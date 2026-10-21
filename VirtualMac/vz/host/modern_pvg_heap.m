#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "modern_pvg_heap.h"

static Ivar transferHeapBufferIvar;
static Ivar nativeHeapIvar;
static Ivar lengthIvar;
static unsigned heapDiagnosticCount;
static char measuredHeapBaseKey;
static char originalHeapAddressKey;
static uint64_t NativeGPUAddress(id object);

static uint64_t DriverHeapGPUAddress(id heap, SEL selector) {
    id original = nil;
    for (Class cls = object_getClass(heap); cls && !original; cls = class_getSuperclass(cls))
        original = objc_getAssociatedObject((id)cls, &originalHeapAddressKey);
    if (!original) return NativeGPUAddress(heap);
    uint64_t (*native)(id, SEL) = (void *)[original pointerValue];
    return native ? native(heap, selector) : 0;
}

static uint64_t LegacyHeapGPUAddress(id heap, SEL selector) {
    // Adding a method to a concrete AGX heap class affects only this process.
    // Unmarked instances retain their driver's native result, including zero.
    uint64_t address = DriverHeapGPUAddress(heap, selector);
    if (address) return address;
    NSNumber *measured = objc_getAssociatedObject(heap, &measuredHeapBaseKey);
    return measured ? measured.unsignedLongLongValue : 0;
}

static uint64_t NativeGPUAddress(id object) {
    SEL selector = sel_registerName("gpuAddress");
    return [object respondsToSelector:selector] ?
        ((uint64_t (*)(id, SEL))objc_msgSend)(object, selector) : 0;
}

static bool ValidIvar(Class cls, Ivar ivar, const char *type, size_t size) {
    if (!ivar || !ivar_getTypeEncoding(ivar) ||
        strncmp(ivar_getTypeEncoding(ivar), type, strlen(type))) return false;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(cls);
    return offset >= 0 && (size_t)offset <= instanceSize &&
        size <= instanceSize - (size_t)offset;
}

static bool RegisterNativeHeapBase(id<MTLHeap> heap, id<MTLBuffer> buffer) {
    SEL offsetSelector = sel_registerName("heapOffset");
    if (!buffer || !heap || buffer.heap != heap || !heap.size ||
        buffer.length < heap.size || ![buffer respondsToSelector:offsetSelector] ||
        ((NSUInteger (*)(id, SEL))objc_msgSend)(buffer, offsetSelector) != 0) return false;
    uint64_t base = NativeGPUAddress(buffer);
    if (!base) return false;
    uint64_t native = DriverHeapGPUAddress(heap, sel_registerName("gpuAddress"));
    // Preserve an already implemented native heap address. A disagreement is
    // evidence that the alias cannot safely supply the heap's base.
    if (native) return native == base;
    Class cls = object_getClass(heap);
    @synchronized((id)cls) {
        SEL selector = sel_registerName("gpuAddress");
        Method method = class_getInstanceMethod(cls, selector);
        IMP implementation = method ? method_getImplementation(method) : NULL;
        if (implementation != (IMP)LegacyHeapGPUAddress) {
            objc_setAssociatedObject((id)cls, &originalHeapAddressKey,
                [NSValue valueWithPointer:(const void *)implementation], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // This NSNumber comes from the live offset-zero native buffer.
            // Retaining the buffer here would create a heap-buffer cycle.
            objc_setAssociatedObject(heap, &measuredHeapBaseKey, @(base),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            const char *types = method ? method_getTypeEncoding(method) : "Q@:";
            if (!class_addMethod(cls, selector, (IMP)LegacyHeapGPUAddress, types))
                method_setImplementation(method, (IMP)LegacyHeapGPUAddress);
        } else {
            objc_setAssociatedObject(heap, &measuredHeapBaseKey, @(base),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return NativeGPUAddress(heap) == base;
}

static id LegacyHeapBuffer(id resource, SEL selector) {
    (void)selector;
    id<MTLBuffer> buffer = object_getIvar(resource, transferHeapBufferIvar);
    id<MTLHeap> heap = object_getIvar(resource, nativeHeapIvar);
    NSUInteger length = 0;
    memcpy(&length, (const char *)resource + ivar_getOffset(lengthIvar), sizeof(length));
    NSUInteger bufferLength = [buffer respondsToSelector:@selector(length)] ? buffer.length : 0;
    bool valid = buffer && heap &&
        [buffer conformsToProtocol:@protocol(MTLBuffer)] &&
        [heap conformsToProtocol:@protocol(MTLHeap)] &&
        buffer.heap == heap && buffer.length == length;
    uint64_t originalAddress = DriverHeapGPUAddress(heap, sel_registerName("gpuAddress"));
    bool baseVerified = valid && RegisterNativeHeapBase(heap, buffer);
    if (__sync_fetch_and_add(&heapDiagnosticCount, 1) < 12) {
        SEL offsetSelector = sel_registerName("heapOffset");
        uint64_t offset = [buffer respondsToSelector:offsetSelector] ?
            ((NSUInteger (*)(id, SEL))objc_msgSend)(buffer, offsetSelector) : UINT64_MAX;
        fprintf(stderr,
            "[ModernGPUTask] legacy heap buffer valid=%d resource=%p heap=%p alias=%p "
            "length=%lu aliasLength=%lu heapSize=%lu aliasOffset=0x%llx originalHeapAddress=0x%llx "
            "heapAddress=0x%llx aliasAddress=0x%llx baseVerified=%d\n",
            valid, resource, heap, buffer, (unsigned long)length,
            (unsigned long)bufferLength,
            (unsigned long)([heap respondsToSelector:@selector(size)] ? heap.size : 0),
            (unsigned long long)offset, (unsigned long long)originalAddress,
            (unsigned long long)NativeGPUAddress(heap),
            (unsigned long long)NativeGPUAddress(buffer), baseVerified);
    }
    // Native init creates this buffer with offset 0 and retains it until
    // dealloc. Return the existing object with getBuffer's borrowed ownership.
    // Its storage, address, contents, and paging remain Apple's native objects.
    return valid ? buffer : nil;
}

bool VZModernInstallHeapCompatibility(void) {
    Class cls = objc_getClass("PGLegacyHeapResource");
    Class parent = objc_getClass("PGHeapResource");
    Class resource = objc_getClass("PGResource");
    if (!cls || !parent || !resource || class_getSuperclass(cls) != parent ||
        class_getSuperclass(parent) != resource) return false;
    @synchronized((id)cls) {
        SEL selector = sel_registerName("getBuffer");
        Method inherited = class_getInstanceMethod(cls, selector);
        Method abstract = class_getInstanceMethod(resource, selector);
        if (!inherited || !abstract) return false;
        if (method_getImplementation(inherited) == (IMP)LegacyHeapBuffer) return true;
        // A different backend may implement this accessor itself. Preserve it.
        if (method_getImplementation(inherited) != method_getImplementation(abstract))
            return false;
        Ivar buffer = class_getInstanceVariable(cls, "_transferHeapBuffer");
        Ivar heap = class_getInstanceVariable(cls, "_heap");
        Ivar length = class_getInstanceVariable(cls, "_length");
        if (!ValidIvar(cls, buffer, "@", sizeof(id)) ||
            !ValidIvar(cls, heap, "@", sizeof(id)) ||
            !ValidIvar(cls, length, @encode(NSUInteger), sizeof(NSUInteger))) return false;
        transferHeapBufferIvar = buffer;
        nativeHeapIvar = heap;
        lengthIvar = length;
        // The macOS 27 task calls getBuffer while registering every heap's
        // GPU address. Its legacy subclass omits this method, although init
        // already creates a whole-heap private buffer for paging. Add only the
        // missing subclass accessor; the base abstract method stays intact.
        bool added = class_addMethod(cls, selector, (IMP)LegacyHeapBuffer,
            method_getTypeEncoding(abstract));
        if (added)
            fprintf(stderr, "[ModernGPUTask] installed native legacy heap buffer accessor\n");
        return added;
    }
}
