#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "PVGDeviceInfoReply.h"

static inline BOOL PVGDeviceInfoHostBool(id device, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod([device class], selector);
    const char *types = method == NULL ? NULL : method_getTypeEncoding(method);
    return types != NULL && method_getNumberOfArguments(method) == 2 &&
        (types[0] == 'B' || types[0] == 'c') &&
        ((BOOL (*)(id, SEL))objc_msgSend)(device, selector);
}

static inline NSUInteger PVGDeviceInfoHostUInt(id device, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod([device class], selector);
    const char *types = method == NULL ? NULL : method_getTypeEncoding(method);
    return types != NULL && method_getNumberOfArguments(method) == 2 &&
        (types[0] == 'Q' || types[0] == 'I')
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(device, selector) : 0;
}

static inline BOOL PVGDeviceInfoMethodSupported(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 5)
        return NO;
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'v')
        return NO;
    for (unsigned index = 2; index < 5; ++index) {
        method_getArgumentType(method, index, type, sizeof(type));
        if (type[0] != 'I')
            return NO;
    }
    return YES;
}

static inline uint32_t PVGDeviceInfoHostFamily(id<MTLDevice> device) {
    for (uint32_t family = 1007; family >= 1001; --family)
        if ([device supportsFamily:(MTLGPUFamily)family])
            return family;
    return 0;
}

static inline BOOL PVGDeviceInfoResolveHostPair(id<MTLDevice> device,
                                               VMDevInfoPair reference,
                                               VMDevInfoPair *resolved) {
    if (device == nil || ![device respondsToSelector:@selector(supportsFamily:)])
        return NO;
    uint32_t family = PVGDeviceInfoHostFamily(device);
    if (family < 1005)
        return NO;
    NSUInteger value = 0;
    switch (reference.key) {
        case 23: value = PVGDeviceInfoHostBool(device, @"supportsTileShaders"); break;
        case 24: value = PVGDeviceInfoHostBool(device, @"supportsImageblocks"); break;
        case 25: value = PVGDeviceInfoHostBool(device, @"supportsRasterOrderGroups"); break;
        case 26: value = PVGDeviceInfoHostBool(device, @"supportsMemoryOrderAtomics"); break;
        case 27: value = PVGDeviceInfoHostBool(device, @"supportsLargeMRT"); break;
        case 28:
            value = 1;
            if (PVGDeviceInfoHostBool(device, @"supportsDynamicAttributeStride"))
                value |= 1u << 1;
            if (PVGDeviceInfoHostBool(device, @"supportsTexture2DMultisampleArray"))
                value |= 1u << 2;
            break;
        case 29:
            value = [device maxThreadsPerThreadgroup].width;
            break;
        case 30:
        case 31:
            value = [device maxThreadgroupMemoryLength];
            break;
        case 32:
            value = reference.value;
            break;
        case 33:
            if ([device argumentBuffersSupport] == MTLArgumentBuffersTier2)
                value |= 1u << 5;
            if (PVGDeviceInfoHostBool(device, @"supportsSIMDReduction"))
                value |= 1u << 6;
            if (PVGDeviceInfoHostBool(device, @"supportsFloat16BCubicFiltering"))
                value |= 1u << 7;
            if (PVGDeviceInfoHostBool(device, @"supportsSIMDShuffleAndFill"))
                value |= 1u << 8;
            if (PVGDeviceInfoHostBool(device, @"supportsConditionalLoadStore"))
                value |= 1u << 9;
            break;
        case 34:
            value = PVGDeviceInfoHostUInt(device, @"gpuCoreCount");
            break;
        case 35:
            value = PVGDeviceInfoHostUInt(device, @"maxTextureLayers");
            break;
        case 36:
            value = PVGDeviceInfoHostUInt(device, @"maxPredicatedNesting");
            break;
        case 37:
            value = family;
            break;
        case 40:
            value = reference.value;
            break;
        default:
            return NO;
    }
    if (value == 0)
        return NO;
    *resolved = (VMDevInfoPair){reference.key, (uint32_t)MIN(value, reference.value)};
    return YES;
}
