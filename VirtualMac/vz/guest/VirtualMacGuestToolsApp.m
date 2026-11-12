#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#import "SEPBridgeNetwork.h"

static NSString * const VMOpenGLKey = @"OpenGLAcceleration";
static NSString * const VMOpenGLAllowedKey = @"OpenGLAllowed";
static NSString * const VMAccountSignInKey = @"AccountSignInAdapter";
static NSString * const VMSEPBridgeKey = @"SEPIdentityBridge";
static NSString * const VMPencilSupportKey =
    @"ApplePencilPressureTiltEnabled";
static NSString * const VMLibrary = @"/Library/VirtualMac";
static NSString * const VMHostConfiguration =
    @"/Library/VirtualMac/HostConfiguration.plist";
static NSString * const VMReadyTokenKey = @"LastHostReadyToken";
static NSString * const VMReadyPath = @"/tmp/VirtualMacGuestTools.ready";
static NSString * const VMDockIconCacheRebuiltKey = @"DockIconCacheRebuilt";
static const NSInteger VMDockIconCacheRepairVersion = 3;
static const NSTimeInterval VMDockIconCacheQuietInterval = 30.0;
static const NSTimeInterval VMDockIconCacheVerificationInterval = 90.0;

static NSString *VML(NSString *key)
{
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

@interface VMGuestToolsDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, retain) NSStatusItem *statusItem;
@property(nonatomic, retain) NSMenuItem *statusMenuItem;
@property(nonatomic, retain) NSMenuItem *openGLMenuItem;
@property(nonatomic, copy) NSString *readyToken;
@property(nonatomic) NSUInteger dockIconCacheRepairAttempts;
@property(nonatomic) NSTimeInterval dockIconCacheRepairTime;
@property(nonatomic, retain) NSTask *identityServer;
@property(nonatomic, copy) NSString *identityToken;
@property(nonatomic, copy) NSString *identityPort;
@property(nonatomic) BOOL identityStarting;
@property(nonatomic) BOOL identityPreparing;
@property(nonatomic, copy) NSString *hostRelayToken;
@property(nonatomic, copy) NSString *hostRelayAddress;
@end

@implementation VMGuestToolsDelegate

- (NSUserDefaults *)preferences { return NSUserDefaults.standardUserDefaults; }

- (BOOL)preferenceForKey:(NSString *)key defaultValue:(BOOL)value
{
    if ([self.preferences objectForKey:key] == nil)
        [self.preferences setBool:value forKey:key];
    return [self.preferences boolForKey:key];
}

- (void)applyHostConfiguration
{
    NSDictionary *configuration = [NSDictionary
        dictionaryWithContentsOfFile:VMHostConfiguration];
    if (![configuration isKindOfClass:NSDictionary.class]) return;
    NSString *token = configuration[@"ReadyToken"];
    if (![token isKindOfClass:NSString.class] || !token.length) return;
    self.readyToken = token;

    // Host policy is machine-owned, while the menu extra is the authority for
    // its own user preference domain. Initialize a new VM boot exactly once so
    // a user can still toggle OpenGL for the rest of that boot without a host
    // repair relaunch overwriting the choice.
    NSString *lastToken = [self.preferences stringForKey:VMReadyTokenKey];
    if (![lastToken isEqualToString:token]) {
        NSNumber *openGL = configuration[VMOpenGLKey];
        if ([openGL isKindOfClass:NSNumber.class])
            [self.preferences setBool:openGL.boolValue forKey:VMOpenGLKey];
        NSNumber *appleServices = configuration[@"AppleServicesEnabled"];
        if ([appleServices isKindOfClass:NSNumber.class])
            [self.preferences setBool:appleServices.boolValue forKey:VMSEPBridgeKey];
        [self.preferences setObject:token forKey:VMReadyTokenKey];
    }
    for (NSString *key in @[VMOpenGLAllowedKey, VMPencilSupportKey]) {
        NSNumber *value = configuration[key];
        if ([value isKindOfClass:NSNumber.class])
            [self.preferences setBool:value.boolValue forKey:key];
    }
    id relayToken = configuration[@"AppleServicesRelayToken"];
    self.hostRelayToken = [relayToken isKindOfClass:NSString.class] && [relayToken length] == 64
        ? relayToken : nil;
    self.hostRelayAddress = VMSEPPreferredHost(configuration[@"AppleServicesRelayHosts"]);
    [self.preferences synchronize];
}

- (void)publishReady
{
    // The marker acknowledges that the guest tools process has applied the
    // host configuration.  It must not depend on AppKit having produced a
    // visible status-item button: on some Aqua boots the menu extra is alive
    // and has already applied DYLD/OpenGL policy while that button is still
    // nil.  Refusing to publish in that state makes the host retry payload
    // installation forever, creating needless virtio traffic and wakeups.
    if (!self.readyToken.length)
        return;
    NSString *temporary = [VMReadyPath stringByAppendingFormat:@".%d", getpid()];
    NSData *data = [self.readyToken dataUsingEncoding:NSUTF8StringEncoding];
    if ([data writeToFile:temporary atomically:YES]) {
        [NSFileManager.defaultManager removeItemAtPath:VMReadyPath error:nil];
        [NSFileManager.defaultManager moveItemAtPath:temporary
                                               toPath:VMReadyPath error:nil];
    }
}

- (NSString *)outputForExecutable:(NSString *)path arguments:(NSArray *)arguments
{
    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = path;
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        return [[[NSString alloc] initWithData:data
            encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    } @catch (__unused NSException *exception) { return @""; }
}

- (void)setEnvironmentVariable:(NSString *)name value:(NSString *)value
{
    [self outputForExecutable:@"/bin/launchctl"
        arguments:value ? @[@"setenv", name, value] : @[@"unsetenv", name]];
}

- (NSString *)dockIconCacheDirectory
{
    NSString *directory = [[self outputForExecutable:@"/usr/bin/getconf"
        arguments:@[@"DARWIN_USER_CACHE_DIR"]] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return directory.isAbsolutePath ? directory : nil;
}

- (NSArray *)runningDockApplications
{
    NSArray *applications = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (!applications.count) return nil;
    for (NSRunningApplication *application in applications) {
        if (!application.finishedLaunching || application.terminated)
            return nil;
    }
    return applications;
}

- (NSTimeInterval)latestIconServicesCrashTime
{
    NSTimeInterval latest = 0;
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *directory in @[@"/Library/Logs/DiagnosticReports",
            [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Logs/DiagnosticReports"]]) {
        for (NSString *name in [manager contentsOfDirectoryAtPath:directory
                                                          error:nil]) {
            if (![name hasPrefix:@"iconservices"] ||
                ![name.pathExtension isEqualToString:@"ips"]) continue;
            NSDictionary *attributes = [manager attributesOfItemAtPath:
                [directory stringByAppendingPathComponent:name] error:nil];
            NSDate *date = attributes[NSFileModificationDate];
            latest = MAX(latest, date.timeIntervalSince1970);
        }
    }
    return latest;
}

- (BOOL)dockIconCachesAreReady
{
    NSString *directory = [self dockIconCacheDirectory];
    if (!directory || ![self runningDockApplications]) return NO;
    for (NSString *name in @[@"com.apple.iconservices/store.index",
                             @"com.apple.dock.iconcache"]) {
        NSDictionary *attributes = [NSFileManager.defaultManager
            attributesOfItemAtPath:[directory stringByAppendingPathComponent:name]
                             error:nil];
        if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
            [attributes[NSFileSize] unsignedLongLongValue] == 0) return NO;
    }
    return YES;
}

- (BOOL)rebuildDockIconCaches
{
    NSString *directory = [self dockIconCacheDirectory];
    NSArray *applications = [self runningDockApplications];
    if (!directory || !applications) return NO;

    // First-login IconServices failures can leave a stale user index. Dock
    // recreates blank icons from it even after its own image cache is removed.
    // Invalidate both disposable files, preserving Dock preferences and the
    // shared system icon store. Missing files already need to be regenerated.
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *name in @[@"com.apple.iconservices/store.index",
                             @"com.apple.dock.iconcache"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) continue;
        NSError *error = nil;
        if (isDirectory || ![manager removeItemAtPath:path error:&error]) {
            NSLog(@"Could not rebuild icon cache at %@: %@", path, error);
            return NO;
        }
    }

    // The agent holds the old index in memory. Reload only this user's job
    // before asking Dock to render its icons again; no root access is needed.
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = @"/bin/launchctl";
    task.arguments = @[@"kickstart", @"-k", [NSString stringWithFormat:
        @"gui/%u/com.apple.iconservices.iconservicesagent", getuid()]];
    @try {
        [task launch];
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            NSLog(@"Could not restart the user's icon services agent");
            return NO;
        }
    } @catch (NSException *exception) {
        NSLog(@"Could not restart the user's icon services agent: %@", exception);
        return NO;
    }
    for (NSRunningApplication *application in applications) {
        pid_t pid = application.processIdentifier;
        if (pid <= 0 || kill(pid, SIGTERM) != 0) {
            NSLog(@"Could not restart Dock to rebuild its icon cache");
            return NO;
        }
    }
    return YES;
}

- (void)rebuildDockIconCacheIfNeeded
{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        [self.preferences integerForKey:VMDockIconCacheRebuiltKey] >=
            VMDockIconCacheRepairVersion) return;

    // A fresh login can keep crashing IconServices after a successful
    // restart. Do not mark the repair complete merely because the commands
    // succeeded: wait for regenerated caches and a stable rendering period.
    // A later crash invalidates the pending repair, even in another session
    // such as Setup Assistant, which can affect the shared icon store.
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval crash = [self latestIconServicesCrashTime];
    if (self.dockIconCacheRepairTime && crash > self.dockIconCacheRepairTime) {
        NSLog(@"IconServices failed after the Dock cache rebuild; retrying");
        self.dockIconCacheRepairTime = 0;
    }
    if (!self.dockIconCacheRepairTime) {
        if (now - crash >= VMDockIconCacheQuietInterval &&
            [self rebuildDockIconCaches]) {
            self.dockIconCacheRepairTime = now;
            NSLog(@"Dock icon caches rebuilt; waiting for regeneration");
        }
    } else if (now - self.dockIconCacheRepairTime >=
                    VMDockIconCacheVerificationInterval &&
                [self dockIconCachesAreReady]) {
        [self.preferences setInteger:VMDockIconCacheRepairVersion
                              forKey:VMDockIconCacheRebuiltKey];
        [self.preferences synchronize];
        NSLog(@"Dock icon cache rebuild verified");
        return;
    }
    // Poll for up to five minutes. A timed-out or failed repair remains
    // eligible on the next launch, including upgrades from versions 1 and 2.
    if (++self.dockIconCacheRepairAttempts < 60)
        [self performSelector:_cmd withObject:nil afterDelay:5.0];
    else
        NSLog(@"Dock icon cache repair did not stabilize; retrying next launch");
}

- (void)setSavedApplicationRelaunchSuppressed:(BOOL)suppressed
{
    NSUserDefaults *loginwindow = [[[NSUserDefaults alloc]
        initWithSuiteName:@"com.apple.loginwindow"] autorelease];
    for (NSString *key in @[@"TALLogoutSavesState",
                             @"LoginwindowLaunchesRelaunchApps"]) {
        if (suppressed)
            [loginwindow setBool:NO forKey:key];
        else
            [loginwindow removeObjectForKey:key];
    }
    [loginwindow synchronize];
}

- (BOOL)hostAllowsOpenGL
{
    return [self preferenceForKey:VMOpenGLAllowedKey defaultValue:NO];
}

- (BOOL)guestSupportsOpenGL
{
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14;
}

- (BOOL)securityPolicySupportsOpenGL
{
    // Virtual Mac applies SIP capabilities to the running guest kernel while
    // leaving its signed persistent LocalPolicy untouched. Modern csrutil
    // reports that persistent startup policy, so query the enforcement ABI
    // used by dyld and the kernel instead.
    int (*csr_check_fn)(uint32_t) = dlsym(RTLD_DEFAULT, "csr_check");
    BOOL unrestrictedFilesystem = csr_check_fn && csr_check_fn(1U << 1) == 0;
    NSString *bootArguments = [self outputForExecutable:@"/usr/sbin/nvram"
                                      arguments:@[@"boot-args"]];
    return unrestrictedFilesystem &&
        [bootArguments containsString:@"-arm64e_preview_abi"];
}

- (BOOL)openGLAvailable
{
    return [self guestSupportsOpenGL] && [self hostAllowsOpenGL] &&
        [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"]];
}

- (BOOL)accountSignInAdapterAvailable
{
    // Opt-in Apple Account sign-in diagnostic adapter. Default off; the guest
    // enables it with `defaults write com.mac.virtual.guest-tools
    // AccountSignInAdapter -bool true`. It requires the same relaxed
    // run-time security policy as the OpenGL dylib and is only injected into
    // processes launched after the environment change.
    return ([self preferenceForKey:VMAccountSignInKey defaultValue:NO] ||
        [self sepIdentityBridgeAvailable]) &&
        [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"AppleAccountSignInCompat.dylib"]];
}

- (BOOL)sepIdentityBridgeAvailable
{
    // Opt-in identity bridge. Default off; the guest enables it with
    // `defaults write com.mac.virtual.guest-tools SEPIdentityBridge
    // -bool true`. Forwards anisette/attestation operations to the host
    // iPad's real SEP path (see docs/SEP-IDENTITY-BRIDGE.md).
    return self.hostRelayToken.length == 64 && self.hostRelayAddress.length &&
        self.identityServer.running && self.identityPort.length &&
        [self preferenceForKey:VMSEPBridgeKey defaultValue:NO] &&
        [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"SEPBridgeCompat.dylib"]];
}

- (void)applyOpenGL
{
    BOOL requested = [self preferenceForKey:VMOpenGLKey defaultValue:YES] &&
        [self guestSupportsOpenGL] && [self hostAllowsOpenGL];
    BOOL enabled = requested && [self securityPolicySupportsOpenGL] &&
        [NSFileManager.defaultManager fileExistsAtPath:[VMLibrary
            stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"]];
    NSMutableArray *libraries = [NSMutableArray array];
    if (enabled)
        [libraries addObject:[VMLibrary
            stringByAppendingPathComponent:@"OpenGLPVGCompat.dylib"]];
    if ([self accountSignInAdapterAvailable])
        [libraries addObject:[VMLibrary
            stringByAppendingPathComponent:@"AppleAccountSignInCompat.dylib"]];
    if ([self sepIdentityBridgeAvailable])
        [libraries addObject:[VMLibrary
            stringByAppendingPathComponent:@"SEPBridgeCompat.dylib"]];
    // This changes only the requested Aqua environment variable and leaves
    // unrelated values intact.
    [self setEnvironmentVariable:@"DYLD_INSERT_LIBRARIES"
        value:libraries.count
            ? [libraries componentsJoinedByString:@":"] : nil];
    BOOL identity = [self sepIdentityBridgeAvailable];
    [self setEnvironmentVariable:@"VM_SEP_BRIDGE" value:identity ? @"1" : nil];
    [self setEnvironmentVariable:@"VM_SEP_FAKE_NONVM" value:identity ? @"1" : nil];
    [self setEnvironmentVariable:@"VM_INDEPENDENT_IDENTITY" value:identity ? @"1" : nil];
    [self setEnvironmentVariable:@"VM_INDEPENDENT_IDENTITY_PORT" value:identity ? self.identityPort : nil];
    [self setEnvironmentVariable:@"VM_INDEPENDENT_IDENTITY_TOKEN" value:identity ? self.identityToken : nil];
    [self setEnvironmentVariable:@"VM_SEP_REMOTE_TOKEN" value:identity ? self.hostRelayToken : nil];
    [self setEnvironmentVariable:@"VM_SEP_HOST" value:identity ? self.hostRelayAddress : nil];
    // loginwindow can restore applications before an ordinary LaunchAgent is
    // scheduled, so those processes cannot inherit a value published by this
    // menu extra. While acceleration is enabled, turn off saved-application
    // relaunch instead of racing loginwindow or injecting a boot-time agent.
    // Removing the OpenGL preference restores the guest's normal defaults.
    // Preserve the configured intent if the host is still applying its
    // running-kernel policy when this login item starts. That transient state
    // must not re-enable saved-app restoration for the following boot.
    [self setSavedApplicationRelaunchSuppressed:requested];
}

- (NSDictionary *)independentIdentityStatus
{
    NSString *provider = [VMLibrary stringByAppendingPathComponent:@"independent-identity-provider"];
    NSString *output = [self outputForExecutable:provider arguments:@[@"--status"]];
    NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : @{};
}

- (void)startIndependentIdentity
{
    if (self.identityStarting || self.identityPreparing || self.identityServer.running ||
        ![self preferenceForKey:VMSEPBridgeKey defaultValue:NO] ||
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 ||
        ![self securityPolicySupportsOpenGL] ||
        ![[self independentIdentityStatus][@"ready"] boolValue]) return;
    self.identityStarting = YES;
    unsigned char random[32]; arc4random_buf(random, sizeof(random));
    NSMutableString *token = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(random); i++) [token appendFormat:@"%02x", random[i]];
    self.identityToken = token;
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = [VMLibrary stringByAppendingPathComponent:@"independent-identity-provider"];
    task.arguments = @[@"--serve"];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    // A repair relaunch inherits the previous provider's published port.
    // Always request a fresh random listener instead of rebinding that port.
    [environment removeObjectForKey:@"VM_INDEPENDENT_IDENTITY_PORT"];
    environment[@"VM_INDEPENDENT_IDENTITY_TOKEN"] = token;
    task.environment = environment; [environment release];
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe;
    self.identityServer = task;
    @try { [task launch]; }
    @catch (__unused NSException *exception) { self.identityStarting = NO; self.identityServer = nil; return; }
    // A missing startup line must not hang the menu extra indefinitely.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.identityStarting && self.identityServer == task && task.running) [task terminate];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSData *line = [pipe.fileHandleForReading availableData];
        NSString *text = [[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] autorelease];
        NSString *port = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL valid = port.length && port.length <= 5 &&
            [port rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound &&
            port.integerValue >= 1024 && port.integerValue <= 65535;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.identityStarting = NO;
            if (!valid || !task.running) { self.identityServer = nil; self.identityPort = nil; [self applyOpenGL]; return; }
            self.identityPort = port;
            [self applyOpenGL];
            // Guest akd must inherit the new user environment. This occurs once
            // at provider startup, never on every menu opening/request.
            [self outputForExecutable:@"/usr/bin/killall" arguments:@[@"akd"]];
        });
    });
}

- (void)showAppleServices:(NSMenuItem *)sender
{
    (void)sender;
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = VML(@"Apple Services Identity");
    alert.informativeText = [[self independentIdentityStatus][@"ready"] boolValue]
        ? VML(@"Independent identity is ready. iCloud and media sign-in still require verification in their apps.")
        : VML(@"Prepare a separate identity for this Virtual Mac before signing in. Existing account data is preserved.");
    if (!self.hostRelayToken.length)
        alert.informativeText = VML(@"Enable the independent-v1 identity profile for this VM. Guest Tools will guide identity preparation; iCloud and media sign-in are verified separately. Copied ADI identities stay blocked until a new identity is prepared. Disabling adapters preserves account data.");
    [alert addButtonWithTitle:VML(@"Prepare Independent Identity")];
    [alert addButtonWithTitle:VML(@"Open Apple Account Settings")];
    [alert addButtonWithTitle:VML(@"Disable Apple Service Adapters")];
    [alert addButtonWithTitle:VML(@"Cancel")];
    NSModalResponse choice = [alert runModal];
    if (choice == NSAlertSecondButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"]];
    } else if (choice == NSAlertThirdButtonReturn) {
        [self.preferences setBool:NO forKey:VMSEPBridgeKey];
        if (self.identityServer.running) [self.identityServer terminate];
        self.identityServer = nil; self.identityPort = nil; self.identityToken = nil;
        [self applyOpenGL];
        [self outputForExecutable:@"/usr/bin/killall" arguments:@[@"akd"]];
    } else if (choice == NSAlertFirstButtonReturn && !self.identityPreparing) {
        self.identityPreparing = YES;
        // Initial HTTPS provisioning has its own 110s budget. Auth requests
        // subsequently use existing state only, avoiding the old 15s race.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [self outputForExecutable:[VMLibrary stringByAppendingPathComponent:@"independent-identity-provider"]
                arguments:@[@"--prepare"]];
            BOOL ready = [[self independentIdentityStatus][@"ready"] boolValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.identityPreparing = NO;
                if (ready) { [self.preferences setBool:YES forKey:VMSEPBridgeKey]; [self startIndependentIdentity]; }
                NSAlert *result = [[[NSAlert alloc] init] autorelease];
                result.messageText = VML(@"Apple Services Identity");
                result.informativeText = ready
                    ? VML(@"Independent identity is ready. iCloud and media sign-in still require verification in their apps.")
                    : VML(@"Identity preparation failed. Existing identity was kept; check the Guest Tools log and try again.");
                [result runModal];
            });
        });
    }
}

- (NSImage *)statusImageNamed:(NSString *)name
{
    NSImage *image = [NSImage imageNamed:name];
    image.template = YES;
    image.size = NSMakeSize(18, 18);
    return image;
}

- (void)updateMenu
{
    BOOL available = [self openGLAvailable];
    BOOL enabled = available &&
        [self preferenceForKey:VMOpenGLKey defaultValue:YES];
    self.statusMenuItem.title = VML(@"Virtual Mac");
    self.openGLMenuItem.state = enabled ? NSControlStateValueOn
                                        : NSControlStateValueOff;
    self.openGLMenuItem.enabled = [self guestSupportsOpenGL];
    self.statusItem.button.image = [self statusImageNamed:enabled
        ? @"vm.laptopcomputer.badge.checkmark" : @"vm.laptopcomputer"];
    self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    (void)menu;
    [self applyHostConfiguration];
    // The host applies the running-kernel policy asynchronously during boot.
    // Refresh both the effective environment and the visible checkmark when
    // the user opens the menu instead of freezing startup-time state.
    [self applyOpenGL];
    [self startIndependentIdentity];
    [self updateMenu];
}

- (void)showOpenGLUnavailable
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = VML(@"OpenGL Acceleration Is Off");
    alert.informativeText = [self guestSupportsOpenGL]
        ? VML(@"To enable OpenGL acceleration, shut down this Virtual Mac, then in its options, enable OpenGL Acceleration.")
        : VML(@"OpenGL Acceleration requires macOS Sonoma or later.");
    [alert addButtonWithTitle:VML(@"OK")];
    [alert runModal];
}

- (void)toggleOpenGL:(NSMenuItem *)sender
{
    (void)sender;
    if (![self openGLAvailable]) {
        [self showOpenGLUnavailable];
        [self updateMenu];
        return;
    }
    BOOL enabled = ![self preferenceForKey:VMOpenGLKey defaultValue:YES];
    [self.preferences setBool:enabled forKey:VMOpenGLKey];
    [self applyOpenGL];
    [self startIndependentIdentity];
    [self updateMenu];
}

- (NSString *)productVersion
{
    NSString *version = [self outputForExecutable:@"/usr/bin/sw_vers"
                                      arguments:@[@"-productVersion"]];
    return [version stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (void)openWebItem:(NSMenuItem *)sender
{
    NSURLComponents *components = [NSURLComponents componentsWithString:
        @"https://nfzerox.github.io/virtual-mac/app/"];
    NSString *virtualMacVersion = [NSBundle.mainBundle
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"app" value:sender.representedObject],
        [NSURLQueryItem queryItemWithName:@"vm" value:virtualMacVersion],
        [NSURLQueryItem queryItemWithName:@"os" value:self.productVersion],
    ];
    [NSWorkspace.sharedWorkspace openURL:components.URL];
}

- (void)openSupport:(NSMenuItem *)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        sender.representedObject]];
}

- (NSMenuItem *)itemWithTitle:(NSString *)title action:(SEL)action
             representedObject:(id)object
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action
        keyEquivalent:@""] autorelease];
    item.target = self;
    item.representedObject = object;
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self applyHostConfiguration];
    [self applyOpenGL];
    [self startIndependentIdentity];
    [self rebuildDockIconCacheIfNeeded];
    self.statusItem = [NSStatusBar.systemStatusBar
        statusItemWithLength:NSSquareStatusItemLength];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:VML(@"Virtual Mac Guest Tools")]
        autorelease];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.statusMenuItem = [[[NSMenuItem alloc]
        initWithTitle:VML(@"Virtual Mac")
        action:nil keyEquivalent:@""] autorelease];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    BOOL supportsOpenGL = [self guestSupportsOpenGL];
    self.openGLMenuItem = [self itemWithTitle:supportsOpenGL
        ? VML(@"OpenGL Acceleration")
        : VML(@"OpenGL Acceleration requires macOS Sonoma or later.")
        action:@selector(toggleOpenGL:) representedObject:nil];
    [menu addItem:self.openGLMenuItem];
    [menu addItem:[self itemWithTitle:VML(@"Apple Services Identity")
        action:@selector(showAppleServices:) representedObject:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self itemWithTitle:VML(@"Download Xcode")
        action:@selector(openWebItem:) representedObject:@"xcode"]];
    if (supportsOpenGL) {
        [menu addItem:[self itemWithTitle:VML(@"Download Final Cut Pro Trial")
            action:@selector(openWebItem:)
            representedObject:@"final-cut-pro-trial"]];
    }
    [menu addItem:[self itemWithTitle:VML(@"Download Logic Pro Trial")
        action:@selector(openWebItem:) representedObject:@"logic-pro-trial"]];
    [menu addItem:[self itemWithTitle:VML(@"Download Pixelmator Pro Trial")
        action:@selector(openWebItem:)
        representedObject:@"pixelmator-pro-trial"]];
    if ([self preferenceForKey:VMPencilSupportKey defaultValue:NO]) {
        [menu addItem:[self itemWithTitle:VML(@"Download Apple Pencil Support")
            action:@selector(openWebItem:) representedObject:@"pencil"]];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self itemWithTitle:VML(@"Get Help")
        action:@selector(openSupport:) representedObject:
        @"https://nfzerox.github.io/virtual-mac/help/"]];
    [menu addItem:[self itemWithTitle:VML(@"Report Issue")
        action:@selector(openSupport:) representedObject:
        @"https://nfzerox.github.io/virtual-mac/issues/"]];
    self.statusItem.menu = menu;
    [self updateMenu];
    [self publishReady];
}

@end


int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSApplication *application = NSApplication.sharedApplication;
    VMGuestToolsDelegate *delegate = [VMGuestToolsDelegate new];
    application.delegate = delegate;
    [application run];
    [delegate release];
    [pool drain];
    return 0;
}
