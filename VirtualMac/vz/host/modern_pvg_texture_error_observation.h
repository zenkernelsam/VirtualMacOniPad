#ifndef VZ_MODERN_PVG_TEXTURE_ERROR_OBSERVATION_H
#define VZ_MODERN_PVG_TEXTURE_ERROR_OBSERVATION_H
#include <stdbool.h>

// Call only at the existing native GPU-server listener setup point. Default
// off, with the same app-private opt-in contract as fault observation. The
// native OSlog call and its six original parameters are always preserved.
// This module creates no textures/GPU objects and changes no OS privacy flags.
bool VZModernInstallTextureErrorObservation(void);
#endif
