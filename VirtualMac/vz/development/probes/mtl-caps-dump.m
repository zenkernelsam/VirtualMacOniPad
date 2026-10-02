// mtl-caps-dump.m — dump every capability the guest-visible MTLDevice reports.
//
// This runs inside the VM: the returned device is Apple's ParavirtGPU device,
// so the printed table IS what the negotiated host/guest feature set exposes
// to Metal clients (MATLAB, Chromium/ANGLE, GLD, etc).
//
// Build (guest macOS):
//   clang -fobjc-arc -framework Foundation -framework Metal -framework IOKit \
//         -o mtl-caps-dump mtl-caps-dump.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static void dumpProperties(id dev) {
    NSObject *o = dev;
    unsigned int count = 0;
    objc_property_t *props = protocol_copyPropertyList(@protocol(MTLDevice), &count);
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = @(property_getName(props[i]));
        SEL sel = NSSelectorFromString(name);
        if (![o respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [o methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2) continue;
        const char *ret = sig.methodReturnType;
        @try {
            if (ret[0] == 'B' || ret[0] == 'c') {
                BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
                BOOL v = fn(o, sel);
                [rows addObject:[NSString stringWithFormat:@"%-58s %s", name.UTF8String, v ? "YES" : "no"]];
            } else if (ret[0] == 'Q' || ret[0] == 'I' || ret[0] == 'q' || ret[0] == 'i' || ret[0] == 'L' || ret[0] == 'l' || ret[0] == 'S' || ret[0] == 's') {
                unsigned long long (*fn)(id, SEL) = (unsigned long long (*)(id, SEL))objc_msgSend;
                unsigned long long v = fn(o, sel);
                if ([name isEqualToString:@"argumentBuffersSupport"]) {
                    NSString *tier = v == MTLArgumentBuffersTier1 ? @"tier1" :
                        v == MTLArgumentBuffersTier2 ? @"tier2" : @"unknown";
                    [rows addObject:[NSString stringWithFormat:
                        @"%-58s %llu (%@)", name.UTF8String, v, tier]];
                } else {
                    [rows addObject:[NSString stringWithFormat:
                        @"%-58s %llu", name.UTF8String, v]];
                }
            } else if (ret[0] == '@') {
                id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id v = fn(o, sel);
                [rows addObject:[NSString stringWithFormat:@"%-58s %@", name.UTF8String, v ?: @"(null)"]];
            }
        } @catch (NSException *e) {
            [rows addObject:[NSString stringWithFormat:@"%-58s <exn %@>", name.UTF8String, e.name]];
        }
    }
    free(props);
    for (NSString *r in [rows sortedArrayUsingSelector:@selector(compare:)]) printf("%s\n", r.UTF8String);
}

int main(void) {
    @autoreleasepool {
        // MTLCopyAllDevices is macOS-only; resolve weakly so the same source
        // builds for iOS (where it does not exist).
        NSArray *(*copyAll)(void) = dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
        NSArray *all = copyAll ? copyAll() : @[];
        printf("== MTLCopyAllDevices: %lu device(s)%s\n", (unsigned long)all.count,
               copyAll ? "" : " (API absent — iOS)");
        id dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("NO default device\n"); return 1; }
        printf("== default device: %s\n", [[dev name] UTF8String]);
        printf("== registryID=0x%llx\n", (unsigned long long)[dev registryID]);

        for (id d in all)
            printf("[device] %s\n", [[d name] UTF8String]);

        for (id d in all.count ? all : @[dev]) {
            printf("\n######## device: %s ########\n", [[d name] UTF8String]);
            dumpProperties(d);
            printf("\n-- families --\n");
            for (long f = 1; f <= 5001; f++) {
                @try {
                    NSMethodSignature *sig = [d methodSignatureForSelector:@selector(supportsFamily:)];
                    if (!sig) break;
                    BOOL (*fn)(id, SEL, long) = (BOOL (*)(id, SEL, long))objc_msgSend;
                    if (fn(d, @selector(supportsFamily:), f)) printf("family %ld: YES\n", f);
                } @catch (NSException *e) { break; }
            }
        }
    }
    return 0;
}
