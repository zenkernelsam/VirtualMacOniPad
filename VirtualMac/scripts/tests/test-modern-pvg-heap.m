// Exercise the compatibility accessor with real Metal placement-heap storage
// and GPU blits. The PG test fixture supplies the measured macOS 27 ivar schema
// because Apple's corresponding classes live in a standalone XPC executable.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../../vz/host/modern_pvg_heap.h"

@interface PGResource : NSObject
- (id)getBuffer;
@end
@implementation PGResource
- (id)getBuffer { return nil; }
@end
@interface PGHeapResource : PGResource
@end
@implementation PGHeapResource
@end
@interface PGLegacyHeapResource : PGHeapResource {
@public
    id<MTLHeap> _heap;
    id<MTLBuffer> _transferHeapBuffer;
    NSUInteger _length;
}
@end
@implementation PGLegacyHeapResource
- (void)dealloc {
    [_transferHeapBuffer release];
    [_heap release];
    [super dealloc];
}
@end

static uint64_t Address(id resource) {
    return ((uint64_t (*)(id, SEL))objc_msgSend)(resource, sel_registerName("gpuAddress"));
}
static uint64_t ZeroHeapAddress(id heap, SEL selector) {
    (void)heap; (void)selector;
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        BOOL simulateLegacy = argc == 2 && !strcmp(argv[1], "--simulate-legacy-heap-address");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { puts("no native Metal device"); return 2; }
        const NSUInteger length = 512;
        MTLSizeAndAlign allocation = [device heapBufferSizeAndAlignWithLength:length
            options:MTLResourceStorageModePrivate];
        MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
        descriptor.type = MTLHeapTypePlacement;
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.size = 8 * (allocation.size + allocation.align);
        id<MTLHeap> heap = [device newHeapWithDescriptor:descriptor];
        id<MTLHeap> unmarkedHeap = [device newHeapWithDescriptor:descriptor];
        if (!heap || !unmarkedHeap) return 3;
        id<MTLBuffer> alias = [heap newBufferWithLength:heap.size
            options:MTLResourceStorageModePrivate offset:0];
        id<MTLBuffer> input = [heap newBufferWithLength:length
            options:MTLResourceStorageModePrivate offset:0];
        NSUInteger outputOffset = (allocation.size + allocation.align - 1) & ~(allocation.align - 1);
        id<MTLBuffer> output = [heap newBufferWithLength:length
            options:MTLResourceStorageModePrivate offset:outputOffset];
        if (!alias || !input || !output) return 4;
        uint64_t nativeHeapAddress = Address(heap);
        uint64_t nativeUnmarkedAddress = Address(unmarkedHeap);
        if (simulateLegacy) {
            Class cls = object_getClass(heap);
            SEL selector = sel_registerName("gpuAddress");
            Method method = class_getInstanceMethod(cls, selector);
            if (!class_addMethod(cls, selector, (IMP)ZeroHeapAddress, method_getTypeEncoding(method)))
                method_setImplementation(method, (IMP)ZeroHeapAddress);
            nativeUnmarkedAddress = 0;
        }
        PGLegacyHeapResource *resource = [PGLegacyHeapResource new];
        resource->_heap = [heap retain];
        resource->_transferHeapBuffer = [alias retain];
        resource->_length = alias.length;
        if (!VZModernInstallHeapCompatibility() || !VZModernInstallHeapCompatibility()) return 5;
        id<MTLBuffer> actual = [resource getBuffer];
        uint64_t base = Address(actual);
        printf("device=%s simulatedLegacy=%d nativeHeapAddress=0x%llx returnedHeapAddress=0x%llx "
               "aliasAddress=0x%llx inputAddress=0x%llx outputAddress=0x%llx\n",
               device.name.UTF8String, simulateLegacy,
               (unsigned long long)nativeHeapAddress, (unsigned long long)Address(heap),
               (unsigned long long)base, (unsigned long long)Address(input),
               (unsigned long long)Address(output));
        if (actual != alias || !base || Address(input) != base ||
            Address(output) != base + outputOffset || Address(heap) != base ||
            Address(unmarkedHeap) != nativeUnmarkedAddress || [[PGResource new] getBuffer]) return 6;
        id<MTLBuffer> upload = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!upload || !readback) return 7;
        for (unsigned i = 0; i < 128; ++i) ((uint32_t *)upload.contents)[i] = 0x12340000u ^ i;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 toBuffer:input destinationOffset:0 size:length];
        [blit copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
        [blit copyFromBuffer:actual sourceOffset:outputOffset toBuffer:readback destinationOffset:0 size:length];
        [blit endEncoding];
        [command commit];
        for (unsigned i = 0; i < 500 && command.status < MTLCommandBufferStatusCompleted; ++i) usleep(10000);
        if (command.status != MTLCommandBufferStatusCompleted) {
            printf("GPU completion failed status=%lu error=%s\n", (unsigned long)command.status,
                command.error.description.UTF8String ?: "none");
            return 8;
        }
        unsigned mismatches = 0;
        for (unsigned i = 0; i < 128; ++i)
            if (((uint32_t *)readback.contents)[i] != (0x12340000u ^ i)) ++mismatches;
        printf("native placement heap alias readback mismatches=%u first=0x%x last=0x%x\n",
            mismatches, ((uint32_t *)readback.contents)[0], ((uint32_t *)readback.contents)[127]);
        if (mismatches) return 9;
        // A foreign buffer cannot supply the placement heap's address.
        [resource->_transferHeapBuffer release];
        resource->_transferHeapBuffer = [upload retain];
        resource->_length = upload.length;
        if ([resource getBuffer]) return 10;
        [resource release];
        puts("heap accessor, real GPU alias storage, and unmarked-resource fallback passed");
        return 0;
    }
}
