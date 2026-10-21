#pragma once
#include <stdbool.h>

// Install before VZModernInstallShaderAudit so that the audit captures the
// original guest input and the native response to its genuine AIR conversion.
bool VZModernInstallShaderCompatibilityCache(id device);
