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
// Run: launchd job in user/501 (bootstrap domain context required so the
// akd-dylib's outbound dial to 192.168.64.1 reaches us).

#import <Foundation/Foundation.h>
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

static int listenOn(uint16_t port, in_addr_t addr) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = addr;
    if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) || listen(s, 8)) {
        hLog(@"bind-fail", @{@"port": @(port), @"errno": @(errno)});
        return -1;
    }
    return s;
}

static BOOL readAll(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return NO;
        p += r; n -= r; }
    return YES;
}

// Re-inject sepinject.dylib whenever akd's pid changes (jetsam/restart).
static int findAkdPid(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) || !sz) return -1;
    struct kinfo_proc *procs = malloc(sz);
    if (!procs) return -1;
    int pid = -1;
    if (!sysctl(mib, 4, procs, &sz, NULL, 0)) {
        size_t n = sz / sizeof(*procs);
        for (size_t i = 0; i < n; i++)
            if (!strcmp(procs[i].kp_proc.p_comm, "akd")) {
                pid = procs[i].kp_proc.p_pid; break;
            }
    }
    free(procs);
    return pid;
}

static void injectWatchdog(void) {
    for (;;) {
        int pid = findAkdPid();
        static int lastPid = -1;
        if (pid > 0 && pid != lastPid) {
            lastPid = pid;
            hLog(@"reinject", @{@"pid": @(pid)});
            sleep(1);
            pid_t cp;
            char pbuf[32];
            snprintf(pbuf, sizeof(pbuf), "%d", pid);
            char *a[] = {"/var/jb/usr/bin/opainject", pbuf,
                         "/var/jb/sepbridge/sepinject.dylib", NULL};
            if (posix_spawn(&cp, "/var/jb/usr/bin/opainject",
                    NULL, NULL, a, NULL) == 0) {
                int st; waitpid(cp, &st, 0);
                hLog(@"reinject-done", @{@"rc": @(st)});
            } else {
                hLog(@"reinject-spawn-fail", nil);
            }
        }
        sleep(3);
    }
}

// Minimal HTTP file server on 18445 so the guest can fetch the bridge
// dylib without an SSH channel:  curl http://192.168.64.1:18445/<name>
static void fileServeThread(void) {
    int srv = listenOn(18445, htonl(INADDR_ANY));
    if (srv < 0) return;
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) continue;
        char req[512] = {0};
        read(fd, req, sizeof(req) - 1);
        char name[128] = {0};
        char *g = strstr(req, "GET /");
        if (!g) { close(fd); continue; }
        g += 5;
        int i = 0;
        while (*g && *g != ' ' && *g != '?' && i < 127) name[i++] = *g++;
        name[i] = 0;
        if (!i || strstr(name, "..")) { close(fd); continue; }
        char path[256];
        snprintf(path, sizeof(path), "/var/jb/sepbridge/%s", name);
        int f = open(path, O_RDONLY);
        if (f < 0) {
            const char *e = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
            write(fd, e, strlen(e));
        } else {
            off_t sz = lseek(f, 0, SEEK_END); lseek(f, 0, SEEK_SET);
            char hdr[160];
            int hl = snprintf(hdr, sizeof(hdr),
                "HTTP/1.1 200 OK\r\nContent-Length: %lld\r\n\r\n", sz);
            write(fd, hdr, hl);
            char buf[65536]; ssize_t r;
            while ((r = read(f, buf, sizeof(buf))) > 0) write(fd, buf, r);
            close(f);
            hLog(@"file-served", @{@"name": @(name)});
        }
        close(fd);
    }
}

static void akdLinkThread(void) {
    int srv = listenOn(18444, htonl(INADDR_ANY));
    if (srv < 0) return;
    hLog(@"link-listen", @{@"port": @18444});
    for (;;) {
        struct sockaddr_in pa; socklen_t pl = sizeof(pa);
        int fd = accept(srv, (struct sockaddr *)&pa, &pl);
        if (fd < 0) continue;
        // Keep the existing healthy link; only replace it when it is dead.
        // Multiple injected instances (different dylib paths) would otherwise
        // ping-pong by killing each other's sockets.
        // Newest link always wins: a reconnect means the old socket is dead
        // even when TCP hasn't reported it yet. The watchdog injects only
        // one dylib per akd, so there is no ping-pong source left.
        [gLock lock];
        if (gAkdFd >= 0) close(gAkdFd);
        gAkdFd = fd;
        [gLock unlock];
        hLog(@"akd-linked", @{
            @"fd": @(fd), @"peer": @(inet_ntoa(pa.sin_addr)),
            @"port": @(ntohs(pa.sin_port))});
    }
}

static void replyErr(int fd, NSString *msg) {
    NSDictionary *o = @{@"args": @[], @"error":
        @{@"k": @"desc", @"v": msg}};
    NSData *p = [NSPropertyListSerialization dataWithPropertyList:o
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    uint32_t n = htonl((uint32_t)p.length);
    write(fd, &n, 4);
    if (p) write(fd, p.bytes, p.length);
}

// Wake iPad akd on demand: it idle-exits, so a request can arrive while
// nothing holds the reverse link. kickstart spawns it; the watchdog
// reinjects; the injected dylib dials back to 18444.
//
// Never pass -k here: kickstart -k kills a healthy akd first, so every
// brief link gap (reconnect, watchdog not yet done) cost a full cold
// start (~10s) and bursty auth flows timed out. If the process exists,
// leave it alone and let the watchdog's 3s poll inject and redial.
static void wakeAkd(void) {
    static const char *doms[] = {"user/501/com.apple.akd",
                                 "gui/501/com.apple.akd",
                                 "system/com.apple.akd"};
    if (findAkdPid() > 0) {
        hLog(@"akd-alive-wait", @{});
        return;
    }
    for (int i = 0; i < 3; i++) {
        pid_t cp;
        char *a[] = {"/var/jb/usr/bin/launchctl", "kickstart",
                     (char *)doms[i], NULL};
        if (posix_spawn(&cp, "/var/jb/usr/bin/launchctl", NULL, NULL,
                        a, NULL) == 0) {
            int st; waitpid(cp, &st, 0);
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) {
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
    uint32_t len;
    if (!readAll(fd, &len, 4)) { close(fd); return; }
    len = ntohl(len);
    if (!len || len > 64 * 1024 * 1024) { close(fd); return; }
    NSMutableData *req = [NSMutableData dataWithLength:len];
    if (!readAll(fd, req.mutableBytes, len)) { close(fd); return; }

    int link = waitForLink(0);
    if (link < 0) {
        hLog(@"wake-akd", @{});
        wakeAkd();
        link = waitForLink(12000);
    }
    if (link < 0) {
        replyErr(fd, @"no akd link");
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
    BOOL ok = write(link, &n, 4) == 4 && write(link, req.bytes, len) == (ssize_t)len;
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
            write(fd, &on, 4);
            write(fd, resp.bytes, rlen);
        }
    }
    if (!ok) {  // link died — drop it, wake akd once, retry once
        close(link);
        if (gAkdFd == link) gAkdFd = -1;
        [gLock unlock];
        hLog(@"akd-link-lost", @{});
        wakeAkd();
        link = waitForLink(15000);
        if (link < 0) {
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
        ok = write(link, &n, 4) == 4 &&
             write(link, req.bytes, len) == (ssize_t)len;
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
                write(fd, &on, 4);
                write(fd, resp.bytes, rlen);
            }
        }
        if (!ok) {
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
    // Writing to an akd link whose peer just exited raises SIGPIPE and
    // kills this whole process (guest then sees ECONNREFUSED on 18443).
    // EPIPE is already handled by the retry path below.
    signal(SIGPIPE, SIG_IGN);
    gLock = [NSLock new];
    hLog(@"start", @{@"uid": @(getuid())});
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ akdLinkThread(); });
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ injectWatchdog(); });
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ fileServeThread(); });
    int srv = listenOn(18443, inet_addr("192.168.64.1"));
    if (srv < 0) srv = listenOn(18443, htonl(INADDR_ANY));
    if (srv < 0) return 1;
    hLog(@"listening", @{@"port": @18443});
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) continue;
        guestHandle(fd);
    }
}
