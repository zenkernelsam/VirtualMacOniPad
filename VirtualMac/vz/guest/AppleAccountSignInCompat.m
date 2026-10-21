// AppleAccountSignInCompat — opt-in diagnostic and web-flow adapter for the
// Apple Account sign-in pane in the virtualized guest.
//
// Methodology ported from the macPad AppleIDSignIn adapter (DCMMC/macPad PR
// #4, the chroot-route fix for this same macOS 15.6.1/24G90 guest build).
// The chroot route needed private Mach namespaces, cloned account/keychain
// daemons and a native device-keybag mapping because it shares the iPad's
// kernel and SEP. A VZ guest already owns its kernel, launchd and service
// namespace, so that machinery is neither required nor ported here. What
// transfers unchanged to this guest:
//   - AuthKitUI's 30 s UI wait timer against a web flow that can take ~38 s
//   - legacy layer-backed WebHTMLView staying blank after unhide under PVG
//   - stage-by-stage JSON logging so a failure reports where it died
// Everything here observes and logs except the two proven AuthKitUI
// adjustments. The guest has no Secure Enclave: keybag/AKS/CTK calls are
// observed so the log shows their real outcome; nothing is remapped, created
// or reset.
//
// Load: appended to DYLD_INSERT_LIBRARIES by Virtual Mac Guest Tools only
// when `defaults write com.mac.virtual.guest-tools AccountSignInAdapter -bool
// true` is set in the guest. Default state is absent from the insert list.
// Output: stderr JSON lines tagged VMACCT_* (visible via `log stream` and
// launchd stderr capture of the inspected process).

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static unsigned acctCount;
static double acctNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static void acctLog(NSString *tag, NSDictionary *details) {
    if (__atomic_fetch_add(&acctCount, 1, __ATOMIC_RELAXED) >= 512) return;
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    d[@"event"] = tag;
    d[@"time"] = @(acctNow());
    d[@"pid"] = @(getpid());
    d[@"process"] = NSProcessInfo.processInfo.processName ?: @"";
    NSData *data = [NSJSONSerialization dataWithJSONObject:d
        options:0 error:nil];
    if (data)
        fprintf(stderr, "VMACCT %.*s\n", (int)data.length,
                (const char *)data.bytes);
}
static NSDictionary *acctURL(NSURL *u) {
    return @{@"host": u.host ?: @"", @"path": u.path ?: @""};
}

#pragma mark - AuthKitUI web flow (timer bound + blank-view redraw)

static void (*acctWebTimer)(id, SEL, double);
static void acctWebCreateTimer(id o, SEL s, double value) {
    // The original server workflow took ~38 s while its UI timer failed at
    // 30 s. Bound only the original default interval; every other value and
    // all failure/cancel/ready paths stay original.
    double use = value == 30.0 ? 90.0 : value;
    acctLog(@"web-timer-create", @{@"original": @(value), @"effective": @(use)});
    acctWebTimer(o, s, use);
}
static id (*acctWebRequest)(id, SEL, id, id, id, id, id);
static id acctWebWillSend(id o, SEL s, id view, id resource,
                        NSURLRequest *request, id redirect, id source) {
    double start = acctNow();
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithDictionary:acctURL(request.URL)];
    d[@"resource"] = [NSString stringWithFormat:@"%p", resource];
    acctLog(@"web-resource-start", d);
    id result = acctWebRequest(o, s, view, resource, request, redirect, source);
    d[@"signing_seconds"] = @(acctNow() - start);
    acctLog(@"web-resource-signed", d);
    return result;
}
static void (*acctWebResponse)(id, SEL, id, id, id, id);
static void acctWebDidReceive(id o, SEL s, id view, id resource,
                            NSURLResponse *response, id source) {
    NSMutableDictionary *d =
        [NSMutableDictionary dictionaryWithDictionary:acctURL(response.URL)];
    d[@"resource"] = [NSString stringWithFormat:@"%p", resource];
    d[@"http"] = @([response isKindOfClass:NSHTTPURLResponse.class]
        ? [(NSHTTPURLResponse *)response statusCode] : 0);
    d[@"length"] = @(response.expectedContentLength);
    acctLog(@"web-resource-response", d);
    acctWebResponse(o, s, view, resource, response, source);
}
static void (*acctWebFrame)(id, SEL, id, id);
static void acctWebDidFinish(id o, SEL s, id view, id frame) {
    acctLog(@"web-frame-finished", @{});
    acctWebFrame(o, s, view, frame);
}
static void (*acctWebReady)(id, SEL), (*acctWebLoaded)(id, SEL),
    (*acctWebDestroy)(id, SEL);
// Under PVG the inherited layer-backed legacy WebHTMLView can remain blank
// after its parent is unhidden. Invalidate + display the existing views after
// the original readiness transition. Never invoke the lazy webView getter
// (it reloads UI).
static unsigned acctWebRedrawTree(id view, unsigned depth) {
    if (!view || depth > 24) return 0;
    Class nsview = objc_getClass("NSView");
    if (![view isKindOfClass:nsview]) return 0;
    unsigned count = 0;
    if ([view isKindOfClass:objc_getClass("WebView")] ||
        [view isKindOfClass:objc_getClass("WebHTMLView")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            view, sel_registerName("setNeedsDisplay:"), YES);
        ((void (*)(id, SEL))objc_msgSend)(
            view, sel_registerName("displayIfNeeded"));
        count++;
    }
    NSArray *children = ((id (*)(id, SEL))objc_msgSend)(
        view, sel_registerName("subviews"));
    for (id child in children) count += acctWebRedrawTree(child, depth + 1);
    return count;
}
static void acctWebIsReady(id o, SEL s) {
    acctLog(@"web-js-client-ready", @{});
    acctWebReady(o, s);
    dispatch_async(dispatch_get_main_queue(), ^{
        id root = ((id (*)(id, SEL))objc_msgSend)(
            o, sel_registerName("containerView"));
        acctLog(@"web-ready-redraw", @{@"views": @(acctWebRedrawTree(root, 0))});
    });
}
static void acctWebHasLoaded(id o, SEL s) {
    acctLog(@"web-js-client-loaded", @{});
    acctWebLoaded(o, s);
}
static void acctWebDestroyTimer(id o, SEL s) {
    acctLog(@"web-timer-destroy", @{});
    acctWebDestroy(o, s);
}
static void (*acctWebFire)(id, SEL, id);
static void acctWebFireTimer(id o, SEL s, id timer) {
    acctLog(@"web-timer-fired", @{@"stack": [NSThread callStackSymbols]});
    acctWebFire(o, s, timer);
}
static void (*acctWebFail)(id, SEL, id);
static void acctWebFailed(id o, SEL s, NSError *err) {
    acctLog(@"web-failed", @{@"domain": err.domain ?: @"",
                             @"code": @(err.code),
                             @"stack": [NSThread callStackSymbols]});
    acctWebFail(o, s, err);
}
static void installAuthKitWeb(void) {
    struct Entry { const char *cls, *sel; unsigned argc;
                   IMP replacement; void **original; } entries[] = {
        {"AKAuthWebTabView", "_createWaitTimerWithTimeInternval:", 3,
            (IMP)acctWebCreateTimer, (void **)&acctWebTimer},
        {"AKWebKitController",
            "webView:resource:willSendRequest:redirectResponse:"
            "fromDataSource:", 7,
            (IMP)acctWebWillSend, (void **)&acctWebRequest},
        {"AKWebKitController",
            "webView:resource:didReceiveResponse:fromDataSource:", 6,
            (IMP)acctWebDidReceive, (void **)&acctWebResponse},
        {"AKWebKitController", "webView:didFinishLoadForFrame:", 4,
            (IMP)acctWebDidFinish, (void **)&acctWebFrame},
        {"AKAuthWebTabView", "icaWebKitViewIsAvailable", 2,
            (IMP)acctWebIsReady, (void **)&acctWebReady},
        {"AKAuthWebTabView", "icaWebKitViewHasLoaded", 2,
            (IMP)acctWebHasLoaded, (void **)&acctWebLoaded},
        {"AKAuthWebTabView", "_destroyWaitTimer", 2,
            (IMP)acctWebDestroyTimer, (void **)&acctWebDestroy},
        {"AKAuthWebTabView", "_fireWaitTimer:", 3,
            (IMP)acctWebFireTimer, (void **)&acctWebFire},
        {"AKAuthWebTabView", "webviewFailedWithError:", 3,
            (IMP)acctWebFailed, (void **)&acctWebFail},
    };
    Method methods[sizeof(entries) / sizeof(entries[0])];
    for (unsigned i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        methods[i] = class_getInstanceMethod(objc_getClass(entries[i].cls),
            sel_registerName(entries[i].sel));
        Dl_info info = {0};
        if (!methods[i] ||
            method_getNumberOfArguments(methods[i]) != entries[i].argc ||
            !dladdr((void *)method_getImplementation(methods[i]), &info) ||
            !info.dli_fname || !strstr(info.dli_fname, "/AuthKitUI.framework/")) {
            acctLog(@"web-install-skipped", @{@"index": @(i)});
            return;
        }
    }
    char type[16] = {0};
    method_getArgumentType(methods[0], 2, type, sizeof(type));
    if (strcmp(type, "d")) {
        acctLog(@"web-install-skipped", @{@"reason": @"timer ABI"});
        return;
    }
    for (unsigned i = 0; i < sizeof(entries) / sizeof(entries[0]); i++)
        *entries[i].original =
            (void *)method_setImplementation(methods[i], entries[i].replacement);
    acctLog(@"web-installed",
        @{@"wait_seconds": @90, @"original_callbacks": @YES});
}

#pragma mark - LocalAuthentication / CryptoTokenKit observers (log only)

static void acctChainError(NSError *error, NSString *tag) {
    for (int i = 0; error && i < 6; i++) {
        const char *domain = "other";
        for (NSString *n in @[@"NSCocoaErrorDomain", @"NSOSStatusErrorDomain",
                @"com.apple.LocalAuthentication",
                @"com.apple.LocalAuthentication.ErrorDomain",
                @"LAErrorDomain", @"com.apple.CoreAuthentication",
                @"CryptoTokenKit"])
            if ([error.domain isEqualToString:n]) {
                domain = n.UTF8String;
                break;
            }
        acctLog(tag, @{@"depth": @(i), @"domain": @(domain),
                       @"code": @(error.code)});
        id next = error.userInfo[NSUnderlyingErrorKey];
        error = [next isKindOfClass:NSError.class] ? next : nil;
    }
}
static id (*acctLAExternal)(id, SEL);
static id acctLAExternalObserver(id self, SEL sel) {
    id result = acctLAExternal(self, sel);
    acctLog(@"la-externalized", @{@"present": @(result != nil)});
    return result;
}
static id (*acctLASyncExternal)(id, SEL, NSError **);
static id acctLASyncObserver(id self, SEL sel, NSError **error) {
    id result = acctLASyncExternal(self, sel, error);
    acctLog(@"la-sync-externalized", @{@"present": @(result != nil)});
    if (error) acctChainError(*error, @"la-sync-error");
    return result;
}
static void (*acctLAConnection)(id, SEL, id, id, id, NSError *);
static void acctLAConnectionObserver(id self, SEL sel, id proxy, id uuid,
                                   id proxyId, NSError *error) {
    acctLog(@"la-connection", @{@"proxy": @(proxy != nil),
                                @"error": @(error ? error.code : 0)});
    acctChainError(error, @"la-connection-error");
    acctLAConnection(self, sel, proxy, uuid, proxyId, error);
}
static void installLocalAuthObservers(void) {
    Class la = objc_getClass("LAContext");
    Method ext = la ? class_getInstanceMethod(
        la, sel_registerName("externalizedContext")) : NULL;
    if (ext) acctLAExternal =
        (void *)method_setImplementation(ext, (IMP)acctLAExternalObserver);
    Class client = objc_getClass("LAClient");
    Method connection = client ? class_getInstanceMethod(client,
        sel_registerName("_handleConnectionResult:uuid:proxyId:error:")) : NULL;
    Method sync = client ? class_getInstanceMethod(client,
        sel_registerName("synchronousExternalizedContextWithError:")) : NULL;
    if (connection) acctLAConnection = (void *)method_setImplementation(
        connection, (IMP)acctLAConnectionObserver);
    if (sync) acctLASyncExternal = (void *)method_setImplementation(
        sync, (IMP)acctLASyncObserver);
    acctLog(@"la-installed", @{@"external": @(ext != NULL),
        @"connection": @(connection != NULL), @"sync": @(sync != NULL)});
}

static id (*acctSEPAuthContext)(id, SEL, NSError **);
static id acctSEPAuthObserver(id self, SEL sel, NSError **error) {
    id result = acctSEPAuthContext(self, sel, error);
    acctLog(@"ctk-auth-context", @{@"present": @(result != nil),
        @"error": @(error && *error ? (*error).code : 0)});
    return result;
}
static int (*acctSEPBag)(id, SEL, BOOL);
static int acctSEPBagObserver(id self, SEL sel, BOOL system) {
    int bag = acctSEPBag(self, sel, system);
    // Log-only port: on the chroot route the macPad adapter mapped the macOS
    // user-session selector (-3) onto the iPad's native device bag (0). This
    // guest has no SEP and no native bag to map onto, so the original value
    // is returned unchanged; the record shows which selector the flow used.
    acctLog(@"ctk-keybag-handle", @{@"original_bag": @(bag),
                                    @"force_system": @(system)});
    return bag;
}
static BOOL (*acctAKSError)(id, SEL, NSError **, int, id, id, id, id);
static BOOL acctAKSErrorObserver(id self, SEL sel, NSError **error, int status,
                               id context, id operation, id params, id message) {
    acctLog(@"ctk-aks-error", @{@"status": @(status),
                                @"hex": @((unsigned)status)});
    return acctAKSError(self, sel, error, status, context, operation, params,
                        message);
}
static void installCryptoTokenKitObservers(void) {
    Class tk = objc_getClass("TKLocalSEPKey");
    Method auth = tk ? class_getInstanceMethod(
        tk, sel_registerName("authContextWithError:")) : NULL;
    Method bag = tk ? class_getClassMethod(
        tk, sel_registerName("keybagHandleForceSystemSession:")) : NULL;
    Method aks = tk ? class_getInstanceMethod(tk, sel_registerName(
        "error:withAKSReturn:ACMHandle:AKSOperation:params:message:")) : NULL;
    if (auth) acctSEPAuthContext =
        (void *)method_setImplementation(auth, (IMP)acctSEPAuthObserver);
    if (bag) acctSEPBag =
        (void *)method_setImplementation(bag, (IMP)acctSEPBagObserver);
    if (aks) acctAKSError =
        (void *)method_setImplementation(aks, (IMP)acctAKSErrorObserver);
    acctLog(@"ctk-installed", @{@"auth": @(auth != NULL),
        @"bag": @(bag != NULL), @"aks": @(aks != NULL)});
}

#pragma mark - AIDA service-owner observer (log only)

static id (*acctOwnerBundles)(id, SEL);
static id acctOwnerBundlesObserver(id receiver, SEL selector) {
    id original = acctOwnerBundles(receiver, selector);
    NSMutableArray *paths = [NSMutableArray array];
    for (id bundle in original) {
        NSString *path = [bundle respondsToSelector:@selector(bundlePath)]
            ? [bundle bundlePath] : nil;
        if (path) [paths addObject:path];
    }
    acctLog(@"owner-bundles", @{@"count": @(paths.count), @"paths": paths});
    return original;
}
static void installOwnerObserver(void) {
    Class manager = NSClassFromString(@"AIDAServiceOwnersManager");
    if (!manager) {
        dlopen("/System/Library/PrivateFrameworks/AppleIDSSOAuthentication"
               ".framework/AppleIDSSOAuthentication", RTLD_LAZY | RTLD_LOCAL);
        manager = NSClassFromString(@"AIDAServiceOwnersManager");
    }
    Method method = manager ? class_getClassMethod(
        manager, NSSelectorFromString(@"serviceOwnerBundles")) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) {
        acctLog(@"owner-install-skipped", @{});
        return;
    }
    acctOwnerBundles =
        (void *)method_setImplementation(method, (IMP)acctOwnerBundlesObserver);
    id registered = ((id (*)(id, SEL))objc_msgSend)(
        manager, NSSelectorFromString(@"supportedServices"));
    BOOL cloud = [registered respondsToSelector:@selector(containsObject:)] &&
        [registered containsObject:@"com.apple.AppleID.Service.Cloud"];
    acctLog(@"owner-installed", @{@"registered_cloud": @(cloud)});
}

#pragma mark - Image watchers

static unsigned acctInstalledMask;
static void acctInstallForImage(const char *name) {
    if (!name) return;
    if (strstr(name, "/AuthKitUI.framework/") && !(acctInstalledMask & 1)) {
        acctInstalledMask |= 1;
        installAuthKitWeb();
    } else if (strstr(name, "/LocalAuthentication.framework/") &&
               !(acctInstalledMask & 2)) {
        acctInstalledMask |= 2;
        installLocalAuthObservers();
    } else if (strstr(name, "/CryptoTokenKit.framework/") &&
               !(acctInstalledMask & 4)) {
        acctInstalledMask |= 4;
        installCryptoTokenKitObservers();
    } else if (strstr(name, "/AppleIDSSOAuthentication.framework/") &&
               !(acctInstalledMask & 8)) {
        acctInstalledMask |= 8;
        installOwnerObserver();
    }
}
static void acctImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    // Re-scan all image names so the match does not depend on the added
    // image's position; each framework's installer runs at most once.
    for (uint32_t i = 0; i < _dyld_image_count(); ++i)
        acctInstallForImage(_dyld_get_image_name(i));
}
__attribute__((constructor)) static void acctInit(void) {
    acctLog(@"loaded", @{});
    for (uint32_t i = 0; i < _dyld_image_count(); ++i)
        acctInstallForImage(_dyld_get_image_name(i));
    _dyld_register_func_for_add_image(acctImageAdded);
}
