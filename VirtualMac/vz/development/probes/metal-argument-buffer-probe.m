#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

static BOOL finish(id<MTLCommandBuffer> command, const char *stage) {
    [command commit];
    for (unsigned count = 0; count < 500 && command.status < MTLCommandBufferStatusCompleted; ++count)
        usleep(10000);
    printf("stage=%s status=%lu error=%s\n", stage,
           (unsigned long)command.status, command.error.localizedDescription.UTF8String ?: "none");
    return command.status == MTLCommandBufferStatusCompleted;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    unsigned modes=3;
    BOOL language24=NO;
    int selectedMode=-1;
    for (int index=1; index<argc; ++index) {
        if (!strcmp(argv[index],"--buffers")) modes=2;
        else if (!strcmp(argv[index],"--language24")) language24=YES;
        else if (!strcmp(argv[index],"--mode=0")) selectedMode=0;
        else if (!strcmp(argv[index],"--mode=1")) selectedMode=1;
        else if (!strcmp(argv[index],"--mode=2")) selectedMode=2;
        else { fputs("usage: probe [--buffers] [--language24] [--mode=0|1|2]\n",stderr); return 1; }
    }
    if (selectedMode >= (int)modes) return 1;
    unsigned failedModes = 0;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        printf("device=%s argumentTier=%lu\n", device.name.UTF8String,
               (unsigned long)device.argumentBuffersSupport);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void direct(device const float* input [[buffer(0)]],device float* output [[buffer(1)]],uint i [[thread_position_in_grid]]) { if(i<128) output[i]=input[i]*2+1; }\n"
            "struct A { device const float* input [[id(0)]]; device float* output [[id(1)]]; };\n"
            "kernel void indirect(constant A& a [[buffer(0)]],uint i [[thread_position_in_grid]]) { if(i<128) a.output[i]=a.input[i]*2+1; }\n";
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        if (language24) options.languageVersion = MTLLanguageVersion2_4;
        printf("requestedLanguage=%s\n",language24 ? "2.4" : "default");
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        if (!library) { printf("compile=%s\n",error.description.UTF8String); return 3; }
        const NSUInteger length = 128 * sizeof(float);
        for (unsigned mode = 0; mode < modes; ++mode) {
            if (selectedMode >= 0 && mode != (unsigned)selectedMode) continue;
            @autoreleasepool {
                printf("mode=%u\n",mode);
                id<MTLFunction> function = [library newFunctionWithName:mode ? @"indirect" : @"direct"];
                id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
                if (!pipeline) { printf("pipeline=%s\n",error.description.UTF8String); return 4; }
                id<MTLBuffer> staging = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
                id<MTLBuffer> readback = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
                for (unsigned i = 0; i < 128; ++i) ((float *)staging.contents)[i] = (float)i;
                id<MTLHeap> heap = nil;
                id<MTLBuffer> input = nil, output = nil;
                if (mode == 2) {
                    MTLSizeAndAlign allocation = [device heapBufferSizeAndAlignWithLength:length options:MTLResourceStorageModePrivate];
                    MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
                    descriptor.storageMode = MTLStorageModePrivate;
                    descriptor.size = 4 * (allocation.size + allocation.align);
                    heap = [device newHeapWithDescriptor:descriptor];
                    printf("heapSize=%lu allocationSize=%lu alignment=%lu heapClass=%s\n",
                           (unsigned long)descriptor.size,(unsigned long)allocation.size,
                           (unsigned long)allocation.align,heap ? object_getClassName(heap) : "nil");
                    input = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
                    output = [heap newBufferWithLength:length options:MTLResourceStorageModePrivate];
                    if (!input || !output) { puts("heap allocation failed"); return 5; }
                    id<MTLCommandBuffer> upload = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [upload blitCommandEncoder];
                    [blit copyFromBuffer:staging sourceOffset:0 toBuffer:input destinationOffset:0 size:length];
                    [blit endEncoding];
                    if (!finish(upload,"private-upload")) return 6;
                } else {
                    input = staging;
                    output = readback;
                }
                id<MTLBuffer> argumentBuffer = nil;
                if (mode) {
                    if (mode==1 && getenv("VZ_PVG_PROBE_MATERIALIZE_BUFFERS")) {
                        id<MTLCommandBuffer> materialize=[queue commandBuffer];
                        id<MTLBlitCommandEncoder> blit=[materialize blitCommandEncoder];
                        [blit copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
                        [blit fillBuffer:output range:NSMakeRange(0,length) value:0];
                        [blit endEncoding];
                        if (!finish(materialize,"materialize-buffers")) return 11;
                    }
                    id<MTLArgumentEncoder> arguments = [function newArgumentEncoderWithBufferIndex:0];
                    if (!arguments) { puts("argument encoder unavailable"); return 7; }
                    argumentBuffer = [device newBufferWithLength:arguments.encodedLength options:MTLResourceStorageModeShared];
                    [arguments setArgumentBuffer:argumentBuffer offset:0];
                    [arguments setBuffer:input offset:0 atIndex:0];
                    [arguments setBuffer:output offset:0 atIndex:1];
                    const uint64_t *encoded = argumentBuffer.contents;
                    SEL addressSelector = sel_registerName("gpuAddress");
                    BOOL hasAddress = [input respondsToSelector:addressSelector];
                    uint64_t inputAddress = hasAddress ? ((uint64_t (*)(id,SEL))objc_msgSend)(input,addressSelector) : 0;
                    uint64_t outputAddress = hasAddress ? ((uint64_t (*)(id,SEL))objc_msgSend)(output,addressSelector) : 0;
                    printf("functionClass=%s encoderClass=%s bufferClass=%s argumentLength=%lu words=%llx,%llx\n",
                           object_getClassName(function),object_getClassName(arguments),object_getClassName(input),
                           (unsigned long)arguments.encodedLength,
                           (unsigned long long)encoded[0],(unsigned long long)encoded[1]);
                    printf("hasGpuAddress=%d inputAddress=%llx outputAddress=%llx\n",hasAddress,
                           (unsigned long long)inputAddress,(unsigned long long)outputAddress);
                }
                id<MTLCommandBuffer> compute = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [compute computeCommandEncoder];
                [encoder setComputePipelineState:pipeline];
                if (mode) {
                    [encoder setBuffer:argumentBuffer offset:0 atIndex:0];
                    if (heap) [encoder useHeap:heap];
                    [encoder useResource:input usage:MTLResourceUsageRead];
                    [encoder useResource:output usage:MTLResourceUsageWrite];
                } else {
                    [encoder setBuffer:input offset:0 atIndex:0];
                    [encoder setBuffer:output offset:0 atIndex:1];
                }
                [encoder dispatchThreads:MTLSizeMake(128,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
                [encoder endEncoding];
                if (!finish(compute,"compute")) return 8;
                if (mode == 2) {
                    id<MTLCommandBuffer> download = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [download blitCommandEncoder];
                    [blit copyFromBuffer:output sourceOffset:0 toBuffer:readback destinationOffset:0 size:length];
                    [blit endEncoding];
                    if (!finish(download,"private-readback")) return 9;
                }
                unsigned mismatches = 0;
                for (unsigned i = 0; i < 128; ++i)
                    if (((float *)readback.contents)[i] != (float)i * 2 + 1) ++mismatches;
                printf("mode=%u mismatches=%u first=%g last=%g\n",mode,mismatches,
                       ((float *)readback.contents)[0],((float *)readback.contents)[127]);
                if (mismatches) ++failedModes;
            }
        }
    }
    return failedModes ? 10 : 0;
}
