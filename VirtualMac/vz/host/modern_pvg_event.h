#import <Metal/Metal.h>
#include <stdbool.h>

void VZModernEncodeSignalEventScheduled(id<MTLCommandBuffer> command,
                                       id<MTLSharedEvent> event,
                                       uint64_t value);
bool VZModernInstallScheduledEventCompatibility(id<MTLDevice> device);
