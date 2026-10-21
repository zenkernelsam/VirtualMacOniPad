#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "modern_pvg_linear_texture.h"

static unsigned diagnosticCount;

static bool NativeAlignmentABI(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return false;
    char *result = method_copyReturnType(method);
    char *format = method_copyArgumentType(method, 2);
    bool valid = !strcmp(result, @encode(NSUInteger)) &&
                 !strcmp(format, @encode(NSUInteger));
    free(result);
    free(format);
    return valid;
}

static NSUInteger DescriptorPitchAlignment(id device, SEL selector,
                    MTLTextureDescriptor *descriptor, NSUInteger *mustMatchExactly) {
    (void)selector;
    // Mac27 _MTLDevice's native wrapper does not read or write this slot. It
    // only queries descriptor.pixelFormat and delegates to the private getter.
    // In particular this is NSUInteger*, not BOOL*. Preserve NULL and sentinels.
    (void)mustMatchExactly;
    NSUInteger format = descriptor.pixelFormat;
    SEL legacy = sel_registerName("minLinearTextureAlignmentForPixelFormat:");
    NSUInteger alignment = ((NSUInteger (*)(id, SEL, NSUInteger))objc_msgSend)
        (device, legacy, format);
    if (__sync_fetch_and_add(&diagnosticCount, 1) < 16)
        fprintf(stderr, "[ModernLinearTexture] device=%s format=%llu nativeAlignment=%llu outputUntouched\n",
                object_getClassName(device), (unsigned long long)format,
                (unsigned long long)alignment);
    return alignment;
}

bool VZModernInstallLinearTextureCompatibility(id device) {
    const char *role = getenv("VZ_PVG_TASK_ROLE");
    const char *version = getenv("VZ_PVG_BACKEND_VERSION");
    if (!device || sizeof(NSUInteger) != 8 || !role || strcmp(role, "server") ||
        !version || strcmp(version, "27")) return false;
    Class cls = object_getClass(device);
    SEL selector = sel_registerName("minLinearTexturePitchAlignmentForDescriptor:mustMatchExactly:");
    if (class_getInstanceMethod(cls, selector) || [device respondsToSelector:selector])
        return false;
    SEL legacy = sel_registerName("minLinearTextureAlignmentForPixelFormat:");
    if (!NativeAlignmentABI(class_getInstanceMethod(cls, legacy))) {
        fprintf(stderr, "[ModernLinearTexture] device=%s native private alignment ABI unavailable\n",
                class_getName(cls));
        return false;
    }
    bool installed = class_addMethod(cls, selector, (IMP)DescriptorPitchAlignment,
                                    "Q32@0:8@16^Q24");
    if (installed)
        fprintf(stderr, "[ModernLinearTexture] device=%s installed native descriptor delegation\n",
                class_getName(cls));
    return installed;
}
