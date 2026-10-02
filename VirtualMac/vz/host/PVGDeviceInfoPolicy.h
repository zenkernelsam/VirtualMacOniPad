#pragma once

#import <Foundation/Foundation.h>
#include <string.h>

#define PVGDeviceInfoCapsPreference @"PVGDeviceInfoCapsExperimental"
#define PVGDeviceInfoCapsEnvironment "PVG_DEVICEINFO_CAPS_EXPERIMENTAL"

static inline BOOL PVGDeviceInfoCapsPreferenceRequested(id value) {
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static inline BOOL PVGDeviceInfoCapsEnvironmentRequested(const char *value) {
    return value != NULL && strcmp(value, "1") == 0;
}
