#import <Foundation/Foundation.h>
#include <stdbool.h>

// Only the verified native27 preflight caller may use genuine native-private
// alignment for four compiled-proof formats. Other callers forward unchanged.
bool VZModernInstallTexturePreflightCallsiteBridge(id actualMetalDevice);
