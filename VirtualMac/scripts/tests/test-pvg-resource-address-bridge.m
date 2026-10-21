#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <string.h>
#include "../../vz/host/pvg_resource_address_bridge.m"

// Exercise the wire format against real Metal buffers, including the normal
// copy path. Each decoder has its own object table, as the real host does.
@interface BridgeTestDecoder : NSObject {
@public id<MTLBlitCommandEncoder> blitEncoder;
}
@property NSMutableDictionary<NSNumber *,id<MTLBuffer>> *buffers;
- (void)readCommand:(const uint32_t *)header withIterator:(NSData *)data
       expectedSize:(NSUInteger)size into:(void *)destination;
- (id<MTLBuffer>)getBufferForReferenceNonNull:(uint32_t)reference;
@end
@implementation BridgeTestDecoder
- (void)readCommand:(const uint32_t *)header withIterator:(NSData *)data
       expectedSize:(NSUInteger)size into:(void *)destination {
    NSCAssert(header[0]==VZ_PVG_COPY_BUFFER_COMMAND && header[1]==size+8,@"header ABI");
    NSCAssert(data.length==size,@"payload ABI");
    memcpy(destination,data.bytes,size);
}
- (id<MTLBuffer>)getBufferForReferenceNonNull:(uint32_t)reference {
    id<MTLBuffer> buffer=self.buffers[@(reference)];
    if (!buffer) [NSException raise:@"MissingResource" format:@"%u",reference];
    return buffer;
}
@end

static void Decode(BridgeTestDecoder *decoder,VZPVGBufferCopy copy) {
    uint32_t header[]={VZ_PVG_COPY_BUFFER_COMMAND,sizeof(copy)+8};
    DecodeBufferCopy(decoder,NULL,header,[NSData dataWithBytes:&copy length:sizeof(copy)]);
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) { fputs("Metal device unavailable\n",stderr); return 2; }
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLBuffer> input=[device newBufferWithLength:512 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[device newBufferWithLength:512 options:MTLResourceStorageModeShared];
        id<MTLBuffer> reply=[device newBufferWithLength:sizeof(VZPVGAddressReply) options:MTLResourceStorageModeShared];
        for (unsigned i=0;i<512;++i)((uint8_t *)input.contents)[i]=(uint8_t)i;
        BridgeTestDecoder *decoder=[BridgeTestDecoder new];
        decoder.buffers=[@{@1:input,@2:output,@3:reply} mutableCopy];
        gBlitEncoderIvar=class_getInstanceVariable([BridgeTestDecoder class],"blitEncoder");
        id<MTLCommandBuffer> command=[queue commandBuffer];
        decoder->blitEncoder=[command blitCommandEncoder];
        Decode(decoder,(VZPVGBufferCopy){.source=1,.destination=2,.sourceOffset=32,
               .destinationOffset=64,.size=128});
        [decoder->blitEncoder endEncoding];[command commit];[command waitUntilCompleted];
        NSCAssert(command.status==MTLCommandBufferStatusCompleted,@"native copy completed");
        NSCAssert(!memcmp((uint8_t *)input.contents+32,(uint8_t *)output.contents+64,128),@"normal copy preserved");
        VZPVGAddressReply *result=reply.contents;
        *result=(VZPVGAddressReply){.marker=VZ_PVG_ADDRESS_QUERY};
        Decode(decoder,(VZPVGBufferCopy){.source=1,.destination=3,
               .sourceOffset=VZ_PVG_ADDRESS_QUERY,.destinationOffset=64,.size=8});
        NSCAssert(result->status==VZPVGAddressReady && result->address==input.gpuAddress+64,
                  @"real buffer address plus suballocation offset");

        // A nonzero number alone is not enough: dereference addresses returned
        // by the bridge in an actual indirect GPU calculation.
        uint64_t addresses[2];
        for (unsigned index=0;index<2;++index) {
            *result=(VZPVGAddressReply){.marker=VZ_PVG_ADDRESS_QUERY};
            Decode(decoder,(VZPVGBufferCopy){.source=index+1,.destination=3,
                   .sourceOffset=VZ_PVG_ADDRESS_QUERY,.size=8});
            addresses[index]=result->address;
        }
        id<MTLBuffer> arguments=[device newBufferWithBytes:addresses length:sizeof(addresses)
                                                   options:MTLResourceStorageModeShared];
        for (unsigned i=0;i<128;++i)((float *)input.contents)[i]=(float)i;
        memset(output.contents,0,output.length);
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
          "struct A { device const float* input [[id(0)]]; device float* output [[id(1)]]; };\n"
          "kernel void indirect(constant A& a [[buffer(0)]],uint i [[thread_position_in_grid]]) { if(i<128) a.output[i]=a.input[i]*2+1; }\n";
        NSError *error=nil;
        id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
        NSCAssert(library,@"test shader compiled: %@",error);
        id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:
                                      [library newFunctionWithName:@"indirect"] error:&error];
        NSCAssert(pipeline,@"test pipeline compiled: %@",error);
        command=[queue commandBuffer];
        id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
        [compute setComputePipelineState:pipeline];
        [compute setBuffer:arguments offset:0 atIndex:0];
        [compute useResource:input usage:MTLResourceUsageRead];
        [compute useResource:output usage:MTLResourceUsageWrite];
        [compute dispatchThreads:MTLSizeMake(128,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
        [compute endEncoding];[command commit];[command waitUntilCompleted];
        NSCAssert(command.status==MTLCommandBufferStatusCompleted,@"indirect calculation completed");
        for (unsigned i=0;i<128;++i)
            NSCAssert(((float *)output.contents)[i]==(float)i*2+1,@"indirect result %u",i);
        BOOL invalidRejected=NO;
        @try { Decode(decoder,(VZPVGBufferCopy){.source=1,.destination=3,
             .sourceOffset=VZ_PVG_ADDRESS_QUERY,.destinationOffset=512,.size=8}); }
        @catch (NSException *e) { invalidRejected=[e.name isEqual:@"VZPVGAddressBridge"]; }
        NSCAssert(invalidRejected,@"out of range suballocation rejected");
        BOOL markerRejected=NO;
        result->marker=0;
        @try { Decode(decoder,(VZPVGBufferCopy){.source=1,.destination=3,
             .sourceOffset=VZ_PVG_ADDRESS_QUERY,.size=8}); }
        @catch (NSException *e) { markerRejected=[e.name isEqual:@"VZPVGAddressBridge"]; }
        NSCAssert(markerRejected,@"reply marker required");
        decoder.buffers[@4]=[device newBufferWithLength:8 options:MTLResourceStorageModeShared];
        decoder.buffers[@5]=[device newBufferWithLength:24 options:MTLResourceStorageModePrivate];
        for (unsigned reference=4;reference<=5;++reference) {
            BOOL replyRejected=NO;
            @try { Decode(decoder,(VZPVGBufferCopy){.source=1,.destination=reference,
                 .sourceOffset=VZ_PVG_ADDRESS_QUERY,.size=8}); }
            @catch (NSException *e) { replyRejected=[e.name isEqual:@"VZPVGAddressBridge"]; }
            NSCAssert(replyRejected,@"undersized and private reply buffers rejected");
        }
        BridgeTestDecoder *other=[BridgeTestDecoder new];other.buffers=[NSMutableDictionary new];
        BOOL isolated=NO;
        @try { Decode(other,(VZPVGBufferCopy){.source=1,.destination=3,
             .sourceOffset=VZ_PVG_ADDRESS_QUERY,.size=8}); }
        @catch (NSException *e) { isolated=[e.name isEqual:@"MissingResource"]; }
        NSCAssert(isolated,@"object references are isolated per decoder");
        NSCAssert(!VZInstallPVGResourceAddressBridge(),@"installation refused outside the shipped VMM framework");
        puts("PASS: normal copy, native GPU address, 128 indirect results, bounds, reply validation, object-table isolation, install guard");
    }
    return 0;
}
