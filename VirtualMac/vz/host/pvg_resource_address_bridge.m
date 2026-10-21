#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include "pvg_resource_address_protocol.h"

static Ivar gBlitEncoderIvar;

// Match Ventura's decodeCopyFromBufferToBuffer:withIterator: exactly for normal
// copies. The same reader validates sizes and advances the iterator once.
static void DecodeBufferCopy(id self, SEL selector, const void *header, id iterator) {
    (void)selector;
    VZPVGBufferCopy copy = {0};
    ((void (*)(id, SEL, const void *, id, NSUInteger, void *))objc_msgSend)(
        self, sel_registerName("readCommand:withIterator:expectedSize:into:"),
        header, iterator, sizeof(copy), &copy);
    SEL getBuffer = sel_registerName("getBufferForReferenceNonNull:");
    id<MTLBuffer> source = ((id (*)(id, SEL, uint32_t))objc_msgSend)(self, getBuffer, copy.source);
    id<MTLBuffer> destination = ((id (*)(id, SEL, uint32_t))objc_msgSend)(self, getBuffer, copy.destination);
    if (copy.sourceOffset == VZ_PVG_ADDRESS_QUERY && copy.size == sizeof(uint64_t)) {
        // Addresses come from resources in this decoder's own object table;
        // references from another guest task cannot select an unrelated buffer.
        if (destination.storageMode != MTLStorageModeShared ||
            destination.length < sizeof(VZPVGAddressReply) || !destination.contents)
            [NSException raise:@"VZPVGAddressBridge" format:@"invalid reply buffer"];
        VZPVGAddressReply *reply = destination.contents;
        if (reply->marker != VZ_PVG_ADDRESS_QUERY || copy.destinationOffset >= source.length)
            [NSException raise:@"VZPVGAddressBridge" format:@"invalid address query"];
        SEL addressSelector = sel_registerName("gpuAddress");
        uint64_t address = [source respondsToSelector:addressSelector]
            ? ((uint64_t (*)(id, SEL))objc_msgSend)(source, addressSelector) : 0;
        if (address && copy.destinationOffset > UINT64_MAX - address)
            [NSException raise:@"VZPVGAddressBridge" format:@"address overflow"];
        reply->address = address ? address + copy.destinationOffset : 0;
        reply->status = address ? VZPVGAddressReady : VZPVGAddressUnavailable;
        static unsigned queries;
        if (__atomic_add_fetch(&queries, 1, __ATOMIC_RELAXED) <= 32) {
            int fd = open("/tmp/virtualmac-pvg-resource-bridge.log", O_WRONLY|O_CREAT|O_APPEND, 0600);
            if (fd >= 0) {
                dprintf(fd, "buffer=%u nativeAddress=%llx offset=%llu reply=%u status=%llu\n",
                        copy.source, (unsigned long long)address,
                        (unsigned long long)copy.destinationOffset, copy.destination,
                        (unsigned long long)reply->status);
                close(fd);
            }
        }
        return;
    }
    id<MTLBlitCommandEncoder> encoder = object_getIvar(self, gBlitEncoderIvar);
    [encoder copyFromBuffer:source sourceOffset:copy.sourceOffset toBuffer:destination
         destinationOffset:copy.destinationOffset size:copy.size];
}

BOOL VZInstallPVGResourceAddressBridge(void) {
    static BOOL installed;
    if (__atomic_load_n(&installed, __ATOMIC_ACQUIRE)) return YES;
    Class cls = NSClassFromString(@"MTLDeserializerBlitDecoder");
    Method method = class_getInstanceMethod(cls,
        sel_registerName("decodeCopyFromBufferToBuffer:withIterator:"));
    gBlitEncoderIvar = class_getInstanceVariable(cls, "blitEncoder");
    Dl_info image = {0};
    Method reader = class_getInstanceMethod(cls,
        sel_registerName("readCommand:withIterator:expectedSize:into:"));
    Method lookup = class_getInstanceMethod(cls, sel_registerName("getBufferForReferenceNonNull:"));
    if (!method || !reader || !lookup || !gBlitEncoderIvar ||
        method_getNumberOfArguments(method) != 4 ||
        method_getNumberOfArguments(reader) != 6 || method_getNumberOfArguments(lookup) != 3 ||
        ivar_getTypeEncoding(gBlitEncoderIvar)[0] != '@' ||
        !dladdr((void *)method_getImplementation(method), &image) || !image.dli_fname ||
        !strstr(image.dli_fname, "/VirtualMac/payload/Frameworks/MetalSerializer.framework/"))
        return NO;
    if (__sync_bool_compare_and_swap(&installed, NO, YES))
        method_setImplementation(method, (IMP)DecodeBufferCopy);
    return YES;
}

#ifdef VZ_PVG_BRIDGE_DIAGNOSTIC_INJECT
__attribute__((constructor)) static void InstallDiagnosticBridge(void) {
    const char *path = NSProcessInfo.processInfo.arguments.firstObject.UTF8String;
    if (!path || !strstr(path, "/VirtualMachine.xpc/Contents/MacOS/")) return;
    BOOL installed = VZInstallPVGResourceAddressBridge();
    int fd = open("/tmp/virtualmac-pvg-resource-bridge.log", O_WRONLY|O_CREAT|O_APPEND, 0600);
    if (fd >= 0) { dprintf(fd,"installed=%d pid=%d\n",installed,getpid()); close(fd); }
}
#endif
