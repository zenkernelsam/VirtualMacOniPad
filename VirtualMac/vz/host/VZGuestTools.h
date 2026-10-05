#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Adds the Virtio socket endpoint consumed by macOS's built-in
// AppleQEMUGuestAgent. No network connection or guest credentials are used.
BOOL VZGuestToolsConfigureDevice(id configuration);
void VZGuestToolsAttachToVirtualMachine(id virtualMachine);
void VZGuestToolsStartProvisioning(NSString *bundlePath,
                                   BOOL guestToolsEnabled,
                                   BOOL openGLAccelerationEnabled,
                                   BOOL pencilSupportEnabled,
                                   BOOL removalPending);
void VZGuestToolsReset(void);

// Corrects the guest wall clock after the iPad app returns from a long
// inactive/suspended period. The command travels over the existing privileged
// AppleQEMUGuestAgent virtio socket; it is a no-op until that agent is ready.
void VZGuestToolsSyncGuestClock(void);

// Updates the virtual Mac's NVRAM before its platform configuration is used.
BOOL VZGuestToolsConfigureBootArguments(id auxiliaryStorage,
                                        BOOL guestAgentEnabled,
                                        BOOL openGLAccelerationEnabled,
                                        NSError **error);

NS_ASSUME_NONNULL_END
