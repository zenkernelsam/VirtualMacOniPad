// Fixtures only: no AuthKit authentication, personal identity or account data.
#import <Foundation/Foundation.h>
#include "../../vz/guest/IndependentIdentityClient.h"

static int check(BOOL condition, const char *name) {
    if (!condition) fprintf(stderr, "FAIL %s\n", name);
    return condition ? 0 : 1;
}

static int mergeChecks(void) {
    NSString *mid = [@"" stringByPaddingToLength:80 withString:@"A" startingAtIndex:0];
    NSString *otp = [@"" stringByPaddingToLength:40 withString:@"B" startingAtIndex:0];
    NSDictionary *headers = @{@"X-Apple-I-MD-M":mid, @"X-Apple-I-MD":otp,
        @"X-Apple-I-MD-RINFO":@"1234", @"X-Apple-I-MD-LU":@"local-fixture",
        @"X-Mme-Device-Id":@"device-fixture"};
    NSDictionary *payload = @{@"nativeHeaders":headers};
    NSDictionary *original = @{@"x-apple-i-md-m":@"old-fixture",
        @"X-APPLE-I-MD-M":@"duplicate-fixture", @"x-apple-i-md":@"old-fixture",
        @"Authorization":@"authorization-fixture", @"User-Agent":@"agent-fixture",
        @"X-Unrelated":@"keep-fixture"};
    NSError *error = nil;
    NSDictionary *result = VMIdentityMergeHeaders(original, payload, &error);
    int failures = check(result && !error && result.count == 8, "merged-shape");
    failures += check(!result[@"x-apple-i-md-m"] && !result[@"X-APPLE-I-MD-M"] &&
        !result[@"x-apple-i-md"], "case-insensitive-replacement");
    for (NSString *key in headers)
        failures += check([result[key] isEqual:headers[key]], "canonical-field");
    for (NSString *key in @[@"Authorization", @"User-Agent", @"X-Unrelated"])
        failures += check([result[key] isEqual:original[key]], "unrelated-field-preserved");
    failures += check(original.count == 6 && [original[@"x-apple-i-md-m"] isEqual:@"old-fixture"],
                      "input-not-mutated");
    NSMutableDictionary *incomplete = [headers mutableCopy];
    [incomplete removeObjectForKey:@"X-Apple-I-MD-M"];
    error = nil;
    failures += check(!VMIdentityMergeHeaders(original, @{@"nativeHeaders":incomplete}, &error)
                      && error.code == 2, "missing-field-rejected");
    error = nil;
    failures += check(!VMIdentityMergeHeaders(original, @{@"nativeHeaders":@[]}, &error)
                      && error.code == 2, "wrong-headers-type-rejected");
    error = nil;
    failures += check(!VMIdentityMergeHeaders(nil, payload, &error) && error.code == 2,
                      "missing-original-rejected");
    error = nil;
    @try {
        failures += check(!VMIdentityMergeHeaders(original, (NSDictionary *)@[], &error)
                          && error.code == 2, "wrong-payload-type-rejected");
    } @catch (NSException *exception) {
        (void)exception;
        failures += check(NO, "wrong-payload-type-raised-exception");
    }
    setenv("VM_INDEPENDENT_IDENTITY", "1", 1);
    failures += check(VMIndependentEnabled(), "exact-one-enabled");
    setenv("VM_INDEPENDENT_IDENTITY", "true", 1);
    failures += check(!VMIndependentEnabled(), "other-values-disabled");
    unsetenv("VM_INDEPENDENT_IDENTITY");
    failures += check(!VMIndependentEnabled(), "absent-disabled");
    failures += check(!VMIdentityAnisette(nil, NULL), "missing-archive-unavailable");
    return failures ? 1 : 0;
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1], "merge")) return mergeChecks();
    if (argc != 3 || strcmp(argv[1], "fetch")) return 64;
    NSError *error = nil;
    NSDictionary *payload = VMIdentityPayload(&error);
    BOOL success = !strcmp(argv[2], "success");
    if (success) return check(payload && !error, "framed-payload-received");
    return check(!payload && [error.domain isEqual:@"VirtualMacIndependentIdentity"]
                 && error.code == 1, "provider-failure-closed");
} }
