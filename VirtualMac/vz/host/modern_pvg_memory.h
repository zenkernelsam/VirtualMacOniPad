#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

bool VZModernPVGEnabled(void);
void VZModernRecordGuestMapping(void *address, uint64_t physical,
                               size_t length, uint64_t flags);
#ifdef __OBJC__
id VZModernNewDeviceWithDescriptor(id descriptor);
bool VZModernInstallIOSurfaceDescriptorBridge(void);
#endif
