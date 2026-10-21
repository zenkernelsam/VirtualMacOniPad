#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <string.h>
#include "../host/pvg_resource_address_protocol.h"

// Experimental and explicitly opt-in. The matching host decoder extension
// must be installed first. This library does not advertise Apple8 or Tier 2.
static uint64_t (*gOriginalGPUAddress)(id, SEL);
static const char gAddressCacheKey;
static id<MTLCommandQueue> gAddressQueue;
static _Thread_local BOOL gResolvingAddress;

static id<MTLCommandQueue> AddressQueue(id<MTLDevice> device) {
    // This opt-in library only targets the single AppleParavirt device. Reuse
    // one queue so loading a game does not create a queue for every buffer.
    @synchronized ([NSObject class]) {
        if (!gAddressQueue) gAddressQueue = [device newCommandQueue];
        return gAddressQueue.device == device ? gAddressQueue : nil;
    }
}

static uint64_t ResourceGPUAddress(id<MTLBuffer> buffer, SEL selector) {
    uint64_t original = gOriginalGPUAddress(buffer, selector);
    if (original) return original;
    // Internal queue allocation must not recursively create address queues.
    if (gResolvingAddress) return 0;
    @synchronized (buffer) {
        NSNumber *cached = objc_getAssociatedObject(buffer, &gAddressCacheKey);
        if (cached) return cached.unsignedLongLongValue;
        gResolvingAddress = YES;
        @try {
            id<MTLDevice> device = buffer.device;
            id<MTLCommandQueue> queue = AddressQueue(device);
            id<MTLBuffer> replyBuffer = [device newBufferWithLength:sizeof(VZPVGAddressReply)
                                                            options:MTLResourceStorageModeShared];
            if (!queue || !replyBuffer || !replyBuffer.contents) return 0;
            VZPVGAddressReply *reply = replyBuffer.contents;
            *reply = (VZPVGAddressReply){ .marker=VZ_PVG_ADDRESS_QUERY };
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id blit = [command blitCommandEncoder];
            SEL bytesSelector = sel_registerName("getCommandBytes:forCommand:");
            SEL referenceSelector = sel_registerName("addResourceReference:isWrite:");
            SEL bufferRefSelector = sel_registerName("bufferRef");
            SEL parentOffsetSelector = sel_registerName("parentResourceOffset");
            if (![blit respondsToSelector:bytesSelector] ||
                ![(id)command respondsToSelector:referenceSelector] ||
                ![(id)buffer respondsToSelector:bufferRefSelector] ||
                ![(id)replyBuffer respondsToSelector:bufferRefSelector]) {
                [blit endEncoding];
                return 0;
            }
            BOOL sourceAdded = ((BOOL (*)(id,SEL,id,BOOL))objc_msgSend)(command,referenceSelector,buffer,NO);
            BOOL replyAdded = ((BOOL (*)(id,SEL,id,BOOL))objc_msgSend)(command,referenceSelector,replyBuffer,YES);
            if (!sourceAdded || !replyAdded) {
                [blit endEncoding];
                return 0;
            }
            VZPVGBufferCopy *copy = ((void *(*)(id,SEL,NSUInteger,uint32_t))objc_msgSend)(
                blit,bytesSelector,sizeof(VZPVGBufferCopy),VZ_PVG_COPY_BUFFER_COMMAND);
            if (!copy) {
                [blit endEncoding];
                return 0;
            }
            *copy = (VZPVGBufferCopy){
                .source=((uint32_t (*)(id,SEL))objc_msgSend)(buffer,bufferRefSelector),
                .destination=((uint32_t (*)(id,SEL))objc_msgSend)(replyBuffer,bufferRefSelector),
                .sourceOffset=VZ_PVG_ADDRESS_QUERY,
                .destinationOffset=[(id)buffer respondsToSelector:parentOffsetSelector]
                    ? ((uint64_t (*)(id,SEL))objc_msgSend)(buffer,parentOffsetSelector) : 0,
                .size=sizeof(uint64_t)
            };
            [blit endEncoding];
            [command commit];
            for (unsigned count=0;count<500 && command.status<MTLCommandBufferStatusCompleted;++count)
                usleep(10000);
            if (command.status != MTLCommandBufferStatusCompleted ||
                reply->status != VZPVGAddressReady || !reply->address) return 0;
            uint64_t address = reply->address;
            objc_setAssociatedObject(buffer,&gAddressCacheKey,@(address),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return address;
        } @finally {
            gResolvingAddress = NO;
        }
    }
}

__attribute__((constructor)) static void InstallPVGResourceAddressCompatibility(void) {
    const char *enabled = getenv("VZ_PVG_RESOURCE_ADDRESS_BRIDGE");
    if (!enabled || strcmp(enabled,"1")) return;
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device || strcmp(object_getClassName(device),"AppleParavirtDevice")) return;
        Class cls=NSClassFromString(@"AppleParavirtBuffer");
        Method method=class_getInstanceMethod(cls,sel_registerName("gpuAddress"));
        if (method && method_getNumberOfArguments(method)==2 && method_getTypeEncoding(method)[0]=='Q') {
            // Publish the fallback before another thread can enter the hook.
            gOriginalGPUAddress=(uint64_t (*)(id,SEL))method_getImplementation(method);
            method_setImplementation(method,(IMP)ResourceGPUAddress);
        }
    }
}
