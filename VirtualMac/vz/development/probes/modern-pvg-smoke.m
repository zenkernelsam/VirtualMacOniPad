#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../host/modern_pvg_memory.h"

typedef struct { uint64_t address, length; void *pointer; } PhysicalRange;

// A separate process with synthetic shared RAM; never opens a VM disk.
// --device additionally creates a Metal device and PVG device, but submits no
// command buffers. Metadata-only loading remains available without that flag.
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        BOOL create = NO, surface = NO;
        for (int i = 1; i < argc; ++i) {
            if (!strcmp(argv[i], "--device")) { create = YES; continue; }
            if (!strcmp(argv[i], "--surface")) { surface = YES; continue; }
            if (!dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stderr, "FAIL dlopen %s: %s\n", argv[i], dlerror()); return 2;
            }
            printf("LOADED %s\n", argv[i]);
        }
        Class mapClass = objc_getClass("PGMemoryMapDescriptor");
        Class memoryClass = objc_getClass("PGMemoryMap");
        Class descriptorClass = objc_getClass("PGDeviceDescriptor");
        if (!mapClass || !memoryClass || !descriptorClass) return 3;
        printf("CLASSES map=%s memory=%s device=%s\n", class_getImageName(mapClass),
            class_getImageName(memoryClass), class_getImageName(descriptorClass));
        vm_address_t address = 0;
        uint64_t length = 0x100000;
        kern_return_t kr = vm_allocate(mach_task_self(), &address, length, VM_FLAGS_ANYWHERE);
        if (kr) { printf("FAIL allocate=%d\n", kr); return 4; }
        memset((void *)address, 0x5a, length);
        id mapDescriptor = [mapClass new];
        PhysicalRange range = {0x70000000, length, (void *)address};
        ((void (*)(id, SEL, PhysicalRange))objc_msgSend)(mapDescriptor, sel_registerName("addRange:"), range);
        id map = ((id (*)(id, SEL, id))objc_msgSend)([memoryClass alloc],
            sel_registerName("initWithDescriptor:"), mapDescriptor);
        if (!map) { puts("FAIL memory map construction"); return 5; }
        uint8_t readback[16] = {0};
        BOOL read = ((BOOL (*)(id, SEL, uint64_t, uint64_t, void *))objc_msgSend)(map,
            sel_registerName("read:length:dst:"), range.address + 0x4000, sizeof(readback), readback);
        void *translated = ((void *(*)(id, SEL, uint64_t, uint64_t))objc_msgSend)(map,
            sel_registerName("virtualAddressForPhysical:length:"), range.address + 0x4000, sizeof(readback));
        if (!read || translated != (void *)(address + 0x4000) || readback[0] != 0x5a) {
            printf("FAIL translated=%p expected=%p read=%d data=%x\n", translated,
                (void *)(address + 0x4000), read, readback[0]); return 6;
        }
        puts("PASS physical-to-host translation and RAM read");
        if (surface) {
            setenv("VZ_PVG_BACKEND_VERSION", "27", 1);
            VZModernRecordGuestMapping((void *)address, range.address, range.length, 7);
            if (!VZModernInstallIOSurfaceDescriptorBridge()) return 9;
            Class surfaceDescriptorClass = objc_getClass("PGIOSurfaceHostDeviceDescriptor");
            Class surfaceClass = objc_getClass("PGIOSurfaceHostDevice");
            id surfaceDescriptor = [surfaceDescriptorClass new];
            [surfaceDescriptor setValue:@(0x1000) forKey:@"mmioLength"];
            void (^interrupt)(uint32_t) = ^(uint32_t value) { printf("surface interrupt=%u\n", value); };
            [surfaceDescriptor setValue:interrupt forKey:@"raiseInterrupt"];
            id oldMap = [^{ return; } copy];
            id oldUnmap = [^{ return; } copy];
            [surfaceDescriptor setValue:oldMap forKey:@"mapMemory"];
            [surfaceDescriptor setValue:oldUnmap forKey:@"unmapMemory"];
            if ([surfaceDescriptor valueForKey:@"mapMemory"] != oldMap ||
                [surfaceDescriptor valueForKey:@"unmapMemory"] != oldUnmap) return 10;
            id surfaceDevice = ((id (*)(id, SEL, id))objc_msgSend)([surfaceClass alloc],
                sel_registerName("initWithDescriptor:"), surfaceDescriptor);
            id surfaceMap = [surfaceDevice valueForKey:@"memoryMap"];
            memset(readback, 0, sizeof(readback));
            BOOL surfaceRead = ((BOOL (*)(id, SEL, uint64_t, uint64_t, void *))objc_msgSend)(surfaceMap,
                sel_registerName("read:length:dst:"), range.address + 0x4000, sizeof(readback), readback);
            if (!surfaceDevice || !surfaceRead || readback[0] != 0x5a) return 11;
            puts("PASS IOSurface legacy descriptor translated to real RAM map and read");
            [oldMap release];
            [oldUnmap release];
        }
        if (create) {
            setenv("VZ_PVG_BACKEND_VERSION", "27", 1);
            id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
            if (!metal) return 7;
            printf("METAL %s gpuAddressSelector=%d\n", metal.name.UTF8String,
                [metal respondsToSelector:sel_registerName("newBufferWithAddressRanges:count:length:options:")]);
            id descriptor = [descriptorClass new];
            [descriptor setValue:metal forKey:@"device"];
            [descriptor setValue:@(0x10000) forKey:@"mmioLength"];
            [descriptor setValue:@1 forKey:@"displayPortCount"];
            [descriptor setValue:@"/tmp/virtualmac2-pvg-cache" forKey:@"cachePath"];
            void (^interrupt)(uint32_t) = ^(uint32_t value) { printf("interrupt=%u\n", value); };
            [descriptor setValue:interrupt forKey:@"raiseInterrupt"];
            VZModernRecordGuestMapping((void *)address, range.address, range.length, 7);
            id (*legacyFactory)(id) = dlsym(RTLD_DEFAULT, "PGNewDeviceWithDescriptor");
            id legacy = legacyFactory ? legacyFactory(descriptor) : nil;
            printf("LEGACY factory=%p device=%p\n", legacyFactory, legacy);
            puts("BEGIN new native device initializer");
            id device = VZModernNewDeviceWithDescriptor(descriptor);
            if (!device) { puts("FAIL native device initializer returned nil"); return 8; }
            printf("PASS native device initialized class=%s\n", object_getClassName(device));
            // Exit promptly; device teardown belongs to the framework, and no
            // guest FIFO or GPU workload was started in this probe.
        }
    }
    return 0;
}
