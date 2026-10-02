#include "../../vz/host/PVGDeviceInfoReply.h"
#include <stdio.h>

static void Require(bool condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

int main(void) {
    uint8_t page[0x4000];
    uint8_t before[sizeof(page)];
    const VMDevInfoPair extras[] = {{33, 32}, {37, 1007}, {42, 1}, {0, 1}};
    memset(page, 0, sizeof(page));
    PVGDeviceInfoWritePair(page, 0, (VMDevInfoPair){10, 0});
    PVGDeviceInfoReplyResult result = PVGDeviceInfoAugmentReply(
        page, sizeof(page), 0, 42, 42, extras, 4);
    Require(result.status == PVGDeviceInfoReplyOK && result.applied == 2 &&
            result.dropped == 2 && result.pairs == 3, "append below exclusive key ceiling");
    Require(PVGDeviceInfoReadPair(page, 0).value == 0, "serializer version remains unchanged");
    Require(PVGDeviceInfoReadPair(page, 3).key == 0, "zero terminator follows added pairs");
    uint8_t alias[sizeof(page)];
    memcpy(alias, page, sizeof(page));
    VMDevInfoPair familyOverride = {37, 1006};
    result = PVGDeviceInfoAugmentReply(alias, sizeof(alias), 0, 42, 42, &familyOverride, 1);
    Require(result.status == PVGDeviceInfoReplyOK && result.applied == 1 &&
            PVGDeviceInfoReadPair(alias, 2).value == 1006,
            "reply is addressed from guest page start, not a rootTaskBase host pointer");
    memcpy(before, page, sizeof(page));
    for (size_t tail = 0; tail < 8; ++tail) {
        result = PVGDeviceInfoAugmentReply(page, sizeof(page), sizeof(page) - tail,
                                           1, 42, extras, 4);
        Require(result.status == PVGDeviceInfoReplyBounds &&
                memcmp(before, page, sizeof(page)) == 0, "short tail refuses without underflow or mutation");
    }
    result = PVGDeviceInfoAugmentReply(page, sizeof(page), UINT64_MAX, 1, 42, extras, 4);
    Require(result.status == PVGDeviceInfoReplyBounds, "oversized offset is rejected");
    memset(page, 0, sizeof(page));
    PVGDeviceInfoWritePair(page, 0, (VMDevInfoPair){10, 0});
    result = PVGDeviceInfoAugmentReply(page, 16, 0, UINT32_MAX, 42, extras, 4);
    Require(result.status == PVGDeviceInfoReplyOK && result.applied == 0 &&
            PVGDeviceInfoReadPair(page, 1).key == 0, "oversized count reserves a physical terminator");
    PVGDeviceInfoWritePair(page, 1, (VMDevInfoPair){13, 256});
    memcpy(before, page, sizeof(page));
    result = PVGDeviceInfoAugmentReply(page, 16, 0, 3, 42, extras, 4);
    Require(result.status == PVGDeviceInfoReplyUnterminated &&
            memcmp(before, page, sizeof(page)) == 0, "unterminated oversized reply remains unchanged");
    result = PVGDeviceInfoAugmentReply(page, 16, 0, 2, 42, extras, 4);
    Require(result.status == PVGDeviceInfoReplyOK && result.applied == 0 &&
            memcmp(before, page, sizeof(page)) == 0, "bounded full reply does not lose existing pairs");
    VMDevInfoPair pairs[] = {{33, 0x3e0}, {37, 1007}, {29, 1024}};
    Require(!PVGDeviceInfoNarrowPair(pairs, 3, 33, 4095), "protocol widening is refused");
    Require(PVGDeviceInfoNarrowPair(pairs, 3, 33, 32), "bitmask narrowing is allowed");
    Require(!PVGDeviceInfoNarrowPair(pairs, 3, 37, 1009), "Apple9 widening is refused");
    Require(!PVGDeviceInfoNarrowPair(pairs, 3, 37, 0), "invalid family is refused");
    Require(!PVGDeviceInfoNarrowPair(pairs, 3, 10, 8), "serializer override is refused");
    Require(PVGDeviceInfoNarrowPair(pairs, 3, 29, 512), "limit reduction is allowed");
    Require(!PVGDeviceInfoNarrowPair(pairs, 3, 29, 0), "zero compute limit is refused");
    VMDevInfoPair alignment[] = {{32, 16}, {40, 256}};
    Require(!PVGDeviceInfoNarrowPair(alignment, 2, 32, 8), "smaller alignment would widen access");
    Require(!PVGDeviceInfoNarrowPair(alignment, 2, 40, 257), "alignment must remain a power of two");
    Require(PVGDeviceInfoNarrowPair(alignment, 2, 40, 512), "stricter alignment is narrowing");
    uint32_t value;
    Require(PVGDeviceInfoParseUInt32("0x20", &value) && value == 32, "hex override is parsed");
    const char *invalid[] = {"", "-1", "+1", "4095garbage", "4294967296", "0x", " 1"};
    for (size_t index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index)
        Require(!PVGDeviceInfoParseUInt32(invalid[index], &value), "malformed or overflowing override is refused");
    for (uint64_t offset = 0; offset <= sizeof(page); ++offset) {
        memset(page, 0, sizeof(page));
        result = PVGDeviceInfoAugmentReply(page, sizeof(page), offset,
                                           UINT32_MAX, 42, extras, 4);
        Require(result.status == (sizeof(page) - offset < 8
                ? PVGDeviceInfoReplyBounds : PVGDeviceInfoReplyOK), "all page offsets are bounded");
    }
    printf("PASS: deviceInfo page bounds, terminators, key ceilings and narrowing-only overrides\n");
    return 0;
}
