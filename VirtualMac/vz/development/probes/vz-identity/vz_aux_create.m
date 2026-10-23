// vz_aux_create — create a fresh VZMacAuxiliaryStorage for a clone from an
// existing HardwareModel blob, without touching the source VM's storage.
//
//   vz_aux_create <compat-dir> <HardwareModel> <out-path>
//
// A freshly created auxiliary storage has no identity-bound NVRAM, which is
// what lets a clone take a new MachineIdentifier (see README).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: %s <compat-dir> <HardwareModel> <out-path>\n", argv[0]);
            return 2;
        }
        NSString *compat = @(argv[1]);
        const char *deps[] = {"Hypervisor", "ParavirtualizedGraphics", "Virtualization"};
        for (int i = 0; i < 3; i++) {
            NSString *p = [compat stringByAppendingPathComponent:@(deps[i])];
            if (!dlopen(p.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stderr, "dlopen %s failed: %s\n", deps[i], dlerror());
                return 3;
            }
        }
        NSData *hwData = [NSData dataWithContentsOfFile:@(argv[2])];
        Class hwCls = objc_getClass("VZMacHardwareModel");
        Class auxCls = objc_getClass("VZMacAuxiliaryStorage");
        if (!hwData || !hwCls || !auxCls) return 4;
        id hw = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)hwCls, sel_registerName("alloc")),
            sel_registerName("initWithDataRepresentation:"), hwData);
        if (!hw) {
            fprintf(stderr, "hardware model rejected\n");
            return 5;
        }
        NSError *error = nil;
        id storage = ((id (*)(id, SEL, id, id, unsigned long long, NSError **))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)auxCls, sel_registerName("alloc")),
            sel_registerName("initCreatingStorageAtURL:hardwareModel:options:error:"),
            [NSURL fileURLWithPath:@(argv[3])], hw, 0ULL, &error);
        (void)storage;
        printf("storage=%p error=%s\n", storage,
               error ? [[error description] UTF8String] : "nil");
        return storage ? 0 : 6;
    }
}
