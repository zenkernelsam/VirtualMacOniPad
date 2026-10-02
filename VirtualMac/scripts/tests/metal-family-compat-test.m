#import "../../vz/guest/OpenGLPVGCompat.m"

@interface TargetlessFixture : NSObject
@property BOOL targetless;
@property NSUInteger queries;
@end
@implementation TargetlessFixture
- (BOOL)supportsRenderPassWithoutRenderTarget {
    ++_queries;
    return _targetless;
}
@end

@interface UnknownTargetlessFixture : NSObject
@end
@implementation UnknownTargetlessFixture
- (NSUInteger)supportsRenderPassWithoutRenderTarget { return 0; }
@end

static BOOL originalSupported = YES;
static BOOL OriginalFamily(id self, SEL selector, NSUInteger family) {
    (void)self;
    (void)selector;
    (void)family;
    return originalSupported;
}

static void Require(BOOL condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", name);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        gSupportsFamily = (IMP)OriginalFamily;
        TargetlessFixture *device = [TargetlessFixture new];
        Require(!PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "Mac2 is incomplete when the device cannot render without targets");
        Require(device.queries == 1, "the decision queries the device capability");
        device.targetless = YES;
        Require(PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "a complete native Mac2 declaration remains supported");
        originalSupported = NO;
        NSUInteger queries = device.queries;
        Require(!PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "native refusal is never widened");
        Require(device.queries == queries, "a native refusal needs no capability query");
        originalSupported = YES;
        Require(PVGSupportsFamily([NSObject new], @selector(supportsFamily:), MTLGPUFamilyMac2),
                "an absent getter leaves the original declaration unchanged");
        Require(PVGSupportsFamily([UnknownTargetlessFixture new], @selector(supportsFamily:), MTLGPUFamilyMac2),
                "an unknown getter ABI leaves the original declaration unchanged");
        device.targetless = NO;
        for (NSUInteger family = MTLGPUFamilyMac2 - 1; family <= MTLGPUFamilyMac2 + 3; ++family)
            if (family != MTLGPUFamilyMac2)
                Require(PVGSupportsFamily(device, @selector(supportsFamily:), family),
                        "unrelated families remain unchanged");
        originalSupported = NO;
        Require(PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyApple7),
                "the existing Apple7 OpenGL profile is retained");
        Require(!PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyApple8),
                "the existing Apple7 OpenGL ceiling is retained");
        gNativeSupportsFamily = (IMP)OriginalFamily;
        gNativeSupportsFeatureSet = (IMP)OriginalFamily;
        originalSupported = YES;
        Require(!PVGNativeSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "the native Metal family path uses the same capability decision");
        Require(!PVGNativeSupportsFeatureSet(device, @selector(supportsFeatureSet:), kPVGMac2FeatureSet),
                "the equivalent legacy feature set is consistent with Mac2");
        Require(PVGNativeSupportsFeatureSet(device, @selector(supportsFeatureSet:), kPVGMac2FeatureSet - 1),
                "unrelated legacy feature sets remain unchanged");
        setenv("VIRTUAL_MAC_METAL_FAMILY_COMPAT", "0", 1);
        Require(PVGNativeSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "the per-process disable switch preserves the native declaration");
        Require(PVGSupportsFamily(device, @selector(supportsFamily:), MTLGPUFamilyMac2),
                "the same disable switch applies to the GL path");
        unsetenv("VIRTUAL_MAC_METAL_FAMILY_COMPAT");
        puts("PASS: capability-derived Mac2 compatibility and unchanged GL profile");
    }
    return 0;
}
