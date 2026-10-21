#import "modern_pvg_event.h"
#import <objc/runtime.h>

// macOS 27's IOGPU encodes an event signal at command-buffer scheduling time.
// iPadOS 16 provides that milestone through the native Metal scheduled handler
// and the same shared event through its CPU signal property. Completion and
// GPU ordering remain controlled by the driver. Only shared events can be
// signalled by this backport; unsupported events retain a real API failure.
void VZModernEncodeSignalEventScheduled(id<MTLCommandBuffer> command,
                                       id<MTLSharedEvent> event,
                                       uint64_t value) {
    if (![event respondsToSelector:@selector(signaledValue)] ||
        ![event respondsToSelector:@selector(setSignaledValue:)]) {
        [(id)event doesNotRecognizeSelector:@selector(setSignaledValue:)];
        return;
    }
    [command addScheduledHandler:^(id<MTLCommandBuffer> scheduled) {
        (void)scheduled;
        if (event.signaledValue < value) event.signaledValue = value;
    }];
}

static void SignalEventScheduled(id command, SEL selector, id event,
                                 uint64_t value) {
    (void)selector;
    VZModernEncodeSignalEventScheduled(command, event, value);
}

bool VZModernInstallScheduledEventCompatibility(id<MTLDevice> device) {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id command = [queue commandBuffer];
    SEL selector = sel_registerName("encodeSignalEventScheduled:value:");
    BOOL installed = command && ![command respondsToSelector:selector] &&
        class_addMethod([command class], selector, (IMP)SignalEventScheduled,
                        "v32@0:8@16Q24");
    [queue release];
    return installed;
}
