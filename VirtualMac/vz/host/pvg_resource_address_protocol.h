#ifndef VZ_PVG_RESOURCE_ADDRESS_PROTOCOL_H
#define VZ_PVG_RESOURCE_ADDRESS_PROTOCOL_H

#include <stdint.h>

// Opt-in extension carried by the existing PVG buffer-copy command. A matching
// host must be installed before enabling the guest library: an unmodified host
// would interpret the reserved offset as an invalid copy. No socket or new
// externally reachable service is involved.
#define VZ_PVG_ADDRESS_QUERY UINT64_C(0x565a504741444452)
#define VZ_PVG_COPY_BUFFER_COMMAND 0x12du

typedef struct {
    uint32_t source;
    uint32_t destination;
    uint64_t sourceOffset;
    uint64_t destinationOffset;
    uint64_t size;
} VZPVGBufferCopy;

typedef struct {
    uint64_t marker;
    uint64_t address;
    uint64_t status;
} VZPVGAddressReply;

enum { VZPVGAddressPending = 0, VZPVGAddressReady = 1, VZPVGAddressUnavailable = 2 };

_Static_assert(sizeof(VZPVGBufferCopy) == 32, "PVG copy command ABI");
_Static_assert(sizeof(VZPVGAddressReply) == 24, "PVG reply ABI");

#endif
