#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <unistd.h>

static uint64_t Address(id resource) {
    SEL selector = sel_registerName("gpuAddress");
    return [resource respondsToSelector:selector] ?
        ((uint64_t (*)(id,SEL))objc_msgSend)(resource,selector) : 0;
}

// Test whether a real full-heap alias can provide the old driver's heap base.
// All addresses come from native Metal; never substitute a guessed address.
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        const NSUInteger length = 512;
        MTLSizeAndAlign allocation = [device heapBufferSizeAndAlignWithLength:length
            options:MTLResourceStorageModePrivate];
        MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.size = 8*(allocation.size+allocation.align);
        id<MTLHeap> heap = [device newHeapWithDescriptor:descriptor];
        if (!heap) return 3;
        printf("device=%s heap=%s size=%lu allocation=%lu alignment=%lu nativeHeapAddress=0x%llx\n",
            device.name.UTF8String, object_getClassName(heap), (unsigned long)heap.size,
            (unsigned long)allocation.size, (unsigned long)allocation.align, Address(heap));
        for (Class cls=[heap class]; cls && cls != [NSObject class]; cls=class_getSuperclass(cls)) {
            unsigned count=0; Method *methods=class_copyMethodList(cls,&count);
            for (unsigned i=0;i<count;++i) {
                NSString *name=NSStringFromSelector(method_getName(methods[i]));
                NSString *lower=name.lowercaseString;
                if ([lower containsString:@"buffer"] || [lower containsString:@"backing"] ||
                    [lower containsString:@"address"])
                    printf("heapMethod=%s %s types=%s\n",class_getName(cls),name.UTF8String,
                        method_getTypeEncoding(methods[i]));
            }
            free(methods);
        }
        NSUInteger fullLength = [heap maxAvailableSizeWithAlignment:allocation.align];
        id<MTLBuffer> alias = [heap newBufferWithLength:fullLength options:MTLResourceStorageModePrivate];
        if (!alias) { puts("full-heap buffer unavailable"); return 4; }
        uint64_t base = Address(alias);
        [alias makeAliasable];
        id<MTLBuffer> input = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
        id<MTLBuffer> output = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
        uint64_t inputAddress=Address(input), outputAddress=Address(output);
        printf("aliasLength=%lu base=0x%llx input=0x%llx output=0x%llx inputOffset=0x%llx outputOffset=0x%llx\n",
            (unsigned long)fullLength,base,inputAddress,outputAddress,inputAddress-base,outputAddress-base);
        if (!input || !output || !base || inputAddress<base || outputAddress<base ||
            inputAddress-base>fullLength-length || outputAddress-base>fullLength-length) return 5;
        id<MTLBuffer> source=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!source || !readback) return 6;
        for(unsigned i=0;i<128;++i)((uint32_t *)source.contents)[i]=0x12340000u^i;
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromBuffer:source sourceOffset:0 toBuffer:input destinationOffset:0 size:length];
        [blit copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
        [blit copyFromBuffer:alias sourceOffset:outputAddress-base toBuffer:readback destinationOffset:0 size:length];
        [blit endEncoding]; [command commit];
        for(unsigned i=0;i<500 && command.status<MTLCommandBufferStatusCompleted;++i)usleep(10000);
        printf("status=%lu error=%s\n",(unsigned long)command.status,
            command.error.localizedDescription.UTF8String ?: "none");
        if(command.status!=MTLCommandBufferStatusCompleted)return 7;
        unsigned mismatches=0;
        for(unsigned i=0;i<128;++i)if(((uint32_t *)readback.contents)[i]!=(0x12340000u^i))++mismatches;
        printf("alias-readback mismatches=%u first=0x%x last=0x%x\n",mismatches,
            ((uint32_t *)readback.contents)[0],((uint32_t *)readback.contents)[127]);
        return mismatches ? 8 : 0;
    }
}
