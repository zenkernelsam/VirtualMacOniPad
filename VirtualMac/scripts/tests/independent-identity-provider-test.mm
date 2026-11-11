// Offline tests. The test-only transport rejects every request and never
// connects to Apple. Synthetic headers exercise only secure serialization.
#define VM_INDEPENDENT_PROVIDER_NO_MAIN 1
#define VM_INDEPENDENT_PROVIDER_TESTING 1
#include "../../vz/guest/independent-identity-provider.mm"

#define CHECK(expression) do { if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); return 1; } } while (0)
template <typename Operation> static bool VMFails(Operation operation) {
    try { operation(); } catch (...) { return true; }
    return false;
}
int main(void) { @autoreleasepool {
    umask(0077);
    char temporary[] = "/tmp/virtualmac-independent-tests.XXXXXX";
    CHECK(mkdtemp(temporary));
    VMFD root(open(temporary, O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    CHECK(root.value >= 0);
    NSString *machine = VMHash(@"synthetic-guest-machine:501");
    NSString *lookup = @"https://gsa.apple.com/grandslam/GsService2/lookup";
    CHECK(VMAllowedRequest(lookup, @"GET", @{}));
    CHECK(!VMAllowedRequest(@"https://gsa.apple.com.evil.invalid/grandslam/GsService2/lookup", @"GET", @{}));
    CHECK(!VMAllowedRequest(@"http://gsa.apple.com/grandslam/GsService2/lookup", @"GET", @{}));
    CHECK(!VMAllowedRequest([lookup stringByAppendingString:@"?x=1"], @"GET", @{}));
    CHECK(!VMAllowedRequest(@"https://gsa.apple.com/grandslam/GsService2/authenticate", @"POST", @{}));
    CHECK(!VMAllowedRequest(lookup, @"GET", @{@"Cookie":@"account=value"}));
    CHECK(!VMAllowedRequest(lookup, @"GET", @{@"x":@"bad\r\nheader"}));
    puts("PASS official account-free provisioning endpoints and safe headers only");

    setenv("VM_INDEPENDENT_TEST_TRANSPORT", "fail", 1);
    CHECK(VMFails([&]{ VMPrepareAtRoot(root.value, machine); }));
    NSString *pendingName = [@"vm-state-initializing-" stringByAppendingString:machine];
    VMFD pending(VMOpenDirectoryAt(root.value, pendingName, NO, YES));
    NSData *firstIdentity = VMReadAt(pending.value, @"identity.json");
    CHECK(firstIdentity.length > 0 && VMBound(pending.value, machine));
    CHECK(VMReadAt(pending.value, @"adi.pb", YES) == nil);
    CHECK(VMFails([&]{ VMPrepareAtRoot(root.value, machine); }));
    CHECK([firstIdentity isEqual:VMReadAt(pending.value, @"identity.json")]);
    CHECK(!VMBound(pending.value, VMHash(@"clone-machine:501")));
    puts("PASS failed/retried preparation preserves the exact pending identity and rejects clone binding");

    VMFD heldLock(VMLockAt(root.value, @".initialization-lock"));
    CHECK(VMFails([&]{ VMPrepareAtRoot(root.value, machine); }));
    CHECK([firstIdentity isEqual:VMReadAt(pending.value, @"identity.json")]);
    close(heldLock.value); heldLock.value = -1;
    puts("PASS competing preparation lock fails without replacing state");

    VMTransportContext expired = {VMMonotonic() - 1, YES, 0};
    aauth_http_request request = {lookup.UTF8String, "GET", "{}", nullptr, 0};
    aauth_http_response response = {};
    CHECK(VMTransport(&expired, &request, &response) == AAUTH_NETWORK_ERROR);
    VMTransportContext offline = {VMMonotonic() + 110, NO, 0};
    CHECK(VMTransport(&offline, &request, &response) == AAUTH_NETWORK_ERROR && offline.requests == 0);
    puts("PASS expired preparation budget and offline transport deny HTTP");

    VMWriteAt(pending.value, @"adi.pb", [@"not-an-ADI-profile" dataUsingEncoding:NSUTF8StringEncoding]);
    VMClient corrupt;
    CHECK(VMFails([&]{ VMCreateClient(corrupt, VMSnapshot(pending.value, YES), &offline); }));
    CHECK(offline.requests == 0 && [firstIdentity isEqual:VMReadAt(pending.value, @"identity.json")]);
    puts("PASS malformed ADI state fails closed without network or identity replacement");

    CHECK(symlinkat("identity.json", pending.value, "unsafe-link") == 0);
    CHECK(VMFails([&]{ (void)VMReadAt(pending.value, @"unsafe-link"); }));
    CHECK(fchmodat(pending.value, "identity.json", 0644, 0) == 0);
    CHECK(VMFails([&]{ (void)VMReadAt(pending.value, @"identity.json"); }));
    CHECK(fchmodat(pending.value, "identity.json", 0600, 0) == 0);
    puts("PASS symlink and public state permissions are rejected");

    VMProvisionHTTP *http = [VMProvisionHTTP new];
    __block NSURLRequest *redirect = [NSURLRequest requestWithURL:[NSURL URLWithString:lookup]];
    NSURLSession *unusedSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSURLSessionDataTask *unstartedTask = [unusedSession dataTaskWithRequest:redirect];
    NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc] initWithURL:redirect.URL
        statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [http URLSession:unusedSession task:unstartedTask willPerformHTTPRedirection:redirectResponse newRequest:redirect
        completionHandler:^(NSURLRequest *value) { redirect = value; }];
    CHECK(http.rejected && redirect == nil);
    [unusedSession invalidateAndCancel];
    puts("PASS HTTPS redirect delegate rejects replacement requests");

    unsigned char token[32]; memset(token, 0x5a, sizeof token);
    unsigned char wire[33]; memcpy(wire, token, 32); wire[32] = 'P';
    int pair[2]; CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    VMFD peer(pair[0]), reader(pair[1]);
    CHECK(write(peer.value, wire, sizeof wire) == sizeof wire);
    CHECK(VMReadAuthenticatedRequest(reader.value, token));
    wire[0] ^= 1;
    CHECK(write(peer.value, wire, sizeof wire) == sizeof wire);
    CHECK(!VMReadAuthenticatedRequest(reader.value, token));
    wire[0] ^= 1; wire[32] = 'Q';
    CHECK(write(peer.value, wire, sizeof wire) == sizeof wire);
    CHECK(!VMReadAuthenticatedRequest(reader.value, token));
    CHECK(write(peer.value, token, 8) == 8);
    close(peer.value); peer.value = -1;
    CHECK(!VMReadAuthenticatedRequest(reader.value, token));
    puts("PASS server accepts only the complete 32-byte token plus P request");

    NSString *mid = [@"M" stringByPaddingToLength:80 withString:@"M" startingAtIndex:0];
    NSString *otp = [@"O" stringByPaddingToLength:40 withString:@"O" startingAtIndex:0];
    NSDictionary *headers = @{@"X-Apple-I-MD-M":mid, @"X-Apple-I-MD":otp,
        @"X-Apple-I-MD-RINFO":@"123456", @"X-Apple-I-MD-LU":@"synthetic-local-user",
        @"X-Mme-Device-Id":@"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"};
    NSDictionary *payload = VMPayloadForHeaders(headers);
    NSData *frame = VMFrame(payload);
    CHECK(frame.length > 4);
    uint32_t length; memcpy(&length, frame.bytes, 4);
    CHECK(ntohl(length) + 4 == frame.length);
    NSDictionary *restored = [NSPropertyListSerialization propertyListWithData:
        [frame subdataWithRange:NSMakeRange(4, frame.length - 4)] options:0 format:nil error:nil];
    CHECK([restored[@"independentEnabled"] boolValue] &&
        [restored[@"nativeHeaders"] isEqual:headers] && [restored[@"anisetteArchive"] isKindOfClass:NSData.class]);
    CHECK(VMFails([&]{ (void)VMPayloadForHeaders(@{}); }));
    puts("PASS real AKAnisetteData secure archive roundtrip and binary framed payload");
    printf("test evidence kept at %s; no accounts or network used\n", temporary);
    return 0;
} }
