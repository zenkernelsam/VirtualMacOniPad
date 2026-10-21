#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "modern_pvg_shader_audit.h"

static id (*nativeLibraryData)(id, SEL, dispatch_data_t, NSError **);
// Count and bytes are reserved together so concurrent library creation cannot
// cross either limit. A failed file write consumes its reservation, giving a
// conservative upper bound on diagnostic storage for the entire GPU task.
static uint64_t captureReservations;
static const unsigned captureLimit = 128;
static const uint32_t captureBytesLimit = 32 * 1024 * 1024;

static BOOL ReserveCapture(size_t bytes, unsigned *index) {
    uint64_t state = __atomic_load_n(&captureReservations, __ATOMIC_RELAXED);
    for (;;) {
        unsigned count = (unsigned)(state >> 32);
        uint32_t total = (uint32_t)state;
        if (count >= captureLimit || bytes > captureBytesLimit - total) return NO;
        uint64_t replacement = ((uint64_t)(count + 1) << 32) | (total + bytes);
        if (__atomic_compare_exchange_n(&captureReservations, &state, replacement,
                                        true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            *index = count;
            return YES;
        }
    }
}

static id AuditLibraryData(id device, SEL selector, dispatch_data_t data,
                           NSError **error) {
    uint64_t state = __atomic_load_n(&captureReservations, __ATOMIC_RELAXED);
    const char *endpoint = getenv("VZ_PVG_TASK_ENDPOINT_FILE");
    if ((state >> 32) >= captureLimit || (uint32_t)state >= captureBytesLimit ||
        !data || !endpoint || dispatch_data_get_size(data) > 16 * 1024 * 1024)
        return nativeLibraryData(device, selector, data, error);

    const void *bytes = NULL;
    size_t size = 0;
    dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &size);
    unsigned index = 0;
    if (!mapped || !bytes || !size || size > 16 * 1024 * 1024 ||
        !ReserveCapture(size, &index)) {
        if (mapped) dispatch_release(mapped);
        return nativeLibraryData(device, selector, data, error);
    }
    NSError *localError = nil;
    NSError **output = error ?: &localError;
    id result = nativeLibraryData(device, selector, data, output);
    {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes, (CC_LONG)size, digest);
        char hash[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        for (unsigned i = 0; i < sizeof(digest); ++i)
            snprintf(hash + i * 2, 3, "%02x", digest[i]);
        NSString *directory = [[NSString stringWithUTF8String:endpoint]
            stringByDeletingLastPathComponent];
        NSString *path = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"shader-input-%02u.metallib", index]];
        NSData *input = [NSData dataWithBytes:bytes length:size];
        BOOL saved = [input writeToFile:path atomically:YES];
        NSArray *names = result ? [result functionNames] : nil;
        NSError *failure = result ? nil : *output;
        fprintf(stderr,
            "[ModernShaderAudit] input=%u bytes=%zu sha256=%s saved=%d "
            "path=%s names=%s error=%s\n", index, size, hash, saved,
            path.fileSystemRepresentation, names.description.UTF8String ?: "none",
            failure.description.UTF8String ?: "none");
    }
    if (mapped) dispatch_release(mapped);
    return result;
}

bool VZModernInstallShaderAudit(id device) {
    // Full input capture is an explicit diagnostic opt-in, outside the cache.
    const char *capture = getenv("VZ_PVG_SHADER_INPUT_AUDIT");
    if (!capture || strcmp(capture, "1")) return false;
    const char *role = getenv("VZ_PVG_TASK_ROLE");
    const char *version = getenv("VZ_PVG_BACKEND_VERSION");
    if (!device || !role || strcmp(role, "server") || !version ||
        strcmp(version, "27") || nativeLibraryData) return false;
    SEL selector = sel_registerName("newLibraryWithData:error:");
    Class cls = object_getClass(device);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return false;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    // Give this device class its own implementation if the method is inherited.
    if (!class_addMethod(cls, selector, (IMP)AuditLibraryData, types))
        method_setImplementation(class_getInstanceMethod(cls, selector),
                                 (IMP)AuditLibraryData);
    nativeLibraryData = (void *)original;
    fprintf(stderr,
        "[ModernShaderAudit] installed native library input audit limit=%u bytes=%u\n",
        captureLimit, captureBytesLimit);
    return true;
}
