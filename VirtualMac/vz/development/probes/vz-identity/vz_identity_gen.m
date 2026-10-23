// vz_identity_gen — build a VZMacMachineIdentifier blob carrying a chosen
// serial number, using the private API the payload already ships.
//
// Run on the iPad against the extracted, VZ-compatible framework copies:
//   vz_identity_gen <compat-dir> <serial> <out-blob>
//
// The VZ payload stores the serial as an NSString in the identifier's
// _serialNumber ivar, but -dataRepresentation sends -string to it and
// aborts with -[__NSCFString string]. Replacing that ivar with a real
// _VZMacSerialNumber (initWithString:) makes serialization work and
// produces a bplist {ECID, SerialNumber}. The blob is accepted by
// -initWithDataRepresentation: and flows through
// VZMacPlatformConfiguration into the guest device tree.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id msg_id(id obj, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}
static id msg_id_id(id obj, const char *sel, id arg) {
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel_registerName(sel), arg);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: %s <compat-dir> <serial> <out-blob>\n", argv[0]);
            return 2;
        }
        NSString *compat = @(argv[1]);
        NSString *serial = @(argv[2]);
        NSString *out = @(argv[3]);

        const char *deps[] = {"Hypervisor", "ParavirtualizedGraphics", "Virtualization"};
        for (int i = 0; i < 3; i++) {
            NSString *p = [compat stringByAppendingPathComponent:@(deps[i])];
            if (!dlopen(p.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stderr, "dlopen %s failed: %s\n", deps[i], dlerror());
                return 3;
            }
        }

        Class ident = objc_getClass("VZMacMachineIdentifier");
        Class snCls = objc_getClass("_VZMacSerialNumber");
        if (!ident || !snCls) {
            fprintf(stderr, "identifier classes unavailable\n");
            return 4;
        }
        id identifier = msg_id_id((id)ident, "_machineIdentifierWithSerialNumber:", serial);
        if (!identifier) {
            fprintf(stderr, "constructor returned nil\n");
            return 5;
        }

        Ivar iv = class_getInstanceVariable(ident, "_serialNumber");
        id real = msg_id_id(msg_id((id)snCls, "alloc"), "initWithString:", serial);
        object_setIvar(identifier, iv, real);
        if (!real) {
            fprintf(stderr, "_VZMacSerialNumber allocation failed\n");
            return 6;
        }

        NSData *blob = nil;
        @try {
            blob = msg_id(identifier, "dataRepresentation");
        } @catch (NSException *e) {
            fprintf(stderr, "dataRepresentation threw: %s\n", e.reason.UTF8String);
            return 7;
        }
        if (!blob.length) {
            fprintf(stderr, "empty dataRepresentation\n");
            return 8;
        }
        if (![blob writeToFile:out atomically:YES]) {
            fprintf(stderr, "cannot write %s\n", argv[3]);
            return 9;
        }
        printf("wrote %s (%lu bytes) serial=%s\n", argv[3],
               (unsigned long)blob.length, serial.UTF8String);
    }
    return 0;
}
