#import <Foundation/Foundation.h>
#include <stdbool.h>

// Call after the actual macOS 27 _PGDevice class has been registered, before
// creating a guest device. This does not create a Metal device or map guest VA.
bool VZModernInstallGuestLinearAlignmentAdvertisement(Class pgDeviceClass);
