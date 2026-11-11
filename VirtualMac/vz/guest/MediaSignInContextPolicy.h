// Diagnostic credential staging must name both the account and the media
// caller. Unknown contexts and background IDMS requests never consume it.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
static BOOL VMMediaContextMatches(id context, NSString *email, NSString *bundle) {
    NSSet *media = [NSSet setWithArray:@[@"com.apple.AppStore", @"com.apple.Music", @"com.apple.TV"]];
    if (!email.length || ![media containsObject:bundle]) return NO;
    NSArray *selectors = @[@"username", @"proxiedAppBundleID", @"clientBundleID",
        @"_proxiedBundleID", @"proxiedBundleID"];
    BOOL userMatches = NO, callerMatches = NO;
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([context class], selector);
        char result[16] = {0};
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        method_getReturnType(method, result, sizeof(result));
        if (strcmp(result, "@")) continue;
        id value = ((id(*)(id,SEL))objc_msgSend)(context,selector);
        if (![value isKindOfClass:NSString.class]) continue;
        if ([name isEqual:@"username"]) userMatches = [value isEqual:email];
        else if ([value isEqual:bundle]) callerMatches = YES;
    }
    return userMatches && callerMatches;
}
