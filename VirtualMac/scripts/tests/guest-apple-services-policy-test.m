// Execute the real Guest Tools methods with a temporary plist and memory-only
// preferences. Environment changes, provider startup and AppKit UI are stubbed.
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *fixtureConfiguration;
static struct ifaddrs fixtureInterface;
static struct sockaddr_in fixtureAddress, fixtureMask;
static int fixtureGetIfaddrs(struct ifaddrs **interfaces) {
    *interfaces = &fixtureInterface;
    return 0;
}
static void fixtureFreeIfaddrs(struct ifaddrs *interfaces) { (void)interfaces; }
@interface NSDictionary (VMFixtureRead)
+ (instancetype)VMFixture_dictionaryWithContentsOfFile:(NSString *)path;
@end

#define getifaddrs fixtureGetIfaddrs
#define freeifaddrs fixtureFreeIfaddrs
#define dictionaryWithContentsOfFile VMFixture_dictionaryWithContentsOfFile
#define main unusedProductionGuestToolsMain
#include "../../vz/guest/VirtualMacGuestToolsApp.m"
#undef main
#undef dictionaryWithContentsOfFile
#undef freeifaddrs
#undef getifaddrs

@implementation NSDictionary (VMFixtureRead)
+ (instancetype)VMFixture_dictionaryWithContentsOfFile:(NSString *)path {
    (void)path;
    return [NSDictionary dictionaryWithContentsOfFile:fixtureConfiguration];
}
@end

@interface VMFixturePreferences : NSObject
@property(nonatomic, retain) NSMutableDictionary *values;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (BOOL)synchronize;
@end
@implementation VMFixturePreferences
- (id)init { if ((self = [super init])) self.values = [NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSString *)stringForKey:(NSString *)key { return self.values[key]; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = value; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (BOOL)synchronize { return YES; }
- (void)dealloc { [_values release]; [super dealloc]; }
@end

@interface VMFixtureDelegate : VMGuestToolsDelegate
@property(nonatomic, retain) VMFixturePreferences *fixturePreferences;
@property(nonatomic) NSUInteger environmentCalls;
@property(nonatomic) NSUInteger providerCalls;
@property(nonatomic) NSUInteger menuCalls;
@end
@implementation VMFixtureDelegate
- (NSUserDefaults *)preferences { return (NSUserDefaults *)self.fixturePreferences; }
- (void)applyOpenGL { self.environmentCalls++; }
- (void)startIndependentIdentity { self.providerCalls++; }
- (void)updateMenu { self.menuCalls++; }
- (void)dealloc { [_fixturePreferences release]; [super dealloc]; }
@end

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while (0)
static BOOL store(id token, id enabled) {
    return [@{@"ReadyToken":token, @"AppleServicesEnabled":enabled,
              @"OpenGLAcceleration":@YES, @"OpenGLAllowed":@YES,
              @"AppleServicesRelayToken":[@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],
              @"AppleServicesRelayHosts":@[@"192.168.64.1", @"192.168.68.66"]}
            writeToFile:fixtureConfiguration atomically:YES];
}
int main(void) { @autoreleasepool {
    char directory[] = "/tmp/virtualmac-guest-policy.XXXXXX";
    CHECK(mkdtemp(directory));
    fixtureConfiguration = [[NSString alloc] initWithFormat:@"%s/HostConfiguration.plist", directory];
    fixtureAddress.sin_len = sizeof(fixtureAddress); fixtureAddress.sin_family = AF_INET;
    fixtureMask.sin_len = sizeof(fixtureMask); fixtureMask.sin_family = AF_INET;
    CHECK(inet_pton(AF_INET, "192.168.68.59", &fixtureAddress.sin_addr) == 1);
    CHECK(inet_pton(AF_INET, "255.255.252.0", &fixtureMask.sin_addr) == 1);
    fixtureInterface.ifa_name = "en0"; fixtureInterface.ifa_flags = IFF_UP;
    fixtureInterface.ifa_addr = (void *)&fixtureAddress;
    fixtureInterface.ifa_netmask = (void *)&fixtureMask;

    VMFixturePreferences *preferences = [VMFixturePreferences new];
    VMFixtureDelegate *delegate = [VMFixtureDelegate new];
    // Production menuWillOpen only discards its parameter; an opaque fixture
    // avoids constructing any actual AppKit menu or opening a UI session.
    NSObject *fixtureMenu = [NSObject new];
    delegate.fixturePreferences = preferences;
    CHECK(store(@"boot-A", @YES));
    [delegate applyHostConfiguration];
    CHECK([preferences boolForKey:VMSEPBridgeKey]);
    CHECK([[preferences stringForKey:VMReadyTokenKey] isEqual:@"boot-A"]);
    CHECK([delegate.hostRelayAddress isEqual:@"192.168.68.66"]);

    // User disables adapters. Opening the real menu path must not undo it.
    [preferences setBool:NO forKey:VMSEPBridgeKey];
    [delegate menuWillOpen:(NSMenu *)fixtureMenu];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    CHECK(delegate.environmentCalls == 1 && delegate.providerCalls == 1 && delegate.menuCalls == 1);
    // A repair relaunch with the same persisted token must also preserve it.
    VMFixtureDelegate *relaunched = [VMFixtureDelegate new];
    relaunched.fixturePreferences = preferences;
    [relaunched applyHostConfiguration];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    CHECK([relaunched.readyToken isEqual:@"boot-A"]);

    CHECK(store(@"boot-B", @YES));
    [delegate applyHostConfiguration];
    CHECK([preferences boolForKey:VMSEPBridgeKey]);
    CHECK([[preferences stringForKey:VMReadyTokenKey] isEqual:@"boot-B"]);
    CHECK(store(@"boot-C", @NO));
    [delegate applyHostConfiguration];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    [preferences setBool:YES forKey:VMSEPBridgeKey];
    [delegate menuWillOpen:(NSMenu *)fixtureMenu];
    CHECK([preferences boolForKey:VMSEPBridgeKey]);

    // Missing/incorrect ReadyToken and non-NSNumber policy never overwrite a
    // user's current preference. No standard defaults domain is opened here.
    [preferences setBool:NO forKey:VMSEPBridgeKey];
    CHECK(store(@"", @YES));
    [delegate applyHostConfiguration];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    CHECK([[preferences stringForKey:VMReadyTokenKey] isEqual:@"boot-C"]);
    CHECK(store(@[], @YES));
    [delegate applyHostConfiguration];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    CHECK(store(@"boot-D", @"1"));
    [delegate applyHostConfiguration];
    CHECK(![preferences boolForKey:VMSEPBridgeKey]);
    CHECK([[preferences stringForKey:VMReadyTokenKey] isEqual:@"boot-D"]);
    puts("PASS real Guest Tools boot-token initialization, same-boot menu/relaunch preservation, new-token policy and type guards; temporary plist and memory-only preferences.");
    [relaunched release]; [delegate release]; [preferences release]; [fixtureMenu release];
    [fixtureConfiguration release];
    return 0;
} }
