#pragma once

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t key;
    uint32_t value;
} VMDevInfoPair;

_Static_assert(sizeof(VMDevInfoPair) == 8, "deviceInfo pair layout");

typedef enum {
    PVGDeviceInfoReplyOK,
    PVGDeviceInfoReplyBounds,
    PVGDeviceInfoReplyUnterminated
} PVGDeviceInfoReplyStatus;

typedef struct {
    PVGDeviceInfoReplyStatus status;
    uint32_t pairs;
    uint32_t applied;
    uint32_t dropped;
} PVGDeviceInfoReplyResult;

static inline bool PVGDeviceInfoParseUInt32(const char *text, uint32_t *value) {
    if (text == NULL || text[0] < '0' || text[0] > '9')
        return false;
    char *end;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno != 0 || *end != '\0' || parsed > UINT32_MAX)
        return false;
    *value = (uint32_t)parsed;
    return true;
}

static inline bool PVGDeviceInfoNarrowPair(VMDevInfoPair *pairs, size_t count,
                                          uint32_t key, uint32_t value) {
    for (size_t index = 0; index < count; ++index) {
        if (pairs[index].key != key)
            continue;
        bool narrower = key == 28 || key == 33
            ? (value & ~pairs[index].value) == 0
            : value <= pairs[index].value;
        if (key == 32 || key == 40)
            narrower = value >= pairs[index].value && value != 0 &&
                (value & (value - 1)) == 0;
        if ((key >= 29 && key <= 31) || (key >= 34 && key <= 37))
            narrower = narrower && value != 0;
        if (key == 37 && value < 1001)
            narrower = false;
        if (!narrower)
            return false;
        pairs[index].value = value;
        return true;
    }
    return false;
}

static inline VMDevInfoPair PVGDeviceInfoReadPair(const uint8_t *bytes,
                                                 uint32_t index) {
    VMDevInfoPair pair;
    memcpy(&pair, bytes + (size_t)index * sizeof(pair), sizeof(pair));
    return pair;
}

static inline void PVGDeviceInfoWritePair(uint8_t *bytes, uint32_t index,
                                          VMDevInfoPair pair) {
    memcpy(bytes + (size_t)index * sizeof(pair), &pair, sizeof(pair));
}

static inline PVGDeviceInfoReplyResult PVGDeviceInfoAugmentReply(
    void *page, size_t pageSize, uint64_t offset, uint32_t count,
    uint32_t keyLimit, const VMDevInfoPair *extras, size_t extraCount) {
    PVGDeviceInfoReplyResult result = { .status = PVGDeviceInfoReplyBounds };
    if (page == NULL || offset > pageSize || pageSize - offset < sizeof(VMDevInfoPair) ||
        count == 0 || keyLimit == 0 || (extras == NULL && extraCount != 0))
        return result;
    size_t physicalCapacity = (pageSize - offset) / sizeof(VMDevInfoPair);
    uint32_t capacity = physicalCapacity > UINT32_MAX
        ? UINT32_MAX : (uint32_t)physicalCapacity;
    uint32_t limit = count < capacity ? count : capacity;
    uint32_t usable = count > capacity ? capacity - 1 : limit;
    uint8_t *bytes = (uint8_t *)page + offset;
    uint32_t n = 0;
    while (n < limit && PVGDeviceInfoReadPair(bytes, n).key != 0)
        ++n;
    if (n == limit && count > capacity) {
        result.status = PVGDeviceInfoReplyUnterminated;
        return result;
    }
    result.status = PVGDeviceInfoReplyOK;
    for (size_t index = 0; index < extraCount; ++index) {
        VMDevInfoPair pair = extras[index];
        if (pair.key == 0 || pair.key >= keyLimit) {
            ++result.dropped;
            continue;
        }
        uint32_t position = 0;
        while (position < n && PVGDeviceInfoReadPair(bytes, position).key != pair.key)
            ++position;
        if (position == n) {
            if (n >= usable) {
                ++result.dropped;
                continue;
            }
            ++n;
        }
        PVGDeviceInfoWritePair(bytes, position, pair);
        ++result.applied;
    }
    if (n < limit)
        PVGDeviceInfoWritePair(bytes, n, (VMDevInfoPair){0, 0});
    result.pairs = n;
    return result;
}
