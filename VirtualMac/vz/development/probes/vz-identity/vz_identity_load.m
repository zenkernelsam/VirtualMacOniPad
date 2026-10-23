// vz_identity_load — read back a MachineIdentifier blob and report its
// serial/ECID through the ivars (-_serialNumber/-_ECID getters are not
// reliable on this payload).
//
//   vz_identity_load <compat-dir> <blob>

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <compat-dir> <blob>\n", argv[0]);
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
        Class clazz = objc_getClass("VZMacMachineIdentifier");
        if (!clazz) return 4;
        NSData *blob = [NSData dataWithContentsOfFile:@(argv[2])];
        id ident = ((id (*)(id, SEL, id))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)clazz, sel_registerName("alloc")),
            sel_registerName("initWithDataRepresentation:"), blob);
        if (!ident) {
            fprintf(stderr, "blob rejected\n");
            return 5;
        }
        Ivar ivSerial = class_getInstanceVariable(clazz, "_serialNumber");
        Ivar ivEcid = class_getInstanceVariable(clazz, "_ECID");
        id sn = (__bridge id)(*(void **)((char *)(__bridge void *)ident
                                         + ivar_getOffset(ivSerial)));
        unsigned long long ecid = *(unsigned long long *)((char *)(__bridge void *)ident
                                         + ivar_getOffset(ivEcid));
        id str = sn ? ((id (*)(id, SEL))objc_msgSend)(sn, sel_registerName("string")) : nil;
        printf("serial=%s class=%s ecid=0x%016llx\n",
               str ? [[str description] UTF8String] : "-",
               sn ? object_getClassName(sn) : "-", ecid);
    }
    return 0;
}
