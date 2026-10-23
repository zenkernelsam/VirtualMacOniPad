// SEPBridgeCompat — opt-in identity bridge for the virtualized guest's
// akd/AuthKit identity operations. The guest has no Secure Enclave, so
// anisette provisioning, device attestation and BAA signing all die inside
// akd with `DeviceIdentity not available` (AKAuthenticationError -7066,
// ADIProvisioningEnd -43004, AKAnisetteError -8004, SRP fail -7018).
//
// This dylib forwards the real operations — nothing is faked or bypassed —
// to a helper running on the host iPad, where the same-named AuthKit/
// DeviceCheckInternal classes reach the iPad's real SEP. The identity the
// guest presents is therefore the host device's own identity; the trust
// model matches the macPad chroot route (one physical device).
//
// Intercept surface (all inside akd / any process loading these classes):
//   - every class conforming to AKAnisetteProvisioningDaemonProtocol
//     (covers anisette fetch/provision/sync AND attestation fetches;
//     erase/reset stay native — never remotely erase host identity state)
//   - AKAttestationSigner signatureForData/signaturesForData
//   - DCBAASigner (DeviceCheckInternal) signatureForData/signaturesForData
//
// Transport: TCP to the helper (default 192.168.64.1:18443; env overrides
// VM_SEP_HOST/VM_SEP_PORT), length-prefixed plist frames.
//
// Enable: `defaults write com.mac.virtual.guest-tools SEPIdentityBridge
// -bool true` (Guest Tools appends this dylib to DYLD_INSERT_LIBRARIES),
// or VM_SEP_BRIDGE=1 for a single-process test.
// Events: stderr JSON lines tagged VMSEP plus /tmp/sepbridge-events.log
// (stderr does not reach `log stream` from extension processes).

#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <Block.h>
#import <signal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>

extern const char *_Block_signature(void *aBlock);

#pragma mark - Logging

static unsigned sepCount;
static int sepLogFD = -1;
static double sepNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
// ReportCrash throttles akd corpses ("Corpse allowed 1 of 5"), so the
// real faulting stacks were invisible. Dump our own backtrace first.
static void sepCrashDump(int sig, siginfo_t *si, void *uc) {
    char buf[64];
    int n = snprintf(buf, sizeof(buf),
        "VMSEP {\"event\":\"crash\",\"sig\":%d,\"addr\":\"%p\",\"pid\":%d}\n",
        sig, si ? si->si_addr : 0, getpid());
    int f = open("/tmp/sepbridge-events.log",
                 O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (f >= 0) { write(f, buf, n); }
    void *frames[32];
    int nf = backtrace(frames, 32);
    if (f >= 0) backtrace_symbols_fd(frames, nf, f);
    if (f >= 0) close(f);
    signal(sig, SIG_DFL);
    raise(sig);
}
static void sepLog(NSString *tag, NSDictionary *details) {
    if (__atomic_fetch_add(&sepCount, 1, __ATOMIC_RELAXED) >= 2048) return;
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    d[@"event"] = tag;
    d[@"time"] = @(sepNow());
    d[@"pid"] = @(getpid());
    d[@"process"] = NSProcessInfo.processInfo.processName ?: @"";
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
        options:0 error:nil];
    if (!data) return;
    fprintf(stderr, "VMSEP %.*s\n", (int)data.length,
            (const char *)data.bytes);
    if (sepLogFD < 0) {
        sepLogFD = open("/tmp/sepbridge-events.log",
                        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    }
    if (sepLogFD >= 0) {
        write(sepLogFD, "VMSEP ", 6);
        write(sepLogFD, data.bytes, data.length);
        write(sepLogFD, "\n", 1);
    }
}

#pragma mark - Value wrapping (plist-safe wire format)

// Wire values: {"k":"raw","v":plist} {"k":"keyed","v":archivedData}
//              {"k":"akdev","v":serializedData} {"k":"bool","v":0/1}
//              {"k":"nil"} (NSNull marker for nil args)
static id sepWrap(id o) {
    if (!o) return @{@"k": @"nil"};
    if ([o isKindOfClass:NSNull.class]) return @{@"k": @"nil"};
    Class dev = objc_getClass("AKDevice");
    if (dev && [o isKindOfClass:dev]) {
        NSData *sd = ((id (*)(id, SEL))objc_msgSend)(
            o, sel_registerName("serializedData"));
        if ([sd isKindOfClass:NSData.class])
            return @{@"k": @"akdev", @"v": sd};
    }
    if ([NSPropertyListSerialization propertyList:o
        isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return @{@"k": @"raw", @"v": o};
    NSData *arch = [NSKeyedArchiver archivedDataWithRootObject:o
        requiringSecureCoding:NO error:nil];
    if (arch) return @{@"k": @"keyed", @"v": arch};
    return @{@"k": @"desc", @"v": [o description] ?: @"?"};
}
static id sepUnwrap(id w) {
    if (![w isKindOfClass:NSDictionary.class]) return nil;
    NSString *k = w[@"k"];
    id v = w[@"v"];
    if ([k isEqualToString:@"raw"]) return v;
    if ([k isEqualToString:@"nil"]) return nil;
    if ([k isEqualToString:@"bool"]) return @([v boolValue]);
    if ([k isEqualToString:@"nserr"] && [v isKindOfClass:NSDictionary.class])
        return [NSError errorWithDomain:v[@"d"] ?: @"VMSEPRemote"
                                   code:[v[@"c"] longLongValue]
                               userInfo:[v[@"u"] isKindOfClass:NSDictionary.class]
                                            ? v[@"u"] : nil];
    if ([k isEqualToString:@"keyed"] && [v isKindOfClass:NSData.class]) {
        id o = [NSKeyedUnarchiver unarchivedObjectOfClasses:
            [NSSet setWithObjects:NSObject.class, NSDictionary.class,
             NSArray.class, NSString.class, NSNumber.class, NSData.class,
             NSError.class, NSNull.class, nil]
            fromData:v error:nil];
        if (!o) o = [NSKeyedUnarchiver unarchiveObjectWithData:v];
        return o;
    }
    if ([k isEqualToString:@"akdev"] && [v isKindOfClass:NSData.class]) {
        Class dev = objc_getClass("AKDevice");
        if (dev) return ((id (*)(id, SEL, id))objc_msgSend)(
            dev, sel_registerName("deviceWithSerializedData:"), v);
        return nil;
    }
    if ([k isEqualToString:@"desc"]) return v;
    return nil;
}

#pragma mark - TCP roundtrip

static NSString *sepHost(void) {
    const char *h = getenv("VM_SEP_HOST");
    return h && *h ? @(h) : @"192.168.64.1";
}
static int sepPort(void) {
    const char *p = getenv("VM_SEP_PORT");
    return p && *p ? atoi(p) : 18443;
}

static int sepWriteAll(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t w = send(fd, p, n, 0);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}
static int sepReadAll(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r <= 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

// Returns the reply dictionary or nil on transport failure.
static NSDictionary *sepRoundtrip(NSDictionary *request) {
    NSData *payload = [NSPropertyListSerialization
        dataWithPropertyList:request
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!payload) { sepLog(@"wire-encode-fail", @{}); return nil; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval tv = {60, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(sepPort());
    sa.sin_addr.s_addr = inet_addr(sepHost().UTF8String);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        sepLog(@"transport-connect-fail",
               @{@"host": sepHost(), @"port": @(sepPort()),
                 @"errno": @(errno)});
        close(fd); return nil;
    }
    uint32_t len = htonl((uint32_t)payload.length);
    if (sepWriteAll(fd, &len, 4) || sepWriteAll(fd, payload.bytes,
                                              payload.length)) {
        sepLog(@"transport-write-fail", @{});
        close(fd); return nil;
    }
    uint32_t rlen;
    if (sepReadAll(fd, &rlen, 4)) {
        sepLog(@"transport-read-fail", @{});
        close(fd); return nil;
    }
    rlen = ntohl(rlen);
    if (!rlen || rlen > 64 * 1024 * 1024) { close(fd); return nil; }
    NSMutableData *resp = [NSMutableData dataWithLength:rlen];
    if (sepReadAll(fd, resp.mutableBytes, rlen)) {
        sepLog(@"transport-read-fail", @{});
        close(fd); return nil;
    }
    close(fd);
    return [NSPropertyListSerialization propertyListWithData:resp
        options:0 format:nil error:nil];
}

#pragma mark - Completion dispatch

// Parse a block signature like "v24@?0@8@16" into per-arg type chars.
// Positions after "@?0" are the real args, each = type + offset digits.
// Supported: object (@), BOOL (B), integer, pointer, struct (skipped pos).
static unsigned sepBlockArgTypes(void *block, char *types, unsigned max) {
    const char *sig = _Block_signature(block);
    if (!sig) return 0;
    const char *at = strstr(sig, "@?0");
    if (!at) return 0;
    const char *p = at + 3;
    unsigned n = 0;
    while (*p && n < max) {
        char c = *p;
        if (c >= '0' && c <= '9') { p++; continue; }   // offset digits
        if (c == '"') {                                 // @"ClassName"
            p++;
            while (*p && *p != '"') p++;
            if (*p) p++;
            continue;
        }
        if (c == '@' || c == '#') { types[n++] = '@'; p++; continue; }
        if (c == 'B' || c == 'b') { types[n++] = 'B'; p++; continue; }
        if (strchr("qQiIlLsScC", c)) { types[n++] = 'i'; p++; continue; }
        if (c == '^' || c == '*') { types[n++] = 'p'; p++; continue; }
        if (c == '{' || c == '(' || c == '[') {
            types[n++] = 's';
            int depth = 0;
            do {
                if (*p == '{' || *p == '(' || *p == '[') depth++;
                if (*p == '}' || *p == ')' || *p == ']') depth--;
                p++;
            } while (*p && depth);
            continue;
        }
        // r n N o O R V are encoding modifiers; anything else: skip char.
        p++;
    }
    return n;
}

// Invoke the captured completion. Protocol convention: the trailing arg is
// always the error; result args fill positions 0..n-2 in order. A block
// expecting fewer args simply reads the registers it declared.
static void sepInvokeCompletion(id block, NSArray *wrappedResults,
                                id wrappedError) {
    if (!block) return;
    const char *verbose = getenv("VM_SEP_VERBOSE");
    BOOL talk = verbose && !strcmp(verbose, "1");
    if (talk)
        sepLog(@"invoke-enter", @{@"blk":
            [NSString stringWithFormat:@"%p", (__bridge void *)block]});
    const char *bsig = _Block_signature((__bridge void *)block);
    char types[6] = {0};
    unsigned n = sepBlockArgTypes((__bridge void *)block, types, 6);
    if (talk) sepLog(@"invoke-parsed", @{@"argc": @(n)});
    if (talk) sepLog(@"invoke-sig",
           @{@"sig": bsig ? [NSString stringWithUTF8String:bsig] : @"?",
             @"argc": @(n),
             @"blk": [NSString stringWithFormat:@"%p", (__bridge void *)block],
             @"isa": [NSString stringWithFormat:@"%p",
                      ((void **)(__bridge void *)block)[0]],
             @"flags": [NSString stringWithFormat:@"%lx",
                        ((unsigned long *)((__bridge void *)block))[1] &
                          0xffffffff]});
    long vals[6] = {0};
    void *keep[6] = {0};   // retain for the call, release afterwards
    for (unsigned i = 0; i < n; i++) {
        BOOL last = (i == n - 1);
        id v = last ? sepUnwrap(wrappedError)
            : (i < wrappedResults.count ? sepUnwrap(wrappedResults[i]) : nil);
        if (talk)
            sepLog(@"invoke-arg",
                   @{@"i": @(i), @"cls": v ? NSStringFromClass([v class]) : @"nil"});
        switch (types[i]) {
            case 'B':
                vals[i] = [v respondsToSelector:@selector(boolValue)]
                    ? (long)[v boolValue] : (long)(v != nil);
                break;
            case 'i':
                vals[i] = [v respondsToSelector:@selector(longLongValue)]
                    ? (long)[v longLongValue] : (long)(v != nil);
                break;
            default:
                // v is released at loop scope; keep it alive across the
                // block call, then release (this used to leak one object
                // per forwarded completion and pushed akd into jetsam).
                keep[i] = (void *)CFBridgingRetain(v);
                vals[i] = (long)keep[i];
                break;
        }
    }
    // Do NOT call the raw invoke pointer: on arm64e it carries a PAC
    // signature, and a C-style indirect call jumps to an unauthenticated
    // address -> SIGSEGV inside the reply block every time. A real
    // block-call expression lets clang emit the authenticated blraa.
    // Object and small-scalar params share the same x-register slot, so
    // id casts are ABI-safe; extra params are ignored by the callee.
    switch (n) {
        case 0:
            ((void (^)(void))block)();
            break;
        case 1:
            ((void (^)(id))block)((__bridge id)(void *)vals[0]);
            break;
        case 2:
            ((void (^)(id, id))block)((__bridge id)(void *)vals[0], (__bridge id)(void *)vals[1]);
            break;
        case 3:
            ((void (^)(id, id, id))block)((__bridge id)(void *)vals[0], (__bridge id)(void *)vals[1],
                                         (__bridge id)(void *)vals[2]);
            break;
        default:
            ((void (^)(id, id, id, id, id, id))block)(
                (__bridge id)(void *)vals[0], (__bridge id)(void *)vals[1], (__bridge id)(void *)vals[2],
                (__bridge id)(void *)vals[3], (__bridge id)(void *)vals[4], (__bridge id)(void *)vals[5]);
            break;
    }
    for (unsigned i = 0; i < n; i++)
        if (keep[i]) CFRelease(keep[i]);
    if (talk) sepLog(@"completion-invoked", @{@"argc": @(n)});
}

static id sepWrapError(NSError *e) {
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:e
        requiringSecureCoding:NO error:nil];
    return d ? @{@"k": @"keyed", @"v": d} : nil;
}

#pragma mark - Forward dispatch

static NSError *sepError(int code, NSString *text) {
    return [NSError errorWithDomain:@"VMSEPBridgeError" code:code
        userInfo:@{NSLocalizedDescriptionKey: text ?: @"bridge failure"}];
}

// Runs on a global queue; never blocks the caller's thread.
// The completion is usually a stack block whose enclosing frame returns as
// soon as this method returns; ARC retains it as a plain object and never
// copies it to the heap, so the async invoke later read dead stack — the
// crash that followed successful forwards. Copy it for the trip.
static void sepForward(SEL sel, NSArray *args, id completion) {
    void *blk = completion
        ? (void *)Block_copy((__bridge void *)completion) : NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *selName = NSStringFromSelector(sel);
        NSMutableArray *wa = [NSMutableArray array];
        for (id a in args) [wa addObject:sepWrap(a)];
        double start = sepNow();
        NSDictionary *resp = sepRoundtrip(@{@"op": @"daemon",
            @"sel": selName, @"args": wa});
        double elapsed = sepNow() - start;
        if (![resp isKindOfClass:NSDictionary.class]) {
            sepLog(@"forward-fail",
                   @{@"sel": selName, @"ms": @(elapsed * 1000)});
            sepInvokeCompletion((__bridge id)blk, @[],
                sepWrapError(sepError(-1, @"SEP bridge transport failure")));
            if (blk) Block_release(blk);
            return;
        }
        NSArray *rargs = [resp[@"args"] isKindOfClass:NSArray.class]
            ? resp[@"args"] : @[];
        id eo = resp[@"error"] ? sepUnwrap(resp[@"error"]) : nil;
        NSMutableDictionary *ev = [@{@"akdpid": resp[@"akdpid"] ?: @0,
            @"sel": selName,
            @"ms": @(elapsed * 1000),
            @"argc": @(rargs.count),
            @"err": eo ? @YES : @NO} mutableCopy];
        if (resp[@"error"]) {
            if (!eo) {
                // Raw structure for diagnostics: which wrap kind arrived
                // and why unwrap dropped it.
                id rw = resp[@"error"];
                ev[@"errRaw"] = [rw isKindOfClass:NSDictionary.class]
                    ? (rw[@"k"] ?: @"?") : NSStringFromClass([rw class]);
            }
            if ([eo isKindOfClass:NSError.class]) {
                NSError *ne = eo;
                ev[@"errDomain"] = ne.domain ?: @"";
                ev[@"errCode"] = @(ne.code);
                ev[@"errDesc"] = ne.localizedDescription ?: @"";
                id ue = ne.userInfo[NSUnderlyingErrorKey];
                if ([ue isKindOfClass:NSError.class])
                    ev[@"errUnder"] = [NSString stringWithFormat:
                        @"%@:%ld", ((NSError *)ue).domain,
                        (long)((NSError *)ue).code];
            } else if (eo) {
                ev[@"errDesc"] = [eo description] ?: @"?";
            }
        }
        for (id a in args) {
            ev[@"argClass"] = ev[@"argClass"]
                ? [NSString stringWithFormat:@"%@,%@",
                   ev[@"argClass"], NSStringFromClass([a class]) ?: @"?"]
                : (NSStringFromClass([a class]) ?: @"?");
        }
        // Result shape diagnostics: unwrapped class + byte length for
        // each returned arg — needed to verify reassembly matches what
        // the caller's completion block expects.
        NSMutableString *rs = [NSMutableString string];
        for (id w in rargs) {
            id o = sepUnwrap(w);
            const char *cn = o ? NSStringFromClass([o class]).UTF8String : "nil";
            [rs appendFormat:@"%s%s%lu", rs.length ? "," : "",
                cn ?: "?",
                (unsigned long)([o isKindOfClass:NSData.class]
                    ? [o length] : 0)];
        }
        if (rs.length) ev[@"resClass"] = rs;
        sepLog(@"forward-ok", ev);
        sepInvokeCompletion((__bridge id)blk, rargs, resp[@"error"]);
        if (blk) Block_release(blk);
    });
}

// Probe: record every intercepted entry so the auth sequence can be
// correlated with memory and launchd restarts. VM_SEP_PROBE_CALLS=1.
static void sepCallLog(SEL _cmd, id self, NSArray *args) {
    const char *on = getenv("VM_SEP_PROBE_CALLS");
    if (!on || strcmp(on, "1")) return;
    NSMutableString *a = [NSMutableString string];
    for (id v in args)
        [a appendFormat:@"%s%@", a.length ? "," : "",
            v ? NSStringFromClass([v class]) : @"nil"];
    sepLog(@"call", @{@"sel": NSStringFromSelector(_cmd),
                      @"cls": NSStringFromClass([self class]) ?: @"?",
                      @"args": a});
}

// Thunks: every intercepted method is (object args..., completion block).
static void sepFwd1(id self, SEL _cmd, id a, id completion) {
    sepCallLog(_cmd, self, @[a ?: NSNull.null]);
    sepForward(_cmd, @[a ?: NSNull.null], completion);
}
static void sepFwd2(id self, SEL _cmd, id a, id b, id completion) {
    sepCallLog(_cmd, self, @[a ?: NSNull.null, b ?: NSNull.null]);
    sepForward(_cmd, @[a ?: NSNull.null, b ?: NSNull.null], completion);
}
static void sepFwdB1(id self, SEL _cmd, BOOL x, id a, id completion) {
    sepCallLog(_cmd, self, @[@(x), a ?: NSNull.null]);
    sepForward(_cmd, @[@(x), a ?: NSNull.null], completion);
}

// iOS's signaturesForData:options: daemon entry performs a peer-context
// check that exits the process for injected callers. The leaf primitive
// absintheSignatureForData: does not — it signs raw bytes and returns.
// Decompose the batch call into per-item absinthe forwards and rebuild
// the response shape (dict->dict, array->array).
// Nested completion blocks via sepInvokeCompletion corrupted __block
// byref captures (EXC_BAD_ACCESS, PAC failure on byref ptr). Instead call
// the leaf synchronously with sepRoundtrip — no inner block ABI at all.
static id sepLeafCall(NSString *sel, NSArray *args, NSError **errOut) {
    double start = sepNow();
    NSMutableArray *w = [NSMutableArray array];
    for (id a in args) [w addObject:sepWrap(a)];
    NSDictionary *resp = sepRoundtrip(@{@"op": @"daemon",
        @"sel": sel, @"args": w});
    double elapsed = sepNow() - start;
    if (![resp isKindOfClass:NSDictionary.class]) {
        sepLog(@"leaf-fail", @{@"sel": sel, @"ms": @(elapsed * 1000)});
        if (errOut) *errOut = sepError(-1, @"SEP bridge transport failure");
        return nil;
    }
    NSArray *rargs = [resp[@"args"] isKindOfClass:NSArray.class]
        ? resp[@"args"] : @[];
    id eo = resp[@"error"] ? sepUnwrap(resp[@"error"]) : nil;
    id res = rargs.count ? sepUnwrap(rargs[0]) : nil;
    sepLog(@"leaf-ok",
           @{@"sel": sel, @"ms": @(elapsed * 1000),
             @"akdpid": resp[@"akdpid"] ?: @0,
             @"err": eo ? @YES : @NO,
             @"resClass": res ? NSStringFromClass([res class]) : @"nil"});
    if (errOut && [eo isKindOfClass:NSError.class]) *errOut = eo;
    return res;
}

static void sepFwdAbsintheBatch(id self, SEL _cmd, id datas, id options,
                              id completion) {
    // absintheSignatureForData: returns an absinthe token (NSString);
    // the real batch result needs per-datum signatures (NSData) — akd
    // base64-encodes each dict value and aborted on NSString. The real
    // leaf is signatureForData:options:completion: on the iOS service.
    NSString *leaf = @"signatureForData:options:completion:";
    // Fully synchronous on the calling thread: the XPC reply block's
    // lifetime is only guaranteed while the method invocation is active;
    // deferred invocation on another queue left its captured state stale
    // (EXC_BAD_ACCESS inside NSXPCConnection decode block).
    __block id rebuilt = nil;
    __block NSError *firstErr = nil;
    id (^signOne)(id) = ^id(id item) {
        if (![item isKindOfClass:NSData.class]) return item;
        NSError *e = nil;
        id out = sepLeafCall(leaf,
            options ? @[item, options] : @[item], &e);
        if (e && !firstErr) firstErr = e;
        return out;
    };
    if ([datas isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        for (id k in datas) r[k] = signOne(datas[k]) ?: NSNull.null;
        rebuilt = r;
    } else if ([datas isKindOfClass:NSArray.class]) {
        NSMutableArray *r = [NSMutableArray array];
        for (id item in datas)
            [r addObject:signOne(item) ?: NSNull.null];
        rebuilt = r;
    } else {
        rebuilt = signOne(datas);
    }
    // Completion ABI (from AuthKit extended signatures):
    //   ^(NSDictionary *result, NSData *data, NSError *error)
    // rebuilt holds per-item signature tokens from absinthe; put the
    // collected dict/array in slot 0 and the first signature blob
    // (UTF-8 of the absinthe token) in slot 1.
    id sigBlob = nil;
    if ([rebuilt isKindOfClass:NSDictionary.class]) {
        for (id v in ((NSDictionary *)rebuilt).allValues)
            if ([v isKindOfClass:NSString.class] ||
                [v isKindOfClass:NSData.class]) { sigBlob = v; break; }
    } else if ([rebuilt isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)rebuilt)
            if ([v isKindOfClass:NSString.class] ||
                [v isKindOfClass:NSData.class]) { sigBlob = v; break; }
    } else {
        sigBlob = rebuilt;
    }
    if ([sigBlob isKindOfClass:NSString.class])
        sigBlob = [(NSString *)sigBlob dataUsingEncoding:NSUTF8StringEncoding];
    NSData *arch = [NSKeyedArchiver archivedDataWithRootObject:
        rebuilt ?: [NSNull null] requiringSecureCoding:NO error:nil];
    NSData *sarch = [NSKeyedArchiver archivedDataWithRootObject:
        sigBlob ?: [NSNull null] requiringSecureCoding:NO error:nil];
    NSMutableArray *wrapped = [NSMutableArray array];
    if (arch) [wrapped addObject:@{@"k": @"keyed", @"v": arch}];
    if (sarch) [wrapped addObject:@{@"k": @"keyed", @"v": sarch}];
    sepInvokeCompletion(completion, wrapped,
                        firstErr ? sepWrapError(firstErr) : nil);
}

#pragma mark - Swizzle installation

static CFMutableSetRef swizzled;
static BOOL sepSwizzle(Class c, SEL sel, IMP repl) {
    if (!c || !sel) return NO;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    // Already ours: report no change so the rescan loop stops logging
    // install-pass every half second for the life of the process.
    if (method_getImplementation(m) == repl) return NO;
    method_setImplementation(m, repl);
    return YES;
}

// Daemon protocol methods we forward — only ops that genuinely need a
// hardware identity (anisette provision/fetch/sync + attestation data).
// erase/reset (remote identity mutation), analytics posting and local
// time-adjust bookkeeping stay native; they fail harmlessly as before.
static const struct { const char *sel; IMP impl; } kDaemonOps[] = {
    {"provisionAnisetteForDevice:completion:", (IMP)sepFwd1},
    {"fetchAnisetteDataAndProvisionIfNecessary:device:completion:",
     (IMP)sepFwdB1},
    {"legacyAnisetteDataForDSID:device:completion:", (IMP)sepFwd2},
    {"syncAnisetteWithSIMData:device:completion:", (IMP)sepFwd2},
    {"attestationDataForDevice:withRequest:completion:", (IMP)sepFwd2},
    // attestationDataForRequestData: stays native: iOS lacks that method,
    // but the macOS implementation decomposes into the leaf ops below,
    // which all exist on the iOS daemon service and are forwarded.
    {"absintheSignatureForData:completion:", (IMP)sepFwd1},
    // Whole-batch forward to iOS AKAttestationSigner.sharedSigner: the
    // signer's batch method returns the exact (NSDictionary, NSData,
    // NSError) reply shape, so relay it verbatim instead of a per-item
    // absinthe fanout (which produced NSString tokens that made akd
    // abort calling -base64EncodedStringWithOptions: on them).
    {"signaturesForData:options:completion:", (IMP)sepFwd2},
    {"signatureForData:options:completion:", (IMP)sepFwd2},
};

static unsigned sepSwizzleDaemonClass(Class c) {
    if (!c || CFSetContainsValue(swizzled, (__bridge const void *)c))
        return 0;
    unsigned n = 0;
    for (size_t i = 0; i < sizeof(kDaemonOps) / sizeof(kDaemonOps[0]); i++) {
        SEL s = sel_registerName(kDaemonOps[i].sel);
        if (sepSwizzle(c, s, kDaemonOps[i].impl)) n++;
    }
    if (n) {
        CFSetAddValue(swizzled, (__bridge const void *)c);
        sepLog(@"daemon-swizzled",
               @{@"class": NSStringFromClass(c), @"methods": @(n)});
    }
    return n;
}

// _AKAnisetteProviderProxy serves com.apple.ak.anisette.xpc inside akd.
// Its context-based methods provision anisette via local ADI (adid),
// which fails on this SEP-less VM (-43004). Translate each call into
// the iOS AKAnisetteProvisioningService equivalent (device = current,
// i.e. nil) and forward across the bridge. DSID/B verified from method
// type encodings: DSID is an object, provisionIfNecessary is BOOL.
static void sepFwdProvisionCtx(id self, SEL _cmd, id ctx, id c) {
    sepForward(sel_registerName("provisionAnisetteForDevice:completion:"),
               @[NSNull.null], c);
}
static void sepFwdFetchCtx(id self, SEL _cmd, id ctx, BOOL p, id c) {
    sepForward(sel_registerName(
        "fetchAnisetteDataAndProvisionIfNecessary:device:completion:"),
               @[@(p), NSNull.null], c);
}
static void sepFwdLegacyCtx(id self, SEL _cmd, id ctx, id d, id c) {
    sepForward(sel_registerName(
        "legacyAnisetteDataForDSID:device:completion:"),
               @[d ?: NSNull.null, NSNull.null], c);
}
static void sepFwdSyncCtx(id self, SEL _cmd, id ctx, id sim, id c) {
    sepForward(sel_registerName("syncAnisetteWithSIMData:device:completion:"),
               @[sim ?: NSNull.null, NSNull.null], c);
}
static void sepFwdPeerAttestCtx(id self, SEL _cmd, id ctx, id req, id c) {
    sepForward(sel_registerName(
        "attestationDataForDevice:withRequest:completion:"),
               @[NSNull.null, req ?: NSNull.null], c);
}
static void sepFwdEraseCtx(id self, SEL _cmd, id ctx, id c) {
    sepForward(sel_registerName("eraseAnisetteForDevice:completion:"),
               @[NSNull.null], c);
}

// AKNativeAnisetteService is the provider that actually talks to CoreADI
// inside akd (confirmed via the provider getter probe). It is what the
// native attestation/SRP path uses, so the daemon-protocol swizzles above
// never see it. Its completion shapes are the AKAnisetteServiceProtocol
// pair (result, error), so relaying the iPad fetch result works for both
// one-arg (error-only) and two-arg completions. Provision and legacy are
// served by the same provision-if-necessary fetch: on this VM the missing
// hardware identity is exactly what that fetch supplies. erase/sync stay
// native — forwarding erase would wipe the iPad's real anisette.
static void sepFwdNativeFetch(id self, SEL _cmd, BOOL p, id c) {
    sepCallLog(_cmd, self, @[@(p)]);
    sepLog(@"native-fetch", @{@"p": @(p)});
    sepForward(sel_registerName(
        "fetchAnisetteDataAndProvisionIfNecessary:device:completion:"),
               @[@(p), NSNull.null], c);
}
static void sepFwdNativeProvision(id self, SEL _cmd, id c) {
    sepCallLog(_cmd, self, @[]);
    sepLog(@"native-provision", @{});
    sepForward(sel_registerName(
        "fetchAnisetteDataAndProvisionIfNecessary:device:completion:"),
               @[@YES, NSNull.null], c);
}
static void sepFwdNativeLegacy(id self, SEL _cmd, id dsid, id c) {
    sepCallLog(_cmd, self, @[dsid ?: NSNull.null]);
    sepLog(@"native-legacy", @{@"dsid": dsid ?: @"nil"});
    sepForward(sel_registerName(
        "fetchAnisetteDataAndProvisionIfNecessary:device:completion:"),
               @[@YES, NSNull.null], c);
}

static const struct { const char *cls; const char *sel; IMP impl; }
    kSignerOps[] = {
    {"AKNativeAnisetteService",
     "fetchAnisetteDataAndProvisionIfNecessary:withCompletion:",
     (IMP)sepFwdNativeFetch},
    {"AKNativeAnisetteService", "provisionAnisetteWithCompletion:",
     (IMP)sepFwdNativeProvision},
    {"AKNativeAnisetteService", "legacyAnisetteDataForDSID:withCompletion:",
     (IMP)sepFwdNativeLegacy},
    {"_AKAnisetteProviderProxy",
     "provisionAnisetteForContext:withCompletion:", (IMP)sepFwdProvisionCtx},
    {"_AKAnisetteProviderProxy",
     "fetchAnisetteDataForContext:provisionIfNecessary:withCompletion:",
     (IMP)sepFwdFetchCtx},
    {"_AKAnisetteProviderProxy",
     "legacyAnisetteDataForContext:DSID:withCompletion:",
     (IMP)sepFwdLegacyCtx},
    {"_AKAnisetteProviderProxy",
     "syncAnisetteForContext:withSIMData:completion:", (IMP)sepFwdSyncCtx},
    {"_AKAnisetteProviderProxy",
     "fetchPeerAttestationDataForContext:withRequest:completion:",
     (IMP)sepFwdPeerAttestCtx},
    {"_AKAnisetteProviderProxy",
     "eraseAnisetteForContext:withCompletion:", (IMP)sepFwdEraseCtx},
    {"AKAttestationSigner", "signatureForData:options:completion:",
     (IMP)sepFwd2},
    {"AKAttestationSigner", "signaturesForData:options:completion:",
     (IMP)sepFwd2},
    {"DCBAASigner", "signatureForData:completion:", (IMP)sepFwd1},
    {"DCBAASigner", "signaturesForData:completion:", (IMP)sepFwd1},
};

// Diagnostic: the App Store / media sign-in sheet never hands akd the typed
// password (it reaches the context as username-only). When explicitly opted
// in with VM_SEP_STAGE_PASSWORD=1, answer AKAppleIDAuthenticationContext's
// _password getter from a mode-0600 file for the staged account, consume the
// file, and forget the value after 3 minutes. Password contents are never
// logged.
static IMP gOrigPasswordGetter;
static NSString *gStagedPassword;
static void sepStageClear(void) {
    if (gStagedPassword) {
        gStagedPassword = nil;
        sepLog(@"stage-password", @{@"phase": @"cleared"});
    }
}
// Probe: fingerprint a context that arrives without a password so the
// media sign-in can be told apart from background IDMS check-ins. Only
// identifiers/enums/classes are logged, never secrets.
static void sepLogCtxProps(id ctx) {
    const char *on = getenv("VM_SEP_PROBE_CTX");
    if (!on || strcmp(on, "1")) return;
    NSArray *sels = @[@"username", @"_serviceType", @"proxiedAppBundleID",
        @"clientBundleID", @"_proxiedBundleID", @"proxiedBundleID",
        @"verifyCredentialReason", @"_reason", @"reason",
        @"shouldPromptForPasswordOnly", @"passwordlessToken",
        @"_isEligibleForUpgradeFromPassword", @"_requiresPasswordInput",
        @"_isPasswordEditable"];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if (![ctx respondsToSelector:sel]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(ctx, sel);
            if ([v isKindOfClass:NSString.class] ||
                [v isKindOfClass:NSNumber.class])
                d[s] = [v description];
            else
                d[s] = v ? NSStringFromClass([v class]) : @"nil";
        } @catch (NSException *e) { d[s] = @"exc"; }
    }
    sepLog(@"ctxprops", d);
}

static id sepPasswordGetter(id self, SEL _cmd) {
    id v = gOrigPasswordGetter
        ? ((id (*)(id, SEL))gOrigPasswordGetter)(self, _cmd) : nil;
    if (v) return v;
    const char *on = getenv("VM_SEP_STAGE_PASSWORD");
    if (!on || strcmp(on, "1")) return v;
    const char *want = getenv("VM_SEP_STAGE_EMAIL");
    id user = v ? nil : ((id (*)(id, SEL))objc_msgSend)(
        self, sel_registerName("username"));
    if (![user isKindOfClass:NSString.class]) return v;
    if (want && *want && strcmp([(NSString *)user UTF8String], want)) return v;
    sepLogCtxProps(self);
    if (!gStagedPassword) {
        gStagedPassword = [NSString stringWithContentsOfFile:@"/tmp/.vmsep-pw"
            encoding:NSUTF8StringEncoding error:nil];
        unlink("/tmp/.vmsep-pw");
        if (gStagedPassword.length) {
            sepLog(@"stage-password", @{@"phase": @"filled",
                                        @"len": @(gStagedPassword.length)});
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180ull * NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                    sepStageClear();
                });
        }
    }
    return gStagedPassword;
}

// Probe: did the sign-in client actually hand akd a password? Logs only
// the object class and length (never the contents). VM_SEP_PROBE_CREDS=1.
static IMP gOrigSetPassword, gOrigSetPLT, gOrigSetUsername;
static void sepCredLog(NSString *what, id v) {
    NSString *s = [v isKindOfClass:NSString.class] ? v : nil;
    sepLog(@"cred", @{@"what": what,
                      @"cls": v ? NSStringFromClass([v class]) : @"nil",
                      @"len": @(s ? s.length : 0)});
}
static void sepSetPassword(id self, SEL _cmd, id v) {
    sepCredLog(@"password", v);
    if (gOrigSetPassword) ((void (*)(id, SEL, id))gOrigSetPassword)(self, _cmd, v);
}
static void sepSetPLT(id self, SEL _cmd, id v) {
    sepCredLog(@"passwordlessToken", v);
    if (gOrigSetPLT) ((void (*)(id, SEL, id))gOrigSetPLT)(self, _cmd, v);
}
static void sepSetUsername(id self, SEL _cmd, id v) {
    sepCredLog(@"username", v);
    if (gOrigSetUsername) ((void (*)(id, SEL, id))gOrigSetUsername)(self, _cmd, v);
}

// One-shot diagnostic: which classes in this process actually implement
// the anisette entry points. The observable failure mode is akd serving a
// client anisette request straight through com.apple.adid, so knowing the
// real receiver class is the difference between a blind swizzle and fixing
// the right object.
static void sepLogReceivers(void) {
    static const char *sels[] = {
        "provisionAnisetteForDevice:completion:",
        "fetchAnisetteDataAndProvisionIfNecessary:device:completion:",
        "fetchAnisetteDataForContext:provisionIfNecessary:withCompletion:",
        "attestationDataForRequestData:completion:",
        "attestationDataForDevice:withRequest:completion:",
    };
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *list = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
    if (!list) return;
    n = objc_getClassList(list, n);
    NSMutableArray *hits = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        for (size_t j = 0; j < sizeof(sels) / sizeof(sels[0]); j++) {
            SEL s = sel_registerName(sels[j]);
            if (class_getInstanceMethod(list[i], s)) {
                [hits addObject:[NSString stringWithFormat:@"%s:%s",
                    class_getName(list[i]), sels[j]]];
            }
        }
    }
    free(list);
    sepLog(@"receivers", @{@"list": hits});
}

// Observation hook: attestationDataForRequestData: is the native path that
// falls through to CoreADI when a client asks for BAA headers. We cannot
// safely forward it yet (iPad's device: variant aborted on a synthetic
// request), but knowing whether real flows hit it decides the next step.
// It logs and calls the original implementation unchanged.
static BOOL sepIsAkd(void);
static IMP gOrigAttestReq;
static IMP gOrigNativeSvc, gOrigClientSvc, gOrigPairedSvc;
static id sepLogProviderGetter(id self, SEL _cmd, IMP orig, NSString *tag) {
    id r = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    sepLog(@"provider", @{@"sel": tag,
                          @"cls": r ? NSStringFromClass([r class]) : @"nil"});
    return r;
}
static id sepGetNative(id self, SEL _cmd) {
    return sepLogProviderGetter(self, _cmd, gOrigNativeSvc, @"native");
}
static id sepGetClientSvc(id self, SEL _cmd) {
    return sepLogProviderGetter(self, _cmd, gOrigClientSvc, @"client");
}
static id sepGetPaired(id self, SEL _cmd) {
    return sepLogProviderGetter(self, _cmd, gOrigPairedSvc, @"paired");
}
static void sepLogAttestReq(id self, SEL _cmd, id req, id completion) {
    NSUInteger len = [req isKindOfClass:NSData.class]
        ? [(NSData *)req length] : 0;
    sepLog(@"attest-req", @{
        @"cls": NSStringFromClass([self class]) ?: @"?",
        @"reqLen": @(len),
        @"reqCls": req ? NSStringFromClass([req class]) : @"nil",
    });
    if (gOrigAttestReq)
        ((void (*)(id, SEL, id, id))gOrigAttestReq)(
            self, _cmd, req, completion);
}

// Dump a class's own method list + protocol conformance. The anisette XPC
// handshake inside akd clearly reaches *some* service object that talks to
// ADI, but neither swizzled class logged a call — so the receiver is not
// necessarily what the names suggest.
static void sepDumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { sepLog(@"dump-class", @{@"cls": @(name), @"found": @NO}); return; }
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++)
        [names addObject:@(sel_getName(method_getName(ms[i])))];
    free(ms);
    unsigned pc = 0;
    Protocol *__unsafe_unretained *ps = class_copyProtocolList(c, &pc);
    NSMutableArray *protos = [NSMutableArray array];
    for (unsigned i = 0; i < pc; i++)
        [protos addObject:@(protocol_getName(ps[i]))];
    free(ps);
    sepLog(@"dump-class", @{@"cls": @(name), @"methods": names,
                            @"protos": protos});
}

static unsigned sepInstall(void) {
    unsigned total = 0;
    Protocol *daemon = objc_getProtocol(
        "AKAnisetteProvisioningDaemonProtocol");
    if (daemon) {
        unsigned count = 0;
        int n = objc_getClassList(NULL, 0);
        if (n > 0) {
            Class *list = (Class *)malloc(sizeof(Class) * (size_t)n);
            n = objc_getClassList(list, n);
            for (int i = 0; i < n; i++) {
                Class c = list[i];
                if (class_conformsToProtocol(c, daemon))
                    total += sepSwizzleDaemonClass(c);
            }
            free(list);
            (void)count;
        }
    }
    for (size_t i = 0; i < sizeof(kSignerOps) / sizeof(kSignerOps[0]); i++) {
        Class c = objc_getClass(kSignerOps[i].cls);
        if (!c) continue;
        SEL s = sel_registerName(kSignerOps[i].sel);
        if (sepSwizzle(c, s, kSignerOps[i].impl)) {
            total++;
            sepLog(@"signer-swizzled", @{@"cls": @(kSignerOps[i].cls),
                                         @"sel": @(kSignerOps[i].sel)});
        }
    }
    if (sepIsAkd()) {
        static BOOL credsHooked;
        if (!credsHooked) {
            credsHooked = YES;
            Class ctx = objc_getClass("AKAppleIDAuthenticationContext");
            if (ctx) {
                Method m;
                m = class_getInstanceMethod(ctx, sel_registerName("_setPassword:"));
                if (m) gOrigSetPassword = method_setImplementation(m, (IMP)sepSetPassword);
                m = class_getInstanceMethod(ctx, sel_registerName("setPasswordlessToken:"));
                if (m) gOrigSetPLT = method_setImplementation(m, (IMP)sepSetPLT);
                m = class_getInstanceMethod(ctx, sel_registerName("setUsername:"));
                if (m) gOrigSetUsername = method_setImplementation(m, (IMP)sepSetUsername);
                m = class_getInstanceMethod(ctx, sel_registerName("_password"));
                if (m) gOrigPasswordGetter = method_setImplementation(m, (IMP)sepPasswordGetter);
                sepLog(@"creds-probe", @{@"ctx": @YES,
                    @"pw": @(gOrigSetPassword != NULL),
                    @"plt": @(gOrigSetPLT != NULL),
                    @"user": @(gOrigSetUsername != NULL)});
            }
        }
    }
    if (sepIsAkd()) {
        static BOOL dumped;
        if (!dumped) {
            dumped = YES;
            sepDumpClass("AKAnisetteProvisioningService");
            sepDumpClass("_AKAnisetteProviderProxy");
            sepDumpClass("AKAnisetteProvisioningController");
        }
        Class sc = objc_getClass("AKAnisetteProvisioningService");
        if (!gOrigAttestReq && sc) {
            SEL s = sel_registerName(
                "attestationDataForRequestData:completion:");
            Method m = class_getInstanceMethod(sc, s);
            if (m)
                gOrigAttestReq = method_setImplementation(
                    m, (IMP)sepLogAttestReq);
        }
        if (!gOrigNativeSvc && sc) {
            SEL s = sel_registerName("_nativeAnisetteService");
            Method m = class_getInstanceMethod(sc, s);
            if (m)
                gOrigNativeSvc = method_setImplementation(
                    m, (IMP)sepGetNative);
            s = sel_registerName("_clientAnisetteService");
            m = class_getInstanceMethod(sc, s);
            if (m)
                gOrigClientSvc = method_setImplementation(
                    m, (IMP)sepGetClientSvc);
            s = sel_registerName("_pairedDeviceAnisetteService");
            m = class_getInstanceMethod(sc, s);
            if (m)
                gOrigPairedSvc = method_setImplementation(
                    m, (IMP)sepGetPaired);
        }
    }
    return total;
}

#pragma mark - Entry

static BOOL sepEnabled(void) {
    const char *env = getenv("VM_SEP_BRIDGE");
    if (env && !strcmp(env, "1")) return YES;
    id pref = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.mac.virtual.guest-tools"];
    return [[(NSUserDefaults *)pref objectForKey:@"SEPIdentityBridge"]
        boolValue];
}

// akd is on-demand: launchd idle-exits it whenever XPC activity drains.
// Our TCP forwarding is invisible to that accounting, so guest akd was
// dying mid-auth (4097 on com.apple.ak.auth.xpc -> field got swallowed).
// Pin it with leaked transactions — same trick as the iPad side.
//
// Leaked xpc_transaction_begin did NOT stop it: akd calls
// xpc_transaction_exit_clean() from its own idle logic and exits anyway
// (EXITED code=0 right after the reply fired). Interpose that symbol so
// akd cannot self-exit while the bridge is loaded — launchd still owns
// its lifecycle for demand/termination.
extern void xpc_transaction_exit_clean(void);
extern void _exit(int);
extern void exit(int);
static BOOL sepIsAkd(void) {
    const char *pn = getprogname();
    return pn && !strcmp(pn, "akd");
}
static void sepExitCleanNoop(void) {
    static int once;
    if (!__sync_fetch_and_add(&once, 1))
        sepLog(@"exit-clean-blocked", @{});
}
// akd's idle logic uses several exits; exit_clean was blocked but the
// process still left through _exit(0)/exit(0). Block status-0 exits in
// akd only (other processes keep normal semantics); nonzero exits and
// signal deaths are unaffected.
static void sepExitBlock0(int status) {
    if (!sepIsAkd() || status != 0) { syscall(SYS_exit, status); }
    static int once;
    if (!__sync_fetch_and_add(&once, 1))
        sepLog(@"exit0-blocked", @{});
}
// DIAGNOSTIC ONLY (env-gated): DeviceIdentity decides "am I a VM?" with
// sysctlbyname("kern.hv_vmm_present"). Reporting 0 inside akd makes AuthKit
// take the device-BAA path instead of the (absent) host-key path, which lets
// us see whether it then uses the already-bridged AKAttestationSigner.
// Everything else passes through untouched.
static int sepSysctlByName(const char *name, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    const char *env = getenv("VM_SEP_FAKE_NONVM");
    if (env && !strcmp(env, "1") && sepIsAkd() &&
        name && !strcmp(name, "kern.hv_vmm_present") &&
        oldp && oldlenp && *oldlenp >= sizeof(int)) {
        *(int *)oldp = 0;
        *oldlenp = sizeof(int);
        sepLog(@"fake-nonvm", @{@"name": @(name)});
        return 0;
    }
    int mib[8];
    size_t miblen = sizeof(mib) / sizeof(mib[0]);
    if (!sysctlnametomib(name, mib, &miblen))
        return sysctl(mib, (u_int)miblen, oldp, oldlenp, newp, newlen);
    return -1;
}

typedef struct { const void *n; const void *o; } sepInterpose;
__attribute__((used)) static const sepInterpose sepInterposes[]
    __attribute__((section("__DATA,__interpose"))) = {
        { (const void *)sepExitCleanNoop,
          (const void *)xpc_transaction_exit_clean },
        { (const void *)sepExitBlock0, (const void *)_exit },
        { (const void *)sepExitBlock0, (const void *)exit },
        { (const void *)sepSysctlByName, (const void *)sysctlbyname },
};
// Probe: akd's own footprint, sampled every 30s. The job's jetsam soft
// limit is 50 MB; this makes the correlation with restarts explicit.
static void *sepMemLoop(void *_) {
    for (;;) {
        task_vm_info_data_t vi;
        mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO,
                      (task_info_t)&vi, &c) == KERN_SUCCESS)
            sepLog(@"mem", @{@"footprintMB": @(vi.phys_footprint >> 20),
                             @"residentMB": @(vi.resident_size >> 20)});
        sleep(30);
    }
    return NULL;
}

static void *sepPinLoop(void *_) {
    void (*xt)(void) = dlsym(RTLD_DEFAULT, "xpc_transaction_begin");
    if (!xt) return NULL;
    for (;;) { sleep(20); xt(); }
    return NULL;
}

// The launchd env is domain-wide, so the dylib gets mapped into every GUI
// process. Only the auth daemons need it; swizzling unrelated agents just
// widens the crash surface (and the rescan loop keeps them awake).
// VM_SEP_BRIDGE_ALLOW=all restores the old everywhere behaviour.
static BOOL sepProcessAllowed(void) {
    const char *all = getenv("VM_SEP_BRIDGE_ALLOW");
    if (all && !strcmp(all, "all")) return YES;
    const char *pn = getprogname();
    if (!pn) return NO;
    static const char *const names[] = {
        "akd", "appleaccountd", "System Settings", "AppleIDSettings",
        "amsengagementd",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (!strcmp(pn, names[i])) return YES;
    return NO;
}

// DIAGNOSTIC ONLY (env-gated, never part of the delivered profile): force
// DeviceIdentityIsSupported() to true inside akd so AuthKit takes the BAA
// path. The VM branch of that function asks the absent host for a host key;
// what we want to learn is whether AuthKit then falls back to
// AKAttestationSigner (already bridged to the iPad SEP) or insists on the
// host-key stack. Reversible by restarting akd without the env.
static void sepForceDeviceIdentity(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity", RTLD_NOW);
    void *sym = h ? dlsym(h, "DeviceIdentityIsSupported") : NULL;
    if (!sym) {
        sepLog(@"force-devid", @{@"err": @"symbol unavailable"});
        return;
    }
    const size_t page = (size_t)sysconf(_SC_PAGESIZE);
    // arm64e symbol pointers can carry PAC bits; keep the 48-bit address.
    uintptr_t addr = (uintptr_t)sym & 0x0000FFFFFFFFFFFFULL;
    sym = (void *)addr;
    vm_address_t base = (vm_address_t)addr & ~(vm_address_t)(page - 1);
    kern_return_t kr = vm_protect(mach_task_self(), base, page, false,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        sepLog(@"force-devid", @{@"err": @(kr)});
        return;
    }
    uint32_t insns[2] = {0x52800020u, 0xD65F03C0u}; // mov w0,#1 ; ret
    memcpy(sym, insns, sizeof(insns));
    vm_protect(mach_task_self(), base, page, false,
        VM_PROT_READ | VM_PROT_EXECUTE);
    __builtin___clear_cache((char *)sym, (char *)sym + sizeof(insns));
    sepLog(@"force-devid", @{@"patched": @YES});
}

// Diagnostic: run AuthKit's password authentication from inside an
// entitled client (App Store), which can reach com.apple.ak.auth.xpc where
// an ad-hoc CLI gets 4099. Password is read from a mode-0600 file and the
// file is unlinked immediately; only result/error classes are logged.
// Enable with VM_SEP_MEDIA_SIGNIN=<apple-id> (App Store process only).
static void sepMediaSelfTest(void) {
    const char *emailEnv = getenv("VM_SEP_MEDIA_SIGNIN");
    if (!emailEnv || !*emailEnv) return;
    NSString *pwPath = @"/tmp/.vmsep-pw";
    NSString *pw = [NSString stringWithContentsOfFile:pwPath
        encoding:NSUTF8StringEncoding error:nil];
    unlink("/tmp/.vmsep-pw");
    if (!pw.length) { sepLog(@"media-auth", @{@"err": @"no password file"}); return; }
    void *ak = dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
    Class ctxCls = objc_getClass("AKAppleIDAuthenticationContext");
    Class ctlCls = objc_getClass("AKAppleIDAuthenticationController");
    if (!ak || !ctxCls || !ctlCls) {
        sepLog(@"media-auth", @{@"err": @"classes unavailable"}); return;
    }
    id ctx = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)ctxCls, sel_registerName("alloc")),
        sel_registerName("init"));
    ((void (*)(id, SEL, id))objc_msgSend)(ctx, sel_registerName("setUsername:"), @(emailEnv));
    SEL setPw = sel_registerName("_setPassword:");
    if ([ctx respondsToSelector:setPw])
        ((void (*)(id, SEL, id))objc_msgSend)(ctx, setPw, pw);
    id ctl = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)ctlCls, sel_registerName("alloc")),
        sel_registerName("init"));
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id results = nil, error = nil;
    void (^cb)(id, id) = ^(id r, id e) {
        results = r; error = e; dispatch_semaphore_signal(sem);
    };
    sepLog(@"media-auth", @{@"phase": @"start", @"user": @(emailEnv)});
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        ctl, sel_registerName("authenticateWithContext:completion:"), ctx, cb);
    long w = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, 180ull * NSEC_PER_SEC));
    NSString *keys = @"";
    if (results && [results respondsToSelector:sel_registerName("allKeys")])
        keys = [((id (*)(id, SEL))objc_msgSend)(
            results, sel_registerName("allKeys")) description];
    sepLog(@"media-auth", @{
        @"phase": @"done", @"wait": @(w),
        @"results": results ? NSStringFromClass([results class]) : @"nil",
        @"keys": keys ?: @"",
        @"err": error ? [error description] : @"nil",
    });
}

// Read-only probe for amsengagementd: which account types it asks for and
// what ACAccountStore returns. The full bridge is NOT installed in this
// process — injecting swizzles into media daemons broke App Store before.
static IMP gOrigAcctsWithType, gOrigTypeForId;
static id sepAcctsWithType(id self, SEL _cmd, id type) {
    id r = gOrigAcctsWithType
        ? ((id (*)(id, SEL, id))gOrigAcctsWithType)(self, _cmd, type) : nil;
    id ident = type ? ((id (*)(id, SEL))objc_msgSend)(
        type, sel_registerName("identifier")) : nil;
    sepLog(@"ams-accts", @{@"type": [ident description] ?: @"?",
                           @"count": @([r isKindOfClass:NSArray.class] ? [r count] : -1)});
    return r;
}
static id sepTypeForId(id self, SEL _cmd, id ident) {
    id r = gOrigTypeForId
        ? ((id (*)(id, SEL, id))gOrigTypeForId)(self, _cmd, ident) : nil;
    sepLog(@"ams-type", @{@"id": [ident description] ?: @"?",
                          @"found": @(r != nil)});
    return r;
}
static void sepInstallAmsProbe(void) {
    Class c = objc_getClass("ACAccountStore");
    if (!c) { sepLog(@"ams-probe", @{@"err": @"no ACAccountStore"}); return; }
    Method m = class_getInstanceMethod(c, sel_registerName("accountsWithAccountType:"));
    if (m) gOrigAcctsWithType = method_setImplementation(m, (IMP)sepAcctsWithType);
    m = class_getInstanceMethod(c, sel_registerName("accountTypeWithAccountTypeIdentifier:"));
    if (m) gOrigTypeForId = method_setImplementation(m, (IMP)sepTypeForId);
    sepLog(@"ams-probe", @{@"accts": @(gOrigAcctsWithType != NULL),
                           @"type": @(gOrigTypeForId != NULL)});
}

// Diagnostic: run the AVP identity probes from INSIDE an entitled daemon
// (akd), where the AppleVirtualPlatform XPC client actually lives. The
// standalone probe gets 4097 on the identity service even when a listener
// exists, which points at audit-token/entitlement checks rather than the
// service itself. Opt in with VM_SEP_DEVID_TEST=1.
static void sepDeviceIdentityProbe(void) {
    void *di = dlopen("/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity", RTLD_NOW);
    void *avp = dlopen("/System/Library/PrivateFrameworks/AppleVirtualPlatform.framework/AppleVirtualPlatform", RTLD_NOW);
    BOOL (*isSup)(void) = di ? (BOOL (*)(void))dlsym(di, "DeviceIdentityIsSupported") : NULL;
    BOOL (*hasKey)(void) = avp ? (BOOL (*)(void))dlsym(avp, "AppleVirtualPlatformGuestHasHostKey") : NULL;
    CFDataRef (*copyStrong)(CFDictionaryRef, CFErrorRef *) = avp
        ? (CFDataRef (*)(CFDictionaryRef, CFErrorRef *))dlsym(avp, "AppleVirtualPlatformGuestCopyStrongIdentityData")
        : NULL;
    sepLog(@"devid-probe", @{
        @"di": di ? @YES : @NO, @"avp": avp ? @YES : @NO,
        @"supported": isSup ? @(isSup()) : @(-1),
        @"hasHostKey": hasKey ? @(hasKey()) : @(-1),
    });
    // The option names are exported CFString *variables* (the symbol points
    // at a CFStringRef), not getter functions.
    CFStringRef syncKey = avp ? *(CFStringRef *)dlsym(avp, "kAppleVirtualPlatformGuestStrongIdentityOptionSynchronous") : NULL;
    CFStringRef ignoreKey = avp ? *(CFStringRef *)dlsym(avp, "kAppleVirtualPlatformGuestStrongIdentityOptionIgnoreCache") : NULL;
    CFStringRef timeoutKey = avp ? *(CFStringRef *)dlsym(avp, "kAppleVirtualPlatformGuestStrongIdentityOptionSynchronousTimeoutNsec") : NULL;
    if (copyStrong) {
        for (int mode = 0; mode < 2; mode++) {
            NSMutableDictionary *opts = [NSMutableDictionary dictionary];
            if (mode == 1) {
                if (syncKey) opts[(__bridge NSString *)syncKey] = @YES;
                if (ignoreKey) opts[(__bridge NSString *)ignoreKey] = @YES;
                if (timeoutKey) opts[(__bridge NSString *)timeoutKey] = @(5ull * NSEC_PER_SEC);
            }
            CFErrorRef err = NULL;
            CFDataRef d = copyStrong((__bridge CFDictionaryRef)opts, &err);
            sepLog(@"devid-strong", @{
                @"mode": @(mode),
                @"opts": @(opts.count),
                @"len": @(d ? CFDataGetLength(d) : -1),
                @"err": err ? [(__bridge NSError *)err description] : @"nil",
            });
            if (d) CFRelease(d);
            if (err) CFRelease(err);
        }
    }
}

__attribute__((constructor)) static void sepInit(void) {
    swizzled = CFSetCreateMutable(NULL, 0, NULL);
    if (!sepEnabled() || !sepProcessAllowed()) return;
    {
        const char *pn = getprogname();
        if (pn && !strcmp(pn, "amsengagementd")) {
            sepInstallAmsProbe();
            return;
        }
    }
    {
        const char *pn = getprogname();
        if (pn && (!strcmp(pn, "App Store") || !strcmp(pn, "cdpd") ||
                   !strcmp(pn, "appleaccountd")) &&
            getenv("VM_SEP_MEDIA_SIGNIN")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    sepMediaSelfTest();
                });
        }
    }
    if (sepIsAkd()) {
        const char *t = getenv("VM_SEP_DEVID_TEST");
        if (t && !strcmp(t, "1")) sepDeviceIdentityProbe();
        const char *f = getenv("VM_SEP_FORCE_DEVID");
        if (f && !strcmp(f, "1")) sepForceDeviceIdentity();
    }
    // A dead helper socket makes write() raise SIGPIPE, whose default
    // disposition kills the host process — that is how guest akd kept
    // "exiting cleanly" right after a transport failure. Ignore it;
    // write() then returns EPIPE which the transport already handles.
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa = {0};
    sa.sa_sigaction = sepCrashDump;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    const char *pn = getprogname();
    if (pn && !strcmp(pn, "akd")) {
        void (*xt)(void) = dlsym(RTLD_DEFAULT, "xpc_transaction_begin");
        if (xt) xt();
        pthread_t pin;
        pthread_create(&pin, NULL, sepPinLoop, NULL);
        pthread_detach(pin);
        pthread_t mem;
        pthread_create(&mem, NULL, sepMemLoop, NULL);
        pthread_detach(mem);
    }
    sepLog(@"loaded",
           @{@"host": sepHost(), @"port": @(sepPort())});
    if (sepIsAkd()) sepLogReceivers();
    // Frameworks/classes attach lazily — _AKAnisetteProviderProxy only
    // registers when the first anisette XPC connection arrives, which can
    // be minutes later. Rescan forever; sepSwizzle no-ops on methods
    // already redirected.
    dispatch_async(dispatch_get_global_queue(
        QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0;; i++) {
            unsigned n = sepInstall();
            if (n) sepLog(@"install-pass",
                          @{@"pass": @(i), @"swizzled": @(n)});
            usleep(5 * 1000 * 1000);
        }
    });
}
