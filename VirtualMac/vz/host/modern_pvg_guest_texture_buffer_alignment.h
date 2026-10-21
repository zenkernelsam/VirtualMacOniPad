#ifndef VZ_MODERN_PVG_GUEST_TEXTURE_BUFFER_ALIGNMENT_H
#define VZ_MODERN_PVG_GUEST_TEXTURE_BUFFER_ALIGNMENT_H
#import <Foundation/Foundation.h>
#include <stdbool.h>
// Explicit VMM constructor integration only; there is no constructor here.
bool VZModernInstallGuestTextureBufferAlignmentAdvertisement(Class pgDeviceClass);
#endif
