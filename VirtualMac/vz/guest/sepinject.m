// sepinject — runs INSIDE the iPad's own akd (injected via opainject by the
// sepbridge-helper watchdog). It owns a persistent outbound connection to
// the helper on 192.168.64.1:18444 (outbound is the only direction akd's
// sandbox permits) and re-dials whenever the link drops.
//
// Each request is a length-prefixed binary-plist frame
// {"sel": <name>, "args": [<wrapped>...]}; the reply is
// {"args": [<wrapped>...], "error": <wrapped|nil>}.
//
// Every selector is invoked on a live AKAnisetteProvisioningService built
// from akd's own audit token — i.e. the real service object serving the
// real com.apple.ak.anisette.xpc endpoint, with full SEP access.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <pthread.h>
#import <mach/mach.h>
extern mach_port_t bootstrap_port;
kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_types.h>
#import <bsm/audit.h>

static int gFd = -1;

static BOOL wrAll(void *b, size_t n) {
    uint8_t *p = b;
    while (n) { ssize_t w = write(gFd, p, n); if (w <= 0) return NO;
        p += w; n -= w; }
    return YES;
}
static BOOL rdAll(void *b, size_t n) {
    uint8_t *p = b;
    while (n) { ssize_t r = read(gFd, p, n); if (r <= 0) return NO;
        p += r; n -= r; }
    return YES;
}

static id wrap(id o) {
    if (!o || o == (id)kCFNull) return @{@"k": @"nil"};
    // BOOL-sized results arrive as tiny integers through the block ABI.
    if ((uintptr_t)o <= 1) return @{@"k": @"bool", @"v": @(!!o)};
    if ([o isKindOfClass:NSData.class] ||
        [o isKindOfClass:NSString.class] ||
        [o isKindOfClass:NSNumber.class] ||
        [o isKindOfClass:NSArray.class] ||
        [o isKindOfClass:NSDictionary.class]) {
        if ([NSPropertyListSerialization
             propertyList:o isValidForFormat:NSPropertyListBinaryFormat_v1_0])
            return @{@"k": @"raw", @"v": o};
    }
    if ([o respondsToSelector:sel_registerName("serializedData")]) {
        id sd = ((id(*)(id, SEL))objc_msgSend)(
            o, sel_registerName("serializedData"));
        if ([sd isKindOfClass:NSData.class])
            return @{@"k": @"akdev", @"v": sd};
    }
    // Errors travel in portable form: private classes (AKAnisetteError)
    // fail unarchive on the peer and silently become nil.
    if ([o isKindOfClass:NSError.class]) {
        NSError *e = o;
        return @{@"k": @"nserr",
                 @"v": @{@"d": e.domain ?: @"?", @"c": @(e.code),
                         @"u": @{NSLocalizedDescriptionKey:
                                    e.localizedDescription ?: @""}}};
    }
    NSData *arch = [NSKeyedArchiver
        archivedDataWithRootObject:o requiringSecureCoding:YES error:nil];
    if (arch) return @{@"k": @"keyed", @"v": arch};
    return @{@"k": @"desc", @"v": [o description] ?: @"?"};
}

static id unwrap(NSDictionary *w) {
    NSString *k = w[@"k"]; id v = w[@"v"];
    if ([k isEqualToString:@"raw"]) return v;
    if ([k isEqualToString:@"nil"]) return nil;
    if ([k isEqualToString:@"bool"]) return @([v boolValue]);
    if ([k isEqualToString:@"keyed"] && [v isKindOfClass:NSData.class])
        return [NSKeyedUnarchiver unarchiveObjectWithData:v];
    if ([k isEqualToString:@"akdev"] && [v isKindOfClass:NSData.class]) {
        Class dev = objc_getClass("AKDevice");
        if (dev) return ((id(*)(id, SEL, id))objc_msgSend)(
            dev, sel_registerName("deviceWithSerializedData:"), v);
        return nil;
    }
    if ([k isEqualToString:@"desc"]) return v;
    return nil;
}

static audit_token_t selfToken(void) {
    audit_token_t t;
    memset(&t, 0, sizeof(t));
    mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
    task_info(mach_task_self(), TASK_AUDIT_TOKEN,
              (task_info_t)&t, &cnt);
    return t;
}

static id gSvc;
static id makeSvc(void) {
    Class ck = objc_getClass("AKClient");
    Class sk = objc_getClass("AKAnisetteProvisioningService");
    if (!ck || !sk) return nil;
    audit_token_t tok = selfToken();
    id client = ((id(*)(id, SEL, audit_token_t *))objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)ck, sel_registerName("alloc")),
        sel_registerName("initWithAuditToken:"), &tok);
    if (!client) return nil;
    return ((id(*)(id, SEL, id))objc_msgSend)(
        ((id(*)(id, SEL))objc_msgSend)((id)sk, sel_registerName("alloc")),
        sel_registerName("initWithClient:"), client);
}

// selector -> arg kinds: i=id obj, b=BOOL, n=none (sync call)
struct op { const char *sel; const char *sig; };
static const struct op kOps[] = {
    {"ping", "n"},
    {"legacyAnisetteDataForDSID:device:completion:", "iib"},
    {"provisionAnisetteForDevice:completion:", "ib"},
    {"fetchAnisetteDataAndProvisionIfNecessary:device:completion:", "bib"},
    {"syncAnisetteWithSIMData:device:completion:", "iib"},
    {"eraseAnisetteForDevice:completion:", "ib"},
    {"anisetteDataForDevice:provisionIfNecessary:", "ibs"},
    {"attestationDataForDevice:withRequest:completion:", "iib"},
    {"absintheSignatureForData:completion:", "ib"},
    {"signatureForData:options:completion:", "iib"},
    {"signaturesForData:options:completion:", "iib"},
    {NULL, NULL},
};

static void respond(NSArray *rargs, id err) {
    NSDictionary *resp = @{@"args": rargs ?: @[],
                           @"error": err ? wrap(err) : @{@"k": @"nil"}};
    NSData *p = [NSPropertyListSerialization dataWithPropertyList:resp
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!p) return;
    uint32_t n = htonl((uint32_t)p.length);
    wrAll(&n, 4);
    wrAll((void *)p.bytes, p.length);
}

static void runCall(NSString *sel, NSArray *args) {
    if ([sel isEqualToString:@"ping"]) { respond(@[], nil); return; }
    const struct op *o = NULL;
    for (int i = 0; kOps[i].sel; i++)
        if (!strcmp(kOps[i].sel, sel.UTF8String)) { o = &kOps[i]; break; }
    if (!o) { respond(nil, [NSString stringWithFormat:@"unsupported %@", sel]);
        return; }
    if (!gSvc) gSvc = makeSvc();
    if (!gSvc) { respond(nil, @"no svc"); return; }

    SEL s = sel_registerName(sel.UTF8String);
    if (![gSvc respondsToSelector:s]) {
        respond(nil, [NSString stringWithFormat:
            @"%@ not on %@", sel, NSStringFromClass(object_getClass(gSvc))]);
        return;
    }
    id a0 = args.count > 0 ? unwrap(args[0]) : nil;
    id a1 = args.count > 1 ? unwrap(args[1]) : nil;

    if (strchr(o->sig, 's')) {   // synchronous: no completion block
        id r = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(
            gSvc, s, a0, a1 ? [a1 boolValue] : NO);
        respond(r ? @[wrap(r)] : @[], nil);
        return;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSMutableArray *rr = [NSMutableArray new];
    __block id rerr = nil;
    // Exactly two block args (result, error); garbage registers bit us before.
    void (^cb)(id, id) = ^(id r0, id r1) {
        if (r1 && [r1 isKindOfClass:NSError.class]) {
            rerr = r1;
            if (r0) [rr addObject:wrap(r0)];
        } else {
            if (r0) [rr addObject:wrap(r0)];
            if (r1) [rr addObject:wrap(r1)];
        }
        dispatch_semaphore_signal(sem);
    };
    if (o->sig[0] == 'b') {
        ((void(*)(id, SEL, BOOL, id, id))objc_msgSend)(
            gSvc, s, a0 ? [a0 boolValue] : NO, a1, cb);
    } else if (o->sig[1] == 'i' && o->sig[2] == 'b' && o->sig[0] == 'i') {
        // "iib": (id, id) + block — i.e. two object args
        if ([sel hasSuffix:@"options:completion:"]) {
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(gSvc, s, a0, a1, cb);
        } else {
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(gSvc, s, a0, a1, cb);
        }
    } else {
        ((void(*)(id, SEL, id, id))objc_msgSend)(gSvc, s, a0, cb);
    }
    if (dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, 20ull * NSEC_PER_SEC)))
        respond(nil, @"timeout");
    else
        respond(rr, rerr);
}

static void serve(void) {
    for (;;) {
        struct sockaddr_in a = {0};
        a.sin_family = AF_INET;
        a.sin_port = htons(18444);
        a.sin_addr.s_addr = inet_addr("192.168.64.1");
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
            gFd = fd;
            for (;;) {
                uint32_t len;
                if (!rdAll(&len, 4)) break;
                len = ntohl(len);
                if (!len || len > 64 * 1024 * 1024) break;
                NSMutableData *d = [NSMutableData dataWithLength:len];
                if (!rdAll(d.mutableBytes, len)) break;
                @autoreleasepool {
                    @try {
                        NSDictionary *req = [NSPropertyListSerialization
                            propertyListWithData:d options:0 format:NULL
                            error:nil];
                        if (![req isKindOfClass:NSDictionary.class]) continue;
                        runCall(req[@"sel"], req[@"args"]);
                    } @catch (NSException *e) {
                        respond(nil, [NSString stringWithFormat:
                            @"exc %@: %@", e.name, e.reason]);
                    }
                }
            }
            close(fd);
            gFd = -1;
        }
        usleep(500 * 1000);   // redial
    }
}

// libxpc: an open transaction counts as activity and prevents akd's
// idle exit — keeps the bridge link stable instead of racing respawns.
// (private SPI — resolved dynamically; SDK marks it iOS-unavailable)
#include <dlfcn.h>

static void (*gTxnBegin)(void);
static void *txnPinLoop(void *_) {
    for (;;) { sleep(20); if (gTxnBegin) gTxnBegin(); }
    return NULL;
}

__attribute__((constructor)) static void boot(void) {
    // May be domain-injected into every user-domain process; only akd
    // owns the bridge.
    const char *pn = getprogname();
    if (!pn || strcmp(pn, "akd")) return;
    // Single-instance dedupe via ObjC runtime namespace: env-injection and
    // watchdog dlopen can both load this dylib; only the first serves.
    // (mach bootstrap_check_in is denied inside the akd sandbox.)
    if (objc_getClass("VMSepBridgeMarker")) return;
    Class mk = objc_allocateClassPair([NSObject class], "VMSepBridgeMarker", 0);
    if (!mk) return;
    objc_registerClassPair(mk);
    void (*xt)(void) = dlsym(RTLD_DEFAULT, "xpc_transaction_begin");
    if (xt) {
        xt();
        // Leak one transaction every 20s: launchd's idle-exit fires only
        // when the outstanding count reaches zero. Idle exits kept
        // killing the bridge mid-request; this keeps akd resident.
        gTxnBegin = xt;
        pthread_t pin;
        pthread_create(&pin, NULL, txnPinLoop, NULL);
        pthread_detach(pin);
    }
    // Pin akd for real: an open client connection to its own listener
    // keeps launchd's idle accounting satisfied where transaction_begin
    // alone proved insufficient (still idle-exited ~30s).
    void *(*xc)(const char *, void *, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (xc) {
        static void *keepConn;
        keepConn = xc("com.apple.ak.anisette.xpc",
            (__bridge void *)dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), 0);
        if (keepConn) {
            void (*seth)(void *, void *) = dlsym(RTLD_DEFAULT,
                "xpc_connection_set_event_handler");
            void (*resume)(void *) = dlsym(RTLD_DEFAULT,
                "xpc_connection_resume");
            if (seth) seth(keepConn, (__bridge void *)^(void *e){ (void)e; });
            if (resume) resume(keepConn);
        }
    }
    pthread_t t;
    pthread_create(&t, NULL, (void *(*)(void *))serve, NULL);
    pthread_detach(t);
}
