#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <unistd.h>

static void Address(id resource, const char *label) {
    SEL selector = sel_registerName("gpuAddress");
    BOOL present = [resource respondsToSelector:selector];
    uint64_t address = present ? ((uint64_t (*)(id,SEL))objc_msgSend)(resource,selector) : 0;
    printf("resource=%s class=%s hasGpuAddress=%d gpuAddress=0x%llx\n",
        label, resource ? object_getClassName(resource) : "nil", present, address);
}

static BOOL Finish(id<MTLCommandBuffer> command, const char *stage) {
    [command commit];
    for (unsigned i = 0; i < 500 && command.status < MTLCommandBufferStatusCompleted; ++i)
        usleep(10000);
    printf("stage=%s status=%lu error=%s\n", stage, (unsigned long)command.status,
        command.error.localizedDescription.UTF8String ?: "none");
    return command.status == MTLCommandBufferStatusCompleted;
}

static BOOL Check(id<MTLBuffer> buffer, const char *stage) {
    const uint32_t *bytes = buffer.contents;
    unsigned mismatches = 0;
    for (unsigned i = 0; i < 128; ++i) if (bytes[i] != (0x12340000u ^ i)) ++mismatches;
    printf("stage=%s mismatches=%u first=0x%x last=0x%x\n",
        stage, mismatches, bytes[0], bytes[127]);
    return mismatches == 0;
}

// Isolate real buffer and heap transfers from shader-library compilation.
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        const NSUInteger length = 128*sizeof(uint32_t);
        id<MTLBuffer> source = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!queue || !source || !readback) return 3;
        for (unsigned i = 0; i < 128; ++i) ((uint32_t *)source.contents)[i] = 0x12340000u ^ i;
        Address(source,"shared-source"); Address(readback,"shared-readback");
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit fillBuffer:readback range:NSMakeRange(0,length) value:0];
        [blit copyFromBuffer:source sourceOffset:0 toBuffer:readback destinationOffset:0 size:length];
        [blit endEncoding];
        if (!Finish(command,"shared-copy") || !Check(readback,"shared-copy")) return 4;
        MTLSizeAndAlign allocation = [device heapBufferSizeAndAlignWithLength:length options:MTLResourceStorageModePrivate];
        MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.size = 4*(allocation.size+allocation.align);
        id<MTLHeap> heap = [device newHeapWithDescriptor:descriptor];
        id<MTLBuffer> input = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
        id<MTLBuffer> output = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
        if (!input || !output) { puts("private heap allocation failed"); return 5; }
        Address(input,"private-heap-input"); Address(output,"private-heap-output");
        command = [queue commandBuffer]; blit = [command blitCommandEncoder];
        [blit fillBuffer:readback range:NSMakeRange(0,length) value:0];
        [blit copyFromBuffer:source sourceOffset:0 toBuffer:input destinationOffset:0 size:length];
        [blit copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
        [blit copyFromBuffer:output sourceOffset:0 toBuffer:readback destinationOffset:0 size:length];
        [blit endEncoding];
        return Finish(command,"private-heap-roundtrip") && Check(readback,"private-heap-roundtrip") ? 0 : 6;
    }
}
