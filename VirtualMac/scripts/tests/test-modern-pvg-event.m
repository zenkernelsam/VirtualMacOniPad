#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import "../../vz/host/modern_pvg_event.h"
#include <stdio.h>
#include <unistd.h>

// Compare with macOS 27's real private method while an unsignalled event
// prevents command-buffer scheduling. Neither path may publish progress early.
// Always release that wait. Check actual completion separately from the event.
static BOOL Check(id<MTLDevice> device, BOOL native, uint64_t initial) {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLSharedEvent> blocker = [device newSharedEvent];
    id<MTLSharedEvent> signal = [device newSharedEvent];
    signal.signaledValue = initial;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    [command encodeWaitForEvent:blocker value:1];
    if (native) {
        SEL selector = sel_registerName("encodeSignalEventScheduled:value:");
        if (![command respondsToSelector:selector]) return NO;
        ((void (*)(id, SEL, id, uint64_t))objc_msgSend)(command, selector, signal, 19);
    } else VZModernEncodeSignalEventScheduled(command, signal, 19);
    BOOL beforeCommit = signal.signaledValue == initial;
    [command commit];
    usleep(20000);
    uint64_t whileBlocked = signal.signaledValue;
    MTLCommandBufferStatus blockedStatus = command.status;
    blocker.signaledValue = 1;
    for (unsigned i = 0; i < 2000 && command.status != MTLCommandBufferStatusCompleted &&
         command.status != MTLCommandBufferStatusError; ++i) usleep(1000);
    uint64_t expected = initial > 19 ? initial : 19;
    BOOL passed = beforeCommit && whileBlocked == initial &&
        blockedStatus == MTLCommandBufferStatusCommitted &&
        signal.signaledValue == expected &&
        command.status == MTLCommandBufferStatusCompleted;
    printf("mode=%s initial=%llu beforeCommit=%d blockedSignal=%llu blockedStatus=%lu finalSignal=%llu finalStatus=%lu passed=%d\n",
        native ? "native27" : "backport", initial, beforeCommit, whileBlocked,
        (unsigned long)blockedStatus, signal.signaledValue,
        (unsigned long)command.status, passed);
    [queue release]; [blocker release]; [signal release];
    return passed;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        BOOL passed = YES;
        for (unsigned mode = 0; mode < 2; ++mode)
            for (unsigned initial = 0; initial <= 21; initial += 21)
                passed = Check(device, mode == 0, initial) && passed;
        return passed ? 0 : 1;
    }
}
