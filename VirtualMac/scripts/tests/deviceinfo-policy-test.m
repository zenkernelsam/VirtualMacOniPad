#import "../../vz/host/PVGDeviceInfoPolicy.h"
#include <stdio.h>
#include <stdlib.h>

static void Require(BOOL condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Require(!PVGDeviceInfoCapsPreferenceRequested(nil), "absent preference is off");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@NO), "explicit false is off");
        Require(PVGDeviceInfoCapsPreferenceRequested(@YES), "explicit new boolean opt-in is accepted");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@"YES"), "string preference cannot opt in");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@[]), "unexpected preference type is off");
        NSDictionary *legacy = @{@"PVGDeviceInfoCaps": @YES,
                                 @"PVGDeviceInfoExtra": @"10=8;33=4095"};
        Require(!PVGDeviceInfoCapsPreferenceRequested(legacy[PVGDeviceInfoCapsPreference]),
                "legacy enabled preference and extras cannot opt in");
        NSDictionary *explicit = @{PVGDeviceInfoCapsPreference: @YES};
        Require(PVGDeviceInfoCapsPreferenceRequested(explicit[PVGDeviceInfoCapsPreference]),
                "new preference key is the sole opt-in");
        Require(strcmp(PVGDeviceInfoCapsEnvironment, "PVG_DEVICEINFO_CAPS") != 0,
                "legacy environment name is not reused");
        Require(!PVGDeviceInfoCapsEnvironmentRequested(NULL), "absent environment is off");
        const char *invalid[] = {"", "0", "true", "YES", "2", "-1", "01", " 1", "1 "};
        for (size_t index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index)
            Require(!PVGDeviceInfoCapsEnvironmentRequested(invalid[index]),
                    "only the exact environment value 1 can opt in");
        Require(PVGDeviceInfoCapsEnvironmentRequested("1"), "exact environment opt-in is accepted");
        printf("PASS: deviceInfo augmentation defaults off and ignores legacy opt-ins\n");
    }
    return 0;
}
