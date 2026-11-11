// sepbridge-helper v2 — relay between the VM guest and the in-akd service.
//
// Why relay: the real anisette implementation lives inside akd which is
// sandboxed (no network-bind, no file-write, no mach-register). The
// injected dylib (sepinject.dylib, via opainject) therefore DIALS OUT to
// this helper on port 18444 — the only network direction akd's sandbox
// permits. The guest-facing side stays on port 18443: every request is
// forwarded verbatim over the persistent akd link and the reply relayed
// back. All identity material is produced inside the real akd; this
// process only shuttles bytes.
//
// Run: opt-in launchd job in user/501, with this fixed-protocol helper
// root-owned 4755. Native akd dials 127.0.0.1:18444 and sends a versioned
// reverse handshake; guests authenticate on 192.168.64.1:18443.

#import <Foundation/Foundation.h>
#import "SEPBridgeNetwork.h"
#import "SEPBridgeInjector.h"
#import <signal.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <spawn.h>
#import <fcntl.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <sysexits.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <poll.h>

#ifndef VMSEP_TOKEN_PATH
#define VMSEP_TOKEN_PATH "/var/jb/sepbridge/host-token.bin"
#endif
#define VMSEP_INJECTOR_PATH "/var/jb/usr/bin/opainject"
#define VMSEP_INJECTION_PATH "/var/jb/sepbridge/sepinject.dylib"
#define VMSEP_NATIVE_AKD_PATH "/System/Library/PrivateFrameworks/AuthKit.framework/akd"

static unsigned hCount;
static void hLog(NSString *tag, NSDictionary *d0) {
    if (__atomic_fetch_add(&hCount, 1, __ATOMIC_RELAXED) >= 4096) return;
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithDictionary:d0 ?: @{}];
    d[@"event"] = tag;
    d[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0
        error:nil];
    if (j) fprintf(stdout, "VMSEPH %.*s\n", (int)j.length,
                   (const char *)j.bytes), fflush(stdout);
}

static int gAkdFd = -1;   // persistent link to the injected akd dylib
static NSLock *gLock;
static int gLinkRequested;
static unsigned gPendingGuests;

static int listenOn(uint16_t port, in_addr_t addr) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = addr;
    if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) || listen(s, 8)) {
        hLog(@"bind-fail", @{@"port": @(port), @"errno": @(errno)});
        close(s);
        return -1;
    }
    return s;
}

static BOOL readAll(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) { ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return NO;
        p += r; n -= r; }
    return YES;
}

static BOOL writeAll(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) { ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w; n -= w; }
    return YES;
}

static NSArray<NSNumber *> *privateInterfaceAddresses(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces)) return nil;
    NSMutableOrderedSet<NSNumber *> *addresses = [NSMutableOrderedSet orderedSet];
    for (struct ifaddrs *it = interfaces; it; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET ||
            !VMSEPInterfaceAllowed(it->ifa_name, it->ifa_flags)) continue;
        in_addr_t address = ((struct sockaddr_in *)it->ifa_addr)->sin_addr.s_addr;
        if (VMSEPPrivateIPv4(address)) [addresses addObject:@(address)];
        if (addresses.count == 64) break;
    }
    freeifaddrs(interfaces);
    return addresses.array;
}

static NSString *addressLabel(in_addr_t address) {
    char text[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &address, text, sizeof(text));
    return @(text);
}

// Only the filtered private address list above reaches this production call.
// Port is explicit so offline tests can use ephemeral loopback sockets.
static void reconcileGuestListeners(NSMutableDictionary<NSNumber *, NSNumber *> *listeners,
                                     NSArray<NSNumber *> *addresses, uint16_t port) {
    if (!addresses) return; // transient enumeration failure preserves valid sockets
    NSSet *wanted = [NSSet setWithArray:addresses];
    for (NSNumber *address in listeners.allKeys) {
        if (![wanted containsObject:address]) {
            close([listeners[address] intValue]);
            [listeners removeObjectForKey:address];
            hLog(@"guest-listener-closed", @{@"address":addressLabel(address.unsignedIntValue)});
        }
    }
    for (NSNumber *address in addresses) {
        if (listeners[address]) continue;
        int fd = listenOn(port, address.unsignedIntValue);
        if (fd >= 0) {
            int flags = fcntl(fd, F_GETFL);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) {
                close(fd); continue;
            }
            listeners[address] = @(fd);
            hLog(@"guest-listening", @{@"port":@(port),
                @"address":addressLabel(address.unsignedIntValue)});
        }
    }
}

static BOOL readToken(uint8_t token[32]) {
    int fd = open(VMSEP_TOKEN_PATH, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_uid == 0 && (info.st_mode & 0777) == 0600 &&
        info.st_size == 32 && readAll(fd, token, 32);
    close(fd);
    return valid;
}

static BOOL safeRootFile(const char *path, BOOL executable) {
    struct stat info;
    return lstat(path, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_uid == 0 && !(info.st_mode & 0022) &&
        (!executable || access(path, X_OK) == 0);
}

typedef struct { int pid; struct timeval started; } NativeAkd;

static BOOL nativeAkdIdentity(struct kinfo_proc *process, NativeAkd *result) {
    if (strcmp(process->kp_proc.p_comm, "akd") ||
        process->kp_eproc.e_ucred.cr_uid != 501)
        return NO;
    int (*pidPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (!pidPath) return NO;
    char path[4096] = {0};
    int count = pidPath(process->kp_proc.p_pid, path, sizeof(path));
    if (count <= 0 || strcmp(path, VMSEP_NATIVE_AKD_PATH)) return NO;
    result->pid = process->kp_proc.p_pid;
    result->started = process->kp_proc.p_starttime;
    return result->pid > 1;
}

// Match native iPad akd only. A concurrent macPad akd has the same p_comm.
static NativeAkd findNativeAkd(void) {
    NativeAkd result = { .pid = -1 };
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) || !sz) return result;
    struct kinfo_proc *procs = malloc(sz);
    if (!procs) return result;
    if (!sysctl(mib, 4, procs, &sz, NULL, 0)) {
        size_t n = sz / sizeof(*procs);
        for (size_t i = 0; i < n; i++)
            if (nativeAkdIdentity(&procs[i], &result)) break;
    }
    free(procs);
    return result;
}

static BOOL sameAkd(NativeAkd a, NativeAkd b) {
    return a.pid > 1 && a.pid == b.pid &&
        a.started.tv_sec == b.started.tv_sec &&
        a.started.tv_usec == b.started.tv_usec;
}

static BOOL revalidateAkd(NativeAkd original) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, original.pid};
    struct kinfo_proc process = {0}; size_t size = sizeof(process);
    NativeAkd now = { .pid = -1 };
    return !sysctl(mib, 4, &process, &size, NULL, 0) &&
        size == sizeof(process) && nativeAkdIdentity(&process, &now) &&
        sameAkd(original, now);
}

static BOOL injectNativeAkd(NativeAkd target) {
    if (!VMSEPTrustedInjector() ||
        !safeRootFile(VMSEP_INJECTION_PATH, NO) || !revalidateAkd(target)) {
        hLog(@"inject-preflight-failed", @{}); return NO;
    }
    pid_t child = -1;
    char pbuf[32]; snprintf(pbuf, sizeof(pbuf), "%d", target.pid);
    char *arguments[] = {VMSEP_INJECTOR_PATH, pbuf, VMSEP_INJECTION_PATH, NULL};
    char *environment[] = {"PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin", NULL};
    int spawned = posix_spawn(&child, VMSEP_INJECTOR_PATH, NULL, NULL,
                              arguments, environment);
    if (spawned) { hLog(@"reinject-spawn-fail", @{@"errno": @(spawned)}); return NO; }
    int status = 0;
    for (int tick = 0; tick < 100; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            BOOL success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            hLog(@"reinject-done", @{@"pid": @(target.pid), @"success": @(success)});
            return success;
        }
        if (waited < 0 && errno != EINTR) return NO;
        usleep(100000);
    }
    // Terminate only our own stuck injector child, never akd or a process group.
    kill(child, SIGTERM);
    for (int tick = 0; tick < 10; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) {
            hLog(@"inject-timeout", @{}); return NO;
        }
        usleep(100000);
    }
    kill(child, SIGKILL);
    for (int tick = 0; tick < 10; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) break;
        usleep(100000);
    }
    hLog(@"inject-timeout", @{}); return NO;
}

static void injectWatchdog(void) {
    NativeAkd injected = { .pid = -1 };
    unsigned failures = 0;
    for (;;) {
        if (!__atomic_load_n(&gLinkRequested, __ATOMIC_ACQUIRE)) {
            sleep(1); continue;
        }
        uint8_t token[32];
        if (!readToken(token)) { sleep(3); continue; }
        NativeAkd target = findNativeAkd();
        if (target.pid > 1 && !sameAkd(target, injected)) {
            if (injectNativeAkd(target)) { injected = target; failures = 0; }
            else {
                failures = MIN(failures + 1, 5u);
                sleep(MIN(3u << failures, 60u));
            }
        }
        sleep(3);
    }
}

static void akdLinkThread(int srv) {
    hLog(@"link-listen", @{@"port": @18444});
    for (;;) {
        struct sockaddr_in pa; socklen_t pl = sizeof(pa);
        int fd = accept(srv, (struct sockaddr *)&pa, &pl);
        if (fd < 0) continue;
        struct timeval timeout = {.tv_sec = 5};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        uint32_t hello[2];
        NativeAkd peer = { .pid = -1 };
        if (pa.sin_addr.s_addr != htonl(INADDR_LOOPBACK) ||
            !readAll(fd, hello, sizeof(hello)) || ntohl(hello[0]) != 0x53455032) {
            close(fd); continue;
        }
        peer = findNativeAkd();
        if ((uint32_t)peer.pid != ntohl(hello[1]) || !revalidateAkd(peer)) {
            hLog(@"reverse-peer-rejected", @{}); close(fd); continue;
        }
        timeout.tv_sec = 30;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        // Keep the existing healthy link; only replace it when it is dead.
        // Multiple injected instances (different dylib paths) would otherwise
        // ping-pong by killing each other's sockets.
        // Newest link always wins: a reconnect means the old socket is dead
        // even when TCP hasn't reported it yet. The watchdog injects only
        // one dylib per akd, so there is no ping-pong source left.
        [gLock lock];
        if (gAkdFd >= 0) close(gAkdFd);
        gAkdFd = fd;
        __atomic_store_n(&gLinkRequested, 0, __ATOMIC_RELEASE);
        [gLock unlock];
        hLog(@"akd-linked", @{
            @"protocol": @2, @"pid": @(peer.pid),
            @"fd": @(fd), @"peer": @(inet_ntoa(pa.sin_addr)),
            @"port": @(ntohs(pa.sin_port))});
    }
}

static void replyErr(int fd, NSString *msg) {
    NSDictionary *o = @{@"args": @[], @"error":
        @{@"k": @"nserr", @"v": @{
            @"d": @"VirtualMac.SEPRelay", @"c": @(ENOTCONN),
            @"u": @{NSLocalizedDescriptionKey: msg ?: @"relay unavailable"}}}};
    NSData *p = [NSPropertyListSerialization dataWithPropertyList:o
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    uint32_t n = htonl((uint32_t)p.length);
    writeAll(fd, &n, 4);
    if (p) writeAll(fd, p.bytes, p.length);
}

// Wake iPad akd on demand: it idle-exits, so a request can arrive while
// nothing holds the reverse link. kickstart spawns it; the watchdog
// reinjects; the injected dylib dials back to 18444.
//
// Never pass -k here: kickstart -k kills a healthy akd first, so every
// brief link gap (reconnect, watchdog not yet done) cost a full cold
// start (~10s) and bursty auth flows timed out. If the process exists,
// leave it alone and let the watchdog's 3s poll inject and redial.
static BOOL waitWakeChild(pid_t child) {
    int status = 0;
    for (unsigned tick = 0; tick < 30; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child)
            return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (waited < 0 && errno != EINTR) return NO;
        usleep(100000);
    }
    // At most 4 seconds including cleanup, signalling only our launchctl child.
    kill(child, SIGTERM);
    for (unsigned tick = 0; tick < 5; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) return NO;
        usleep(100000);
    }
    kill(child, SIGKILL);
    for (unsigned tick = 0; tick < 5; tick++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno != EINTR)) break;
        usleep(100000);
    }
    return NO;
}

static void wakeAkd(void) {
    static const char *doms[] = {"user/501/com.apple.akd",
                                 "gui/501/com.apple.akd",
                                 "system/com.apple.akd"};
    if (findNativeAkd().pid > 0) {
        hLog(@"akd-alive-wait", @{});
        return;
    }
    for (int i = 0; i < 3; i++) {
        pid_t cp;
        char *a[] = {"/var/jb/usr/bin/launchctl", "kickstart",
                     (char *)doms[i], NULL};
        if (posix_spawn(&cp, "/var/jb/usr/bin/launchctl", NULL, NULL,
                        a, NULL) == 0) {
            if (waitWakeChild(cp)) {
                hLog(@"akd-kickstarted", @{@"dom": @(doms[i])});
                return;
            }
        }
    }
}

// Wait for the reverse link for up to ms milliseconds (immediate probe
// first: the old loop body never ran for ms == 0, so every guest request
// looked link-less and went through the akd wake path).
static int waitForLink(int ms) {
    for (int i = 0;; i++) {
        [gLock lock];
        int link = gAkdFd;
        [gLock unlock];
        if (link >= 0) return link;
        if (i >= ms / 50) return -1;
        usleep(50 * 1000);
    }
}

static void guestHandle(int fd) {
    struct timeval timeout = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    uint8_t expected[32], supplied[32];
    if (!readToken(expected) || !readAll(fd, supplied, 32)) { close(fd); return; }
    unsigned difference = 0;
    for (NSUInteger index = 0; index < sizeof(expected); index++)
        difference |= expected[index] ^ supplied[index];
    if (difference) { hLog(@"guest-auth-rejected", @{}); close(fd); return; }
    uint32_t len;
    if (!readAll(fd, &len, 4)) { close(fd); return; }
    len = ntohl(len);
    if (!len || len > 64 * 1024 * 1024) { close(fd); return; }
    NSMutableData *req = [NSMutableData dataWithLength:len];
    if (!readAll(fd, req.mutableBytes, len)) { close(fd); return; }

    int link = waitForLink(0);
    if (link < 0) {
        __atomic_store_n(&gLinkRequested, 1, __ATOMIC_RELEASE);
        hLog(@"wake-akd", @{});
        wakeAkd();
        link = waitForLink(12000);
    }
    if (link < 0) {
        __atomic_store_n(&gLinkRequested, 0, __ATOMIC_RELEASE);
        replyErr(fd, @"native akd relay link not ready; existing mapped version may require natural respawn");
        close(fd);
        return;
    }
    [gLock lock];
    link = gAkdFd;
    if (link < 0) {
        [gLock unlock];
        replyErr(fd, @"no akd link");
        close(fd);
        return;
    }
    // Forward verbatim, keep lock held so requests stay serialized.
    uint32_t n = htonl(len);
    BOOL ok = writeAll(link, &n, 4) && writeAll(link, req.bytes, len);
    uint32_t rlen = 0;
    if (ok) ok = readAll(link, &rlen, 4);
    if (ok) {
        rlen = ntohl(rlen);
        if (!rlen || rlen > 64 * 1024 * 1024) ok = NO;
    }
    if (ok) {
        NSMutableData *resp = [NSMutableData dataWithLength:rlen];
        ok = readAll(link, resp.mutableBytes, rlen);
        if (ok) {
            uint32_t on = htonl(rlen);
            writeAll(fd, &on, 4);
            writeAll(fd, resp.bytes, rlen);
        }
    }
    if (!ok) {  // link died — drop it, wake akd once, retry once
        close(link);
        if (gAkdFd == link) gAkdFd = -1;
        [gLock unlock];
        hLog(@"akd-link-lost", @{});
        __atomic_store_n(&gLinkRequested, 1, __ATOMIC_RELEASE);
        wakeAkd();
        link = waitForLink(15000);
        if (link < 0) {
            __atomic_store_n(&gLinkRequested, 0, __ATOMIC_RELEASE);
            replyErr(fd, @"akd link lost");
            close(fd);
            return;
        }
        [gLock lock];
        link = gAkdFd;
        if (link < 0) {
            [gLock unlock];
            replyErr(fd, @"akd link lost");
            close(fd);
            return;
        }
        n = htonl(len);
        ok = writeAll(link, &n, 4) && writeAll(link, req.bytes, len);
        if (ok) ok = readAll(link, &rlen, 4);
        if (ok) {
            rlen = ntohl(rlen);
            if (!rlen || rlen > 64 * 1024 * 1024) ok = NO;
        }
        if (ok) {
            NSMutableData *resp = [NSMutableData dataWithLength:rlen];
            ok = readAll(link, resp.mutableBytes, rlen);
            if (ok) {
                uint32_t on = htonl(rlen);
                writeAll(fd, &on, 4);
                writeAll(fd, resp.bytes, rlen);
            }
        }
        if (!ok) {
            __atomic_store_n(&gLinkRequested, 0, __ATOMIC_RELEASE);
            close(link);
            if (gAkdFd == link) gAkdFd = -1;
            replyErr(fd, @"akd link lost");
        }
        [gLock unlock];
        close(fd);
        return;
    }
    [gLock unlock];
    close(fd);
}

int main(void) {
    if (setgid(0) || setuid(0) || getuid() || geteuid()) {
        hLog(@"root-required", @{}); return EX_NOPERM;
    }
    uint8_t token[32];
    if (!readToken(token) || !VMSEPTrustedInjector() ||
        !safeRootFile(VMSEP_INJECTION_PATH, NO)) {
        hLog(@"startup-preflight-failed", @{}); return EX_CONFIG;
    }
    // Writing to an akd link whose peer just exited raises SIGPIPE and
    // kills this whole process (guest then sees ECONNREFUSED on 18443).
    // EPIPE is already handled by the retry path below.
    signal(SIGPIPE, SIG_IGN);
    gLock = [NSLock new];
    hLog(@"start", @{@"uid": @(getuid())});
    int reverse = listenOn(18444, htonl(INADDR_LOOPBACK));
    if (reverse < 0) return 1;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ akdLinkThread(reverse); });
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ injectWatchdog(); });
    dispatch_queue_t guests = dispatch_queue_create("com.mac.virtual.sepbridge.requests", NULL);
    NSMutableDictionary<NSNumber *, NSNumber *> *listeners = [NSMutableDictionary dictionary];
    for (;;) {
        @autoreleasepool {
            BOOL enabled = readToken(token);
            if (!enabled) __atomic_store_n(&gLinkRequested, 0, __ATOMIC_RELEASE);
            reconcileGuestListeners(listeners,
                enabled ? privateInterfaceAddresses() : @[], 18443);
            NSMutableData *pollStorage = [NSMutableData dataWithLength:
                listeners.count * sizeof(struct pollfd)];
            struct pollfd *descriptors = pollStorage.mutableBytes;
            NSUInteger index = 0;
            for (NSNumber *fd in listeners.allValues)
                descriptors[index++] = (struct pollfd){.fd=fd.intValue,.events=POLLIN};
            if (poll(descriptors, (nfds_t)index, 1000) <= 0) continue;
            for (NSUInteger i = 0; i < index; i++) {
                if (!(descriptors[i].revents & POLLIN)) continue;
                int fd = accept(descriptors[i].fd, NULL, NULL);
                if (fd < 0) continue;
                int flags = fcntl(fd, F_GETFL);
                if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)) {
                    close(fd); continue;
                }
                if (__atomic_fetch_add(&gPendingGuests, 1, __ATOMIC_ACQ_REL) >= 16) {
                    __atomic_fetch_sub(&gPendingGuests, 1, __ATOMIC_ACQ_REL);
                    close(fd); continue;
                }
                dispatch_async(guests, ^{
                    guestHandle(fd);
                    __atomic_fetch_sub(&gPendingGuests, 1, __ATOMIC_ACQ_REL);
                });
            }
        }
    }
}
