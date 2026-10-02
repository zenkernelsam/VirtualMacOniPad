#import "../../vz/host/PVGDeviceInfoProfile.h"

@interface ProfileTestDevice : NSObject
@property MTLGPUFamily family;
@property NSUInteger memory;
@property NSUInteger threads;
@property BOOL tier2;
@property BOOL shaderFeatures;
@end

@implementation ProfileTestDevice
- (BOOL)supportsFamily:(MTLGPUFamily)family { return family >= 1001 && family <= self.family; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(self.threads, self.threads, 64); }
- (NSUInteger)maxThreadgroupMemoryLength { return self.memory; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return self.tier2 ? MTLArgumentBuffersTier2 : MTLArgumentBuffersTier1; }
- (BOOL)supportsSIMDReduction { return self.shaderFeatures; }
- (BOOL)supportsFloat16BCubicFiltering { return self.shaderFeatures; }
- (BOOL)supportsSIMDShuffleAndFill { return self.shaderFeatures; }
- (BOOL)supportsConditionalLoadStore { return self.shaderFeatures; }
- (BOOL)supportsTileShaders { return self.shaderFeatures; }
- (void)getDeviceInfo:(uint32_t)keyLimit length:(uint32_t)count dst:(uint32_t)frame {
    (void)keyLimit; (void)count; (void)frame;
}
- (void)wrongDeviceInfo:(uint64_t)keyLimit length:(uint32_t)count dst:(uint32_t)frame {
    (void)keyLimit; (void)count; (void)frame;
}
@end

@interface BadGetterDevice : NSObject
@end
@implementation BadGetterDevice
- (id)supportsTileShaders { return @YES; }
- (id)gpuCoreCount { return @8; }
@end

static void Require(BOOL condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        ProfileTestDevice *mock = [ProfileTestDevice new];
        mock.family = 1007;
        mock.memory = 16384;
        mock.threads = 512;
        mock.tier2 = YES;
        id<MTLDevice> device = (id)mock;
        VMDevInfoPair pair;
        Require(PVGDeviceInfoMethodSupported(class_getInstanceMethod([mock class],
                @selector(getDeviceInfo:length:dst:))), "decoded uint32 method ABI is accepted");
        Require(!PVGDeviceInfoMethodSupported(class_getInstanceMethod([mock class],
                @selector(wrongDeviceInfo:length:dst:))), "changed method ABI is refused");
        Require(!PVGDeviceInfoMethodSupported(NULL), "missing method ABI is refused");
        BadGetterDevice *bad = [BadGetterDevice new];
        Require(!PVGDeviceInfoHostBool(bad, @"supportsTileShaders") &&
                PVGDeviceInfoHostUInt(bad, @"gpuCoreCount") == 0,
                "object-returning private getters are not called as integers");
        Require(PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){37, 1009}, &pair) &&
                pair.value == 1007, "family is clamped to queried Apple7");
        Require(PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){33, 4095}, &pair) &&
                pair.value == 32, "tier2 alone enables only argument-buffer bit");
        mock.shaderFeatures = YES;
        Require(PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){33, 4095}, &pair) &&
                pair.value == 0x3e0, "shader flags never enable resource or new command-stream flags");
        Require(PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){29, 1024}, &pair) &&
                pair.value == 512, "compute threads are host-clamped");
        Require(PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){30, 32768}, &pair) &&
                pair.value == 16384, "compute memory is host-clamped");
        const uint32_t excluded[] = {10, 17, 18, 19, 20, 21, 22, 38, 39, 41, 42, 44};
        for (size_t index = 0; index < sizeof(excluded) / sizeof(excluded[0]); ++index)
            Require(!PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){excluded[index], 1}, &pair),
                    "unknown or incompatible transport features are not advertised");
        Require(!PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){34, 8}, &pair),
                "missing host getter does not invent GPU core count");
        mock.shaderFeatures = NO;
        mock.tier2 = NO;
        Require(!PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){33, 4095}, &pair),
                "tier1 with no queried flags does not claim tier2");
        mock.family = 1003;
        Require(!PVGDeviceInfoResolveHostPair(device, (VMDevInfoPair){37, 1009}, &pair),
                "older unsupported host profile is refused");
        Require(!PVGDeviceInfoResolveHostPair(nil, (VMDevInfoPair){37, 1009}, &pair),
                "missing host device is refused");
        printf("PASS: host-clamped experimental profile; no Apple9, AIR widening or protocol-only bits\n");
    }
    return 0;
}
