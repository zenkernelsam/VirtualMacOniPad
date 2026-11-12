// Account-free independent ADI provider. Only --prepare may contact Apple;
// --payload/--serve import an immutable local snapshot with networking denied.
// No passwords, account sessions, iPad identity, or SDK login APIs are used.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <apple_auth/client_c_api.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdexcept>
#include <string>

static constexpr size_t VMStateLimit = 16 * 1024 * 1024;
static constexpr size_t VMPayloadLimit = 65536;
static void VMRequire(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
struct VMFD {
    int value = -1;
    explicit VMFD(int fd = -1) : value(fd) {}
    ~VMFD() { if (value >= 0) close(value); }
    VMFD(const VMFD &) = delete;
    VMFD &operator=(const VMFD &) = delete;
};
struct VMClient {
    aauth_client *value = nullptr;
    ~VMClient() { if (value) aauth_client_free(value); }
    VMClient() = default;
    VMClient(const VMClient &) = delete;
    VMClient &operator=(const VMClient &) = delete;
};
static NSData *VMJSONData(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    VMRequire(data != nil, "json-encoding-failed");
    return data;
}
static id VMJSON(NSData *data) {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    VMRequire(object != nil, "invalid-state-json");
    return object;
}
static NSString *VMHash(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *result = [NSMutableString string];
    for (unsigned char byte : hash) [result appendFormat:@"%02x", byte];
    return result;
}
static NSString *VMMachineHash(void) {
    io_service_t platform = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice"));
    VMRequire(platform != IO_OBJECT_NULL, "machine-binding-unavailable");
    CFTypeRef uuid = IORegistryEntryCreateCFProperty(platform, CFSTR("IOPlatformUUID"),
        kCFAllocatorDefault, 0);
    IOObjectRelease(platform);
    NSString *value = CFBridgingRelease(uuid);
    VMRequire([value isKindOfClass:NSString.class] && value.length >= 32,
        "machine-binding-unavailable");
    return VMHash([NSString stringWithFormat:@"%@:%u", value, getuid()]);
}
static BOOL VMResetRequired(void) {
    NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:
        @"/Library/VirtualMac/HostConfiguration.plist"];
    return [configuration[@"AppleServicesIdentityResetRequired"] boolValue];
}
static void VMCheckPrivate(int descriptor, BOOL directory) {
    struct stat status;
    VMRequire(fstat(descriptor, &status) == 0 && status.st_uid == getuid() &&
        (directory ? S_ISDIR(status.st_mode) : S_ISREG(status.st_mode)) &&
        (status.st_mode & 077) == 0 && (directory || status.st_nlink == 1),
        "unsafe-state-permissions");
}
static int VMOpenDirectoryAt(int parent, NSString *name, BOOL create, BOOL privateDirectory) {
    VMRequire(name.length && ![name containsString:@"/"] &&
        ![name isEqual:@"."] && ![name isEqual:@".."], "unsafe-state-name");
    if (create && mkdirat(parent, name.fileSystemRepresentation, 0700) != 0)
        VMRequire(errno == EEXIST, "state-directory-creation-failed");
    int descriptor = openat(parent, name.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    VMRequire(descriptor >= 0, "state-directory-unavailable");
    if (privateDirectory) {
        try { VMCheckPrivate(descriptor, YES); }
        catch (...) { close(descriptor); throw; }
    }
    return descriptor;
}
static int VMOpenRoot(BOOL create) {
    // Walk every ancestor without following symlinks. Only the application
    // directory itself is required to be private; normal home ancestors may
    // have the user's conventional directory permissions.
    VMFD root(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    VMRequire(root.value >= 0, "home-unavailable");
    for (NSString *component in [NSHomeDirectory() pathComponents]) {
        if ([component isEqual:@"/"]) continue;
        int next = VMOpenDirectoryAt(root.value, component, NO, NO);
        close(root.value); root.value = next;
    }
    for (NSString *component in @[@"Library", @"Application Support"] ) {
        int next = VMOpenDirectoryAt(root.value, component, create, NO);
        close(root.value); root.value = next;
    }
    return VMOpenDirectoryAt(root.value, @"VirtualMacIndependentIdentity", create, YES);
}
static NSData *VMReadAt(int directory, NSString *name, BOOL optional = NO) {
    VMFD file(openat(directory, name.fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (file.value < 0 && optional && errno == ENOENT) return nil;
    VMRequire(file.value >= 0, "state-file-unavailable");
    VMCheckPrivate(file.value, NO);
    struct stat status;
    VMRequire(fstat(file.value, &status) == 0 && status.st_size > 0 &&
        (uint64_t)status.st_size <= VMStateLimit, "state-file-size-invalid");
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    size_t done = 0;
    while (done < data.length) {
        ssize_t count = read(file.value, (char *)data.mutableBytes + done, data.length - done);
        if (count < 0 && errno == EINTR) continue;
        VMRequire(count > 0, "state-read-failed"); done += (size_t)count;
    }
    return data;
}
static void VMWriteAt(int directory, NSString *name, NSData *data) {
    VMRequire(data.length > 0 && data.length <= VMStateLimit, "state-write-size-invalid");
    NSString *temporary = [@".pending-" stringByAppendingString:NSUUID.UUID.UUIDString];
    VMFD file(openat(directory, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    VMRequire(file.value >= 0, "state-write-open-failed");
    size_t done = 0;
    while (done < data.length) {
        ssize_t count = write(file.value, (const char *)data.bytes + done, data.length - done);
        if (count < 0 && errno == EINTR) continue;
        VMRequire(count > 0, "state-write-failed"); done += (size_t)count;
    }
    VMRequire(fsync(file.value) == 0 &&
        renameat(directory, temporary.fileSystemRepresentation,
                 directory, name.fileSystemRepresentation) == 0 && fsync(directory) == 0,
        "state-publish-failed");
}
static int VMLockAt(int directory, NSString *name) {
    int descriptor = openat(directory, name.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    VMRequire(descriptor >= 0, "state-lock-unavailable");
    try {
        VMCheckPrivate(descriptor, NO);
        VMRequire(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "state-busy");
    } catch (...) { close(descriptor); throw; }
    return descriptor;
}
static NSString *VMActiveState(int root) {
    NSData *marker = VMReadAt(root, @"active-state.json", YES);
    if (!marker) return @"vm-state-a";
    id dictionary = VMJSON(marker);
    NSString *name = [dictionary isKindOfClass:NSDictionary.class] ? dictionary[@"state"] : nil;
    VMRequire([name isKindOfClass:NSString.class] && [name hasPrefix:@"vm-state-"] &&
        [name rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet]].location == NSNotFound &&
        name.length < 100, "invalid-active-state");
    return name;
}
static BOOL VMBound(int state, NSString *machine) {
    NSData *data = VMReadAt(state, @"machine-binding.json", YES);
    if (!data) return NO;
    id binding = VMJSON(data);
    return [binding isKindOfClass:NSDictionary.class] &&
        [binding[@"version"] isEqual:@1] && [binding[@"machineHash"] isEqual:machine];
}
static NSData *VMSnapshot(int state, BOOL complete) {
    NSData *identity = VMReadAt(state, @"identity.json", !complete);
    NSData *adi = VMReadAt(state, @"adi.pb", !complete);
    VMRequire(identity || !adi, "identity-missing-beside-profile");
    if (!identity) return nil;
    VMRequire([VMJSON(identity) isKindOfClass:NSDictionary.class], "invalid-identity-json");
    NSMutableDictionary *files = [NSMutableDictionary dictionaryWithObject:
        [identity base64EncodedStringWithOptions:0] forKey:@"identity.json"];
    if (adi) files[@"adi.pb"] = [adi base64EncodedStringWithOptions:0];
    return VMJSONData(@{@"kind":@"apple-auth-state", @"version":@1, @"files":files});
}
static void VMSaveSnapshot(aauth_client *client, int state) {
    aauth_client_buffer buffer = {};
    VMRequire(aauth_client_state(client, &buffer) == AAUTH_OK, "sdk-state-export-failed");
    NSData *data = [NSData dataWithBytes:buffer.data length:buffer.size];
    aauth_client_buffer_free(&buffer);
    id snapshot = VMJSON(data);
    id files = snapshot[@"files"];
    VMRequire([files isKindOfClass:NSDictionary.class], "sdk-state-export-invalid");
    for (NSString *name in @[@"identity.json", @"adi.pb"]) {
        NSString *value = files[name];
        if (!value) continue;
        VMRequire([value isKindOfClass:NSString.class], "sdk-state-export-invalid");
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:value options:0];
        VMWriteAt(state, name, decoded);
    }
}

static BOOL VMAllowedRequest(NSString *urlString, NSString *method, NSDictionary *headers) {
    NSURLComponents *url = [NSURLComponents componentsWithString:urlString];
    NSSet *hosts = [NSSet setWithArray:@[@"gsa.apple.com", @"gsas.apple.com"]];
    NSSet *paths = [NSSet setWithArray:@[@"/grandslam/GsService2/lookup",
        @"/grandslam/MidService/startMachineProvisioning",
        @"/grandslam/MidService/finishMachineProvisioning"]];
    if (![url.scheme isEqual:@"https"] || ![hosts containsObject:url.host.lowercaseString] ||
        (url.port && url.port.integerValue != 443) || url.user || url.password ||
        url.query || url.fragment || ![paths containsObject:url.percentEncodedPath] ||
        ![@[@"GET", @"POST"] containsObject:method] ||
        ![headers isKindOfClass:NSDictionary.class]) return NO;
    for (id key in headers) {
        id value = headers[key];
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] ||
            [@[@"authorization", @"cookie", @"proxy-authorization"] containsObject:[key lowercaseString]] ||
            [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
            [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
            return NO;
    }
    return YES;
}
@interface VMProvisionHTTP : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSHTTPURLResponse *response;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) BOOL rejected;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end
@implementation VMProvisionHTTP
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    (void)session; (void)task; (void)response; (void)request;
    self.rejected = YES; completion(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session; (void)task;
    self.response = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    BOOL accepted = self.response && response.expectedContentLength <= (int64_t)VMStateLimit;
    if (!accepted) self.rejected = YES;
    completion(accepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (data.length > VMStateLimit - self.body.length) { self.rejected = YES; [task cancel]; }
    else [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task; self.error = error; dispatch_semaphore_signal(self.done);
}
@end
struct VMTransportContext { double deadline; BOOL network; unsigned requests = 0; };
static double VMMonotonic(void) { return NSProcessInfo.processInfo.systemUptime; }
static int VMTransport(void *opaque, const aauth_http_request *request, aauth_http_response *response) {
    VMTransportContext *context = (VMTransportContext *)opaque;
    @autoreleasepool {
        try {
            VMRequire(context->network && request && response && request->url &&
                request->method && request->headers_json && request->body_size <= VMStateLimit &&
                (!request->body_size || request->body), "offline-network-denied");
            VMRequire(++context->requests <= 3 && context->deadline > VMMonotonic(), "preparation-budget-exhausted");
            NSDictionary *headers = VMJSON([NSData dataWithBytes:request->headers_json
                length:strlen(request->headers_json)]);
            NSString *url = @(request->url), *method = @(request->method);
            NSURLComponents *endpoint = [NSURLComponents componentsWithString:url];
            fprintf(stderr,"independent-identity: provisioning phase=%u host=%s path=%s\n",
                context->requests, endpoint.host.UTF8String ?: "", endpoint.path.UTF8String ?: "");
            VMRequire(VMAllowedRequest(url, method, headers), "provisioning-endpoint-rejected");
#ifdef VM_INDEPENDENT_PROVIDER_TESTING
            const char *test = getenv("VM_INDEPENDENT_TEST_TRANSPORT");
            if (test) return AAUTH_NETWORK_ERROR; // Never present in the production binary.
#endif
            NSTimeInterval budget = MIN(30.0, context->deadline - VMMonotonic());
            VMRequire(budget > 0, "preparation-budget-exhausted");
            NSMutableURLRequest *native = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:budget];
            native.HTTPMethod = method; native.allHTTPHeaderFields = headers;
            if (request->body_size) native.HTTPBody = [NSData dataWithBytes:request->body length:request->body_size];
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.timeoutIntervalForRequest = budget;
            configuration.timeoutIntervalForResource = budget;
            configuration.HTTPShouldSetCookies = NO; configuration.HTTPCookieStorage = nil;
            configuration.URLCredentialStorage = nil; configuration.URLCache = nil;
            VMProvisionHTTP *delegate = [VMProvisionHTTP new];
            delegate.body = [NSMutableData data]; delegate.done = dispatch_semaphore_create(0);
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:native];
            [task resume];
            long waited = dispatch_semaphore_wait(delegate.done,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC)));
            if (waited) { [task cancel]; [session invalidateAndCancel]; return AAUTH_NETWORK_ERROR; }
            [session finishTasksAndInvalidate];
            fprintf(stderr,"independent-identity: provisioning response=%ld transportCode=%ld\n",
                (long)delegate.response.statusCode, (long)delegate.error.code);
            VMRequire(!delegate.error && !delegate.rejected && delegate.response.statusCode == 200,
                "verified-https-failed");
            NSMutableArray *pairs = [NSMutableArray array];
            for (NSString *name in delegate.response.allHeaderFields)
                [pairs addObject:@[name, [delegate.response.allHeaderFields[name] description]]];
            NSData *headerData = VMJSONData(pairs);
            response->status = delegate.response.statusCode;
            VMRequire(aauth_client_buffer_alloc(delegate.body.length, &response->body) == AAUTH_OK &&
                aauth_client_buffer_alloc(headerData.length, &response->headers_json) == AAUTH_OK,
                "transport-allocation-failed");
            memcpy(response->body.data, delegate.body.bytes, delegate.body.length);
            memcpy(response->headers_json.data, headerData.bytes, headerData.length);
            return AAUTH_OK;
        } catch (const std::exception &error) {
            fprintf(stderr,"independent-identity: provisioning failure=%s\n",error.what());
            return AAUTH_NETWORK_ERROR;
        }
    }
}
static void VMCreateClient(VMClient &client, NSData *snapshot, VMTransportContext *context) {
    aauth_client_options options = {}; options.transport = VMTransport; options.context = context;
    aauth_client_config config = {}; config.options = &options;
    config.platform = snapshot ? AAUTH_DEVICE_AUTOMATIC : AAUTH_DEVICE_MAC;
    aauth_mac_device mac = {"Mac14,2", "15.6.1", "24G90"};
    if (!snapshot) config.mac_device = &mac;
    config.state = (const uint8_t *)snapshot.bytes; config.state_size = snapshot.length;
    VMRequire(aauth_client_create(&config, &client.value) == AAUTH_OK, "invalid-sdk-state");
    aauth_device_platform platform;
    VMRequire(aauth_client_device_platform(client.value, &platform) == AAUTH_OK &&
        platform == AAUTH_DEVICE_MAC, "state-is-not-mac-profile");
}
@interface NSObject (VMAnisetteAccess)
- (void)setMachineID:(NSString *)value;
- (void)setOneTimePassword:(NSString *)value;
- (void)setRoutingInfo:(unsigned long long)value;
- (NSString *)machineID;
- (NSString *)oneTimePassword;
- (unsigned long long)routingInfo;
@end
static NSDictionary *VMPayloadForHeaders(NSDictionary *headers) {
    NSMutableDictionary *selected = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-RINFO",
                           @"X-Apple-I-MD-LU", @"X-Mme-Device-Id"]) {
        id value = headers[key];
        VMRequire([value isKindOfClass:NSString.class] && [value length] > 0 &&
            [value length] < 1024, "incomplete-native-headers");
        selected[key] = value;
    }
    NSString *machine = selected[@"X-Apple-I-MD-M"], *otp = selected[@"X-Apple-I-MD"];
    NSString *routing = selected[@"X-Apple-I-MD-RINFO"];
    VMRequire(machine.length == 80 && otp.length == 40, "invalid-anisette-shape");
    NSScanner *scanner = [NSScanner scannerWithString:routing]; unsigned long long routingValue;
    VMRequire([scanner scanUnsignedLongLong:&routingValue] && scanner.isAtEnd,
        "invalid-routing-info");
    VMRequire(dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW) != NULL,
        "authkit-unavailable");
    Class klass = NSClassFromString(@"AKAnisetteData");
    VMRequire(klass && [klass supportsSecureCoding], "secure-anisette-class-unavailable");
    id object = [klass new];
    [object setMachineID:machine]; [object setOneTimePassword:otp]; [object setRoutingInfo:routingValue];
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
    id restored = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:klass fromData:archive error:&error] : nil;
    VMRequire(restored && !error && [[restored machineID] isEqual:machine] &&
        [[restored oneTimePassword] isEqual:otp] && [restored routingInfo] == routingValue,
        "secure-archive-roundtrip-failed");
    return @{@"independentEnabled":@YES, @"anisetteArchive":archive, @"nativeHeaders":selected};
}
static NSDictionary *VMLoadStatePayload(int root, NSString *active, NSString *machine) {
    VMFD state(VMOpenDirectoryAt(root, active, NO, YES));
    // All states require a stable local binding. This also makes a stale host
    // reset marker harmless after explicit preparation of the replacement.
    VMRequire(VMBound(state.value, machine), VMResetRequired() ? "identity-reset-needs-preparation" : "state-unbound-or-cloned");
    VMFD lock(VMLockAt(state.value, @".provider-lock"));
    NSData *snapshot = VMSnapshot(state.value, YES);
    VMTransportContext context = {0, NO, 0}; VMClient client;
    VMCreateClient(client, snapshot, &context);
    aauth_client_buffer buffer = {};
    VMRequire(aauth_client_headers(client.value, &buffer) == AAUTH_OK && context.requests == 0,
        "offline-payload-unavailable");
    NSData *data = [NSData dataWithBytes:buffer.data length:buffer.size];
    aauth_client_buffer_free(&buffer);
    return VMPayloadForHeaders(VMJSON(data));
}
static NSDictionary *VMLoadPayload(int root, NSString *machine) {
    return VMLoadStatePayload(root, VMActiveState(root), machine);
}
static void VMPrepareAtRoot(int root, NSString *machine) {
    VMFD lock(VMLockAt(root, @".initialization-lock"));
    NSString *active = VMActiveState(root);
    struct stat existing;
    BOOL exists = fstatat(root, active.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) == 0;
    if (exists) {
        VMFD state(VMOpenDirectoryAt(root, active, NO, YES));
        if (VMBound(state.value, machine)) { (void)VMLoadPayload(root, machine); return; }
        // Preserve every legacy or cloned state. Never attach a new machine
        // binding to somebody else's unbound ADI identity.
    }
    NSString *destination = exists ? [@"vm-state-" stringByAppendingString:machine] : @"vm-state-a";
    // Recover a completed rename if publishing the active selector was
    // interrupted. Validate the existing replacement; never overwrite it.
    struct stat completed;
    if (fstatat(root, destination.fileSystemRepresentation, &completed, AT_SYMLINK_NOFOLLOW) == 0) {
        (void)VMLoadStatePayload(root, destination, machine);
        VMWriteAt(root, @"active-state.json", VMJSONData(@{@"state":destination}));
        return;
    }
    NSString *pendingName = [@"vm-state-initializing-" stringByAppendingString:machine];
    VMFD pending(VMOpenDirectoryAt(root, pendingName, YES, YES));
    NSData *binding = VMReadAt(pending.value, @"machine-binding.json", YES);
    if (binding) VMRequire(VMBound(pending.value, machine), "pending-state-binding-mismatch");
    else VMWriteAt(pending.value, @"machine-binding.json", VMJSONData(@{@"version":@1, @"machineHash":machine}));
    VMFD providerLock(VMLockAt(pending.value, @".provider-lock"));
    VMTransportContext context = {VMMonotonic() + 110.0, YES, 0}; VMClient client;
    VMCreateClient(client, VMSnapshot(pending.value, NO), &context);
    VMSaveSnapshot(client.value, pending.value); // Commit random identity before any HTTP.
    aauth_status provisioned = aauth_client_provision(client.value);
    VMSaveSnapshot(client.value, pending.value); // Preserve completed progress even on error.
    VMRequire(provisioned == AAUTH_OK && VMMonotonic() <= context.deadline, "preparation-failed-pending-preserved");
    (void)VMSnapshot(pending.value, YES);
    aauth_client_buffer headers = {};
    VMRequire(aauth_client_headers(client.value, &headers) == AAUTH_OK, "prepared-headers-invalid");
    NSData *headerData = [NSData dataWithBytes:headers.data length:headers.size];
    aauth_client_buffer_free(&headers); (void)VMPayloadForHeaders(VMJSON(headerData));
    struct stat target;
    VMRequire(fstatat(root, destination.fileSystemRepresentation, &target, AT_SYMLINK_NOFOLLOW) != 0 &&
        errno == ENOENT, "replacement-state-already-exists");
    VMRequire(renameat(root, pendingName.fileSystemRepresentation,
        root, destination.fileSystemRepresentation) == 0 && fsync(root) == 0,
        "prepared-state-publication-failed");
    VMWriteAt(root, @"active-state.json", VMJSONData(@{@"state":destination}));
}
static void VMPrepare(void) {
    VMFD root(VMOpenRoot(YES)); VMPrepareAtRoot(root.value, VMMachineHash());
}
static NSData *VMFrame(NSDictionary *payload) {
    NSData *body = [NSPropertyListSerialization dataWithPropertyList:payload
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    VMRequire(body.length > 0 && body.length <= VMPayloadLimit, "payload-size-invalid");
    uint32_t length = htonl((uint32_t)body.length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&length length:4];
    [frame appendData:body]; return frame;
}
static BOOL VMWriteAll(int descriptor, NSData *data) {
    size_t done = 0;
    while (done < data.length) {
        ssize_t count = write(descriptor, (const char *)data.bytes + done, data.length - done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO; done += (size_t)count;
    }
    return YES;
}
static BOOL VMReadAuthenticatedRequest(int descriptor, const unsigned char token[32]) {
    unsigned char request[33]; size_t done = 0;
    double deadline = VMMonotonic() + 2.0;
    while (done < sizeof request) {
        double remaining = deadline - VMMonotonic();
        if (remaining <= 0) return NO;
        struct timeval timeout = {(time_t)remaining, (suseconds_t)((remaining - (time_t)remaining) * 1000000)};
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
        ssize_t count = read(descriptor, request + done, sizeof request - done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO; done += (size_t)count;
    }
    unsigned difference = 0;
    for (size_t i = 0; i < 32; ++i) difference |= token[i] ^ request[i];
    return difference == 0 && request[32] == 'P';
}
static void VMServe(void) {
    const char *tokenText = getenv("VM_INDEPENDENT_IDENTITY_TOKEN");
    VMRequire(tokenText && strlen(tokenText) == 64, "server-token-invalid");
    unsigned char token[32];
    for (size_t i = 0; i < 32; ++i) {
        int high = tokenText[2*i], low = tokenText[2*i+1];
        auto hex = [](int c) { return c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; };
        VMRequire(hex(high) >= 0 && hex(low) >= 0, "server-token-invalid");
        token[i] = (unsigned char)((hex(high) << 4) | hex(low));
    }
    // Preparation is explicit and separate from server startup and requests.
    VMFD root(VMOpenRoot(NO)); NSString *machine = VMMachineHash();
    (void)VMLoadPayload(root.value, machine);
    VMFD listener(socket(AF_INET, SOCK_STREAM, 0));
    VMRequire(listener.value >= 0, "server-socket-failed");
    fcntl(listener.value, F_SETFD, FD_CLOEXEC);
    struct sockaddr_in address = {}; address.sin_len = sizeof address;
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const char *requested = getenv("VM_INDEPENDENT_IDENTITY_PORT");
    if (requested && *requested) {
        char *end = nullptr; long port = strtol(requested, &end, 10);
        VMRequire(end && !*end && port >= 1024 && port <= 65535, "server-port-invalid");
        address.sin_port = htons((uint16_t)port);
    }
    VMRequire(bind(listener.value, (struct sockaddr *)&address, sizeof address) == 0 &&
        listen(listener.value, 8) == 0, "server-bind-failed");
    socklen_t size = sizeof address;
    VMRequire(getsockname(listener.value, (struct sockaddr *)&address, &size) == 0, "server-port-unavailable");
    printf("%u\n", ntohs(address.sin_port)); fflush(stdout);
    for (;;) { @autoreleasepool {
        VMFD connection(accept(listener.value, nullptr, nullptr));
        if (connection.value < 0) { if (errno == EINTR) continue; throw std::runtime_error("server-accept-failed"); }
        fcntl(connection.value, F_SETFD, FD_CLOEXEC);
        struct timeval timeout = {2, 0};
        setsockopt(connection.value, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        if (!VMReadAuthenticatedRequest(connection.value, token)) continue;
        try { (void)VMWriteAll(connection.value, VMFrame(VMLoadPayload(root.value, machine))); }
        catch (...) { uint32_t zero = 0; (void)write(connection.value, &zero, sizeof zero); }
    }}
}
#ifndef VM_INDEPENDENT_PROVIDER_NO_MAIN
int main(int argc, const char **argv) { @autoreleasepool {
    umask(0077); signal(SIGPIPE, SIG_IGN);
    if (argc != 2) return 64;
    std::string command(argv[1]);
    if (command == "--status") {
        BOOL bound = NO, ready = NO;
        try {
            NSString *machine = VMMachineHash(); VMFD root(VMOpenRoot(NO));
            VMFD state(VMOpenDirectoryAt(root.value, VMActiveState(root.value), NO, YES));
            bound = VMBound(state.value, machine);
            if (bound) { (void)VMLoadPayload(root.value, machine); ready = YES; }
        } catch (...) {}
        NSData *report = VMJSONData(@{@"ready":@(ready), @"bound":@(bound), @"needsPreparation":@(!ready)});
        (void)VMWriteAll(STDOUT_FILENO, report); puts(""); return 0;
    }
    @try { try {
        if (command == "--prepare") { VMPrepare(); puts("prepared"); return 0; }
        if (command == "--payload") {
            VMFD root(VMOpenRoot(NO));
            VMRequire(VMWriteAll(STDOUT_FILENO, VMFrame(VMLoadPayload(root.value, VMMachineHash()))), "payload-write-failed");
            return 0;
        }
        if (command == "--serve") { VMServe(); return 0; }
        return 64;
    } catch (const std::exception &error) {
        fprintf(stderr, "independent-identity: %s\n", error.what()); return 1;
    } } @catch (__unused NSException *error) {
        fputs("independent-identity: native-operation-failed\n", stderr); return 1;
    }
} }
#endif
