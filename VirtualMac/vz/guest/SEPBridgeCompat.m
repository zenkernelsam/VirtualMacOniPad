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
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern const char *_Block_signature(void *aBlock);

#pragma mark - Logging

static unsigned sepCount;
static int sepLogFD = -1;
static double sepNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
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
    char types[6] = {0};
    unsigned n = sepBlockArgTypes((__bridge void *)block, types, 6);
    long vals[6] = {0};
    for (unsigned i = 0; i < n; i++) {
        BOOL last = (i == n - 1);
        id v = last ? sepUnwrap(wrappedError)
            : (i < wrappedResults.count ? sepUnwrap(wrappedResults[i]) : nil);
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
                vals[i] = (long)(__bridge void *)v;
                break;
        }
    }
    void *invoke = ((void **)(__bridge void *)block)[2];
    ((void (*)(void *, long, long, long, long, long, long))invoke)(
        (__bridge void *)block, vals[0], vals[1], vals[2], vals[3],
        vals[4], vals[5]);
    sepLog(@"completion-invoked", @{@"argc": @(n)});
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
static void sepForward(SEL sel, NSArray *args, id completion) {
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
            sepInvokeCompletion(completion, @[],
                sepWrapError(sepError(-1, @"SEP bridge transport failure")));
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
            [rs appendFormat:@"%s%@%lu", rs.length ? "," : "",
                o ? NSStringFromClass([o class]).UTF8String : "nil",
                (unsigned long)([o isKindOfClass:NSData.class]
                    ? [o length] : 0)];
        }
        if (rs.length) ev[@"resClass"] = rs;
        sepLog(@"forward-ok", ev);
        sepInvokeCompletion(completion, rargs, resp[@"error"]);
    });
}

// Thunks: every intercepted method is (object args..., completion block).
static void sepFwd1(id self, SEL _cmd, id a, id completion) {
    sepForward(_cmd, @[a ?: NSNull.null], completion);
}
static void sepFwd2(id self, SEL _cmd, id a, id b, id completion) {
    sepForward(_cmd, @[a ?: NSNull.null, b ?: NSNull.null], completion);
}
static void sepFwdB1(id self, SEL _cmd, BOOL x, id a, id completion) {
    sepForward(_cmd, @[@(x), a ?: NSNull.null], completion);
}

// iOS's signaturesForData:options: daemon entry performs a peer-context
// check that exits the process for injected callers. The leaf primitive
// absintheSignatureForData: does not — it signs raw bytes and returns.
// Decompose the batch call into per-item absinthe forwards and rebuild
// the response shape (dict->dict, array->array).
static void sepFwdAbsintheBatch(id self, SEL _cmd, id datas, id options,
                              id completion) {
    SEL leaf = sel_registerName("absintheSignatureForData:completion:");
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id rebuilt = nil;
    __block id firstErr = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id (^signOne)(id) = ^id(id item) {
            if (![item isKindOfClass:NSData.class]) return item;
            dispatch_semaphore_t s1 = dispatch_semaphore_create(0);
            __block id out = nil, err = nil;
            sepForward(leaf, @[item], ^(NSArray *a, id e) {
                out = a.count ? a[0] : nil;
                err = e;
                dispatch_semaphore_signal(s1);
            });
            dispatch_semaphore_wait(s1,
                dispatch_time(DISPATCH_TIME_NOW, 30ull * NSEC_PER_SEC));
            if (err && !firstErr) firstErr = err;
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
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, 120ull * NSEC_PER_SEC));
    // The wrapped-results path expects the remote's wire format; rebuild
    // one item as a keyed archive so unwrap reproduces the object.
    NSData *arch = [NSKeyedArchiver archivedDataWithRootObject:
        rebuilt ?: [NSNull null] requiringSecureCoding:NO error:nil];
    NSArray *wrapped = arch ? @[@{@"k": @"keyed", @"v": arch}] : @[];
    sepInvokeCompletion(completion, wrapped,
                        firstErr ? sepWrapError(firstErr) : nil);
}

#pragma mark - Swizzle installation

static CFMutableSetRef swizzled;
static BOOL sepSwizzle(Class c, SEL sel, IMP repl) {
    if (!c || !sel) return NO;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    if (method_getImplementation(m) == repl) return YES;
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
    {"signaturesForData:options:completion:", (IMP)sepFwdAbsintheBatch},
    {"signatureForData:options:completion:", (IMP)sepFwdAbsintheBatch},
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

static const struct { const char *cls; const char *sel; IMP impl; }
    kSignerOps[] = {
    {"AKAttestationSigner", "signatureForData:options:completion:",
     (IMP)sepFwd2},
    {"AKAttestationSigner", "signaturesForData:options:completion:",
     (IMP)sepFwd2},
    {"DCBAASigner", "signatureForData:completion:", (IMP)sepFwd1},
    {"DCBAASigner", "signaturesForData:completion:", (IMP)sepFwd1},
};

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
        if (sepSwizzle(c, s, kSignerOps[i].impl)) total++;
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

__attribute__((constructor)) static void sepInit(void) {
    swizzled = CFSetCreateMutable(NULL, 0, NULL);
    if (!sepEnabled()) return;
    sepLog(@"loaded",
           @{@"host": sepHost(), @"port": @(sepPort())});
    // Frameworks attach lazily; rescan until anchors appear (60 × 250 ms).
    dispatch_async(dispatch_get_global_queue(
        QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0; i < 60; i++) {
            unsigned n = sepInstall();
            if (n) sepLog(@"install-pass",
                          @{@"pass": @(i), @"swizzled": @(n)});
            usleep(250 * 1000);
        }
        sepLog(@"install-done", @{});
    });
}
