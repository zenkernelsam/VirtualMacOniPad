#import "../../vz/guest/MediaSignInContextPolicy.h"
@interface TestMediaContext : NSObject
@property(nonatomic, strong) id username;
@property(nonatomic, strong) id proxiedAppBundleID;
@end
@implementation TestMediaContext
@end
@interface TestScalarContext : NSObject
- (id)username;
- (BOOL)clientBundleID;
@end
@implementation TestScalarContext
- (id)username { return @"synthetic@example.invalid"; }
- (BOOL)clientBundleID { return YES; }
@end
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); return 1; } } while (0)
int main(void) { @autoreleasepool {
    NSString *email = @"synthetic@example.invalid";
    TestMediaContext *context = [TestMediaContext new]; context.username = email;
    // Same username in background IDMS is insufficient to consume a password.
    CHECK(!VMMediaContextMatches(context,email,@"com.apple.AppStore"));
    context.proxiedAppBundleID = @"com.apple.appleaccountd";
    CHECK(!VMMediaContextMatches(context,email,@"com.apple.AppStore"));
    context.proxiedAppBundleID = @"com.apple.AppStore";
    CHECK(VMMediaContextMatches(context,email,@"com.apple.AppStore"));
    CHECK(!VMMediaContextMatches(context,@"other@example.invalid",@"com.apple.AppStore"));
    CHECK(!VMMediaContextMatches(context,email,@"com.apple.Music"));
    CHECK(!VMMediaContextMatches(context,email,@"com.apple.appleaccountd"));
    CHECK(!VMMediaContextMatches(context,nil,@"com.apple.AppStore"));
    context.proxiedAppBundleID = @42;
    CHECK(!VMMediaContextMatches(context,email,@"com.apple.AppStore"));
    CHECK(!VMMediaContextMatches([TestScalarContext new],email,@"com.apple.AppStore"));
    for (NSString *bundle in @[@"com.apple.Music",@"com.apple.TV"]) {
        context.proxiedAppBundleID = bundle;
        CHECK(VMMediaContextMatches(context,email,bundle));
    }
    puts("PASS media caller/account match; background, unknown ABI and unrelated apps rejected");
    return 0;
} }
