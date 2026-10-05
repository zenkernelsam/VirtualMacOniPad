// Mac-side helper for Apple VM identity (VZMacMachineIdentifier) on Apple
// silicon. Mirrors how the iPad app derives its identity, but runs against the
// local Virtualization.framework so identities can be generated / inspected
// offline (e.g. to pre-seed a VM bundle's `MachineIdentifier`).
//
//   vzidentity new
//       Generate a fresh identity and print its dataRepresentation (hex and
//       base64) plus the derived serial number when the private getter exists.
//
//   vzidentity dump <MachineIdentifier>
//       Load an existing identity blob and print the same fields (read-only).
//
//   vzidentity write <out.mid>
//       Generate a fresh identity and write its dataRepresentation to out.mid.
//
// Build:
//   clang -fobjc-arc -framework Foundation -framework Virtualization \
//       vzidentity.m -o /tmp/vzidentity
//
// The identity that Apple's servers accept for iCloud is derived from the
// *host* Secure Enclave and requires host+guest macOS 15 or later, so an
// offline-generated identity is a format probe only, not an Apple-accepted
// one. See docs/ARM-APPLE-IDENTITY.md.
#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <objc/message.h>

static NSString *HexString(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *string =
        [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++)
        [string appendFormat:@"%02x", bytes[i]];
    return string;
}

// Best-effort read of the private serial number carried by an identifier.
static NSString *SerialForIdentifier(VZMacMachineIdentifier *identifier) {
    if (!identifier)
        return nil;
    @try {
        SEL serialSel = sel_registerName("_serialNumber");
        if ([identifier respondsToSelector:serialSel]) {
            id serialObject =
                ((id(*)(id, SEL))objc_msgSend)(identifier, serialSel);
            if (serialObject) {
                SEL stringSel = sel_registerName("string");
                id value = [serialObject respondsToSelector:stringSel]
                    ? ((id(*)(id, SEL))objc_msgSend)(serialObject, stringSel)
                    : serialObject;
                if ([value isKindOfClass:NSString.class])
                    return value;
                if ([value isKindOfClass:NSData.class])
                    return [(NSData *)value
                        base64EncodedStringWithOptions:0];
            }
        }
        id value = [identifier valueForKey:@"serialNumber"];
        if ([value isKindOfClass:NSString.class])
            return value;
    } @catch (NSException *exception) {
        (void)exception;
    }
    return nil;
}

static void Describe(NSString *label, VZMacMachineIdentifier *identifier) {
    NSData *representation = identifier.dataRepresentation;
    NSString *serial = SerialForIdentifier(identifier);
    printf("IDENTITY\t%s\tbytes=%lu\tserial=%s\n",
           label.UTF8String, (unsigned long)representation.length,
           serial.length ? serial.UTF8String : "(unavailable)");
    printf("HEX\t%s\n", HexString(representation).UTF8String);
    printf("BASE64\t%s\n",
           [representation base64EncodedStringWithOptions:0].UTF8String);
}

static void Fail(NSString *message) {
    fprintf(stderr, "error: %s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "usage: vzidentity new\n"
                "       vzidentity dump <MachineIdentifier>\n"
                "       vzidentity write <MachineIdentifier> <out.mid>\n");
            return 2;
        }
        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"new"]) {
            VZMacMachineIdentifier *identifier =
                [[VZMacMachineIdentifier alloc] init];
            if (!identifier)
                Fail(@"could not create a machine identifier");
            Describe(@"new", identifier);
            return 0;
        }
        if ([command isEqualToString:@"dump"]) {
            if (argc != 3)
                Fail(@"dump needs a MachineIdentifier path");
            NSData *data = [NSData dataWithContentsOfFile:@(argv[2])];
            if (!data.length)
                Fail(@"could not read the supplied file");
            VZMacMachineIdentifier *identifier =
                [[VZMacMachineIdentifier alloc]
                    initWithDataRepresentation:data];
            if (!identifier)
                Fail(@"the file is not a VZMachineIdentifier representation");
            Describe(@"file", identifier);
            return 0;
        }
        if ([command isEqualToString:@"write"]) {
            if (argc != 3)
                Fail(@"write needs an <out.mid> path");
            VZMacMachineIdentifier *fresh =
                [[VZMacMachineIdentifier alloc] init];
            if (!fresh)
                Fail(@"could not create a machine identifier");
            NSError *error = nil;
            if (![fresh.dataRepresentation writeToFile:@(argv[2])
                    options:NSDataWritingAtomic error:&error])
                Fail(error.localizedDescription);
            Describe(@"written", fresh);
            return 0;
        }
        Fail([NSString stringWithFormat:@"unknown command: %@", command]);
    }
    return 1;
}
