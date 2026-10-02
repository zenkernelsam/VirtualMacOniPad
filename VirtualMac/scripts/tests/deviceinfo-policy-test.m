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
        Require(PVGDeviceInfoCapsPreferenceRequested(nil), "absent preference selects the audited experiment");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@NO), "explicit false is off");
        Require(PVGDeviceInfoCapsPreferenceRequested(@YES), "explicit new boolean opt-in is accepted");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@"YES"), "string preference cannot opt in");
        Require(!PVGDeviceInfoCapsPreferenceRequested(@[]), "unexpected preference type is off");
        NSDictionary *legacy = @{@"PVGDeviceInfoCaps": @YES,
                                 @"PVGDeviceInfoExtra": @"10=8;33=4095"};
        Require(PVGDeviceInfoCapsPreferenceRequested(legacy[PVGDeviceInfoCapsPreference]) ==
                PVGDeviceInfoCapsPreferenceRequested(nil),
                "legacy preference does not change the default profile");
        NSDictionary *disabled = @{PVGDeviceInfoCapsPreference: @NO,
                                   @"PVGDeviceInfoCaps": @YES};
        Require(!PVGDeviceInfoCapsPreferenceRequested(disabled[PVGDeviceInfoCapsPreference]),
                "explicit new false overrides default and legacy enabled preference");
        NSDictionary *explicit = @{PVGDeviceInfoCapsPreference: @YES};
        Require(PVGDeviceInfoCapsPreferenceRequested(explicit[PVGDeviceInfoCapsPreference]),
                "new preference enables or disables the audited default");
        Require(strcmp(PVGDeviceInfoCapsEnvironment, "PVG_DEVICEINFO_CAPS") != 0,
                "legacy environment name is not reused");
        Require(!PVGDeviceInfoCapsEnvironmentRequested(NULL), "absent environment is off");
        const char *invalid[] = {"", "0", "true", "YES", "2", "-1", "01", " 1", "1 "};
        for (size_t index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index)
            Require(!PVGDeviceInfoCapsEnvironmentRequested(invalid[index]),
                    "only the exact environment value 1 can opt in");
        Require(PVGDeviceInfoCapsEnvironmentRequested("1"), "exact environment opt-in is accepted");
        printf("PASS: audited experiment defaults on; explicit false disables; VMM environment remains strict\n");
    }
    return 0;
}
