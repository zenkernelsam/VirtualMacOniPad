#import "modern_pvg_texture_preflight.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <mach/mach_vm.h>
#else
extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
#endif
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

typedef NSUInteger (*NativeFormatGetter)(id, SEL, NSUInteger);
typedef NSUInteger (*NativeRegistryGetter)(id, SEL);
typedef id (*NativeNameGetter)(id, SEL);

typedef struct {
    bool GPUReadbackVerified;
    const char *evidenceManifestSHA256;
    const char *evidenceResultsSHA256;
    const char *nativeProbeSHA256;
    const char *nativeProbeCDHash;
    const char *additionalEvidenceManifestSHA256;
    const char *additionalEvidenceResultsSHA256;
    const char *additionalNativeProbeSHA256;
    const char *additionalNativeProbeCDHash;
    NSUInteger formats[7];
    unsigned formatCount;
    NSUInteger publicAlignment;
    NSUInteger privateAlignment;
} VerifiedNativePolicy;

#include "texture_preflight_verified_native_policy.h"

typedef struct {
    Class deviceClass;
    id device; // One retained, genuine device; no association or retain cycle.
    NSUInteger registryID;
    NativeFormatGetter originalPublic;
    NativeFormatGetter originalPrivate;
    uintptr_t mainBase;
    bool usable;
} NativeBinding;

static NativeBinding nativeBinding;
static pthread_mutex_t installLock = PTHREAD_MUTEX_INITIALIZER;
static bool bindingPublished;
static unsigned diagnosticCount;

static const char mainVarPath[] = "/var/root/VirtualMac2/payload/Frameworks/ParavirtualizedGraphics.framework/Versions/A/XPCServices/com.apple.gpusw.ParavirtualizedGraphicsGPUTask.xpc/Contents/MacOS/com.apple.gpusw.ParavirtualizedGraphicsGPUTask";
static const char mainPrivatePath[] = "/private/var/root/VirtualMac2/payload/Frameworks/ParavirtualizedGraphics.framework/Versions/A/XPCServices/com.apple.gpusw.ParavirtualizedGraphicsGPUTask.xpc/Contents/MacOS/com.apple.gpusw.ParavirtualizedGraphicsGPUTask";
static const char nativeMetalPath[] = "/System/Library/Frameworks/Metal.framework/Metal";

// Exact unchanged native GPUTask source: SHA96ddbd5bbac1433690a5381de7b7f397
// 9301db316ad4c9c18122459417c2238a, UUID C29E9119-93F1-3C18-A925-7293D5168597.
// Raw arm64 call is0x5743c;0x57440 is its return PC, not a second BL site.
static const unsigned char expectedUUID[16] = {
    0xc2,0x9e,0x91,0x19,0x93,0xf1,0x3c,0x18,
    0xa9,0x25,0x72,0x93,0xd5,0x16,0x85,0x97,
};
static const unsigned char expectedCallAndOffsetCheck[] = {
    0xe0,0x03,0x18,0xaa, 0xe2,0x03,0x1a,0xaa, 0x61,0x54,0x00,0x94,
    0x40,0x0c,0x00,0xb4, 0x08,0x04,0x00,0xd1, 0x1f,0x01,0x14,0xea,
    0xc0,0x05,0x00,0x54,
};
static const unsigned char expectedSelectorStub[] = {
    0x61,0x01,0x00,0x90, 0x21,0x50,0x41,0xf9,
    0x31,0x01,0x00,0xb0, 0x31,0x02,0x2f,0x91,
    0x30,0x02,0x40,0xf9, 0x11,0x0a,0x1f,0xd7,
    0x20,0x00,0x20,0xd4, 0x20,0x00,0x20,0xd4,
};

static bool SafeRead(uintptr_t address, void *destination, size_t length) {
    if (!address || !destination || !length || address > UINTPTR_MAX-length)
        return false;
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, length,
        (mach_vm_address_t)destination, &copied) == KERN_SUCCESS &&
        copied == length;
}

static bool SafeString(const char *value, char *destination, size_t capacity) {
    if (!value || !destination || capacity < 2 || capacity > PATH_MAX ||
        !vm_page_size || vm_page_size > (1U << 20))
        return false;
    uintptr_t start = (uintptr_t)value;
    size_t copied = 0;
    while (copied < capacity) {
        uintptr_t address = start+copied;
        if (address < start) return false;
        size_t pageRemaining = (size_t)vm_page_size-address%vm_page_size;
        size_t chunk = capacity-copied;
        if (chunk > pageRemaining) chunk = pageRemaining;
        if (chunk > 128) chunk = 128;
        if (!SafeRead(address, destination+copied, chunk)) return false;
        for (size_t n = 0; n < chunk; ++n)
            if (!destination[copied+n]) return true;
        copied += chunk;
    }
    return false;
}

static bool FullMethodABI(Method method, const char *result,
                          const char *const *arguments, unsigned count) {
    if (!method || method_getNumberOfArguments(method) != count ||
        !method_getImplementation(method)) return false;
    char *value = method_copyReturnType(method);
    bool okay = value && !strcmp(value, result);
    free(value);
    for (unsigned n = 0; okay && n < count; ++n) {
        value = method_copyArgumentType(method, n);
        okay = value && !strcmp(value, arguments[n]);
        free(value);
    }
    return okay;
}

static bool FormatABI(Method method) {
    const char *arguments[] = {"@", ":", @encode(NSUInteger)};
    return FullMethodABI(method, @encode(NSUInteger), arguments, 3) &&
        !strcmp(method_getTypeEncoding(method), "Q24@0:8Q16");
}

static bool NativeMethodImage(IMP implementation) {
    Dl_info image = {0};
    char path[PATH_MAX];
    void *address = (void *)implementation;
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    return implementation && dladdr(address, &image) &&
        image.dli_fbase && SafeString(image.dli_fname, path, sizeof(path)) &&
        !strcmp(path, nativeMetalPath);
}

static bool Contains(uint64_t start, uint64_t length,
                      uint64_t address, uint64_t size) {
    return size && length && address >= start && address-start <= length &&
        size <= length-(address-start);
}

static bool VerifyMainGeometryAndBytes(uintptr_t base) {
    struct mach_header_64 header;
    if (!SafeRead(base, &header, sizeof(header)) || header.magic != MH_MAGIC_64 ||
        header.cputype != CPU_TYPE_ARM64 || header.filetype != MH_EXECUTE ||
        !header.ncmds || header.ncmds > 128 || !header.sizeofcmds ||
        header.sizeofcmds > 32768 || base > UINTPTR_MAX-sizeof(header)-header.sizeofcmds)
        return false;
    unsigned char *commands = malloc(header.sizeofcmds);
    if (!commands) return false;
    bool okay = SafeRead(base+sizeof(header), commands, header.sizeofcmds);
    bool uuidFound = false, textFound = false, codeFound = false, stubFound = false;
    size_t offset = 0;
    for (unsigned n = 0; okay && n < header.ncmds; ++n) {
        if (offset > header.sizeofcmds ||
            sizeof(struct load_command) > header.sizeofcmds-offset) {
            okay = false; break;
        }
        struct load_command command;
        memcpy(&command, commands+offset, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize%8 ||
            command.cmdsize > header.sizeofcmds-offset) {
            okay = false; break;
        }
        if (command.cmd == LC_UUID) {
            struct uuid_command uuid;
            if (uuidFound || command.cmdsize != sizeof(uuid)) {
                okay = false; break;
            }
            memcpy(&uuid, commands+offset, sizeof(uuid));
            uuidFound = !memcmp(uuid.uuid, expectedUUID, sizeof(expectedUUID));
            if (!uuidFound) { okay = false; break; }
        } else if (command.cmd == LC_SEGMENT_64) {
            struct segment_command_64 segment;
            if (command.cmdsize < sizeof(segment)) { okay = false; break; }
            memcpy(&segment, commands+offset, sizeof(segment));
            if (segment.nsects > 128 || sizeof(segment)+
                segment.nsects*sizeof(struct section_64) != command.cmdsize) {
                okay = false; break;
            }
            if (!memcmp(segment.segname, "__TEXT\0\0\0\0\0\0\0\0\0\0", 16)) {
                if (textFound || segment.vmaddr != 0x100000000ULL ||
                    segment.fileoff || segment.vmsize != 0x90000 ||
                    segment.filesize != 0x90000 ||
                    !(segment.initprot & VM_PROT_READ) ||
                    !(segment.initprot & VM_PROT_EXECUTE) ||
                    (segment.initprot & VM_PROT_WRITE)) {
                    okay = false; break;
                }
                textFound = true;
                for (unsigned k = 0; k < segment.nsects; ++k) {
                    struct section_64 section;
                    memcpy(&section, commands+offset+sizeof(segment)+
                        k*sizeof(section), sizeof(section));
                    if (memcmp(section.segname, segment.segname, 16)) {
                        okay = false; break;
                    }
                    if (!memcmp(section.sectname, "__text\0\0\0\0\0\0\0\0\0\0", 16)) {
                        if (codeFound || !Contains(segment.vmaddr, segment.vmsize,
                            section.addr, section.size) || !Contains(section.addr, section.size,
                            0x100057434ULL, sizeof(expectedCallAndOffsetCheck))) {
                            okay = false; break;
                        }
                        codeFound = true;
                    } else if (!memcmp(section.sectname, "__objc_stubs\0\0\0\0", 16)) {
                        if (stubFound || !Contains(segment.vmaddr, segment.vmsize,
                            section.addr, section.size) || !Contains(section.addr, section.size,
                            0x10006c5c0ULL, sizeof(expectedSelectorStub))) {
                            okay = false; break;
                        }
                        stubFound = true;
                    }
                }
            }
        }
        offset += command.cmdsize;
    }
    okay = okay && offset == header.sizeofcmds && uuidFound && textFound &&
        codeFound && stubFound;
    free(commands);
    unsigned char actualCall[sizeof(expectedCallAndOffsetCheck)];
    unsigned char actualStub[sizeof(expectedSelectorStub)];
    return okay && base <= UINTPTR_MAX-0x90000 &&
        SafeRead(base+0x57434, actualCall, sizeof(actualCall)) &&
        !memcmp(actualCall, expectedCallAndOffsetCheck, sizeof(actualCall)) &&
        SafeRead(base+0x6c5c0, actualStub, sizeof(actualStub)) &&
        !memcmp(actualStub, expectedSelectorStub, sizeof(actualStub));
}

static bool ActualServer27(uintptr_t *base) {
    const char *version = getenv("VZ_PVG_BACKEND_VERSION");
    const char *role = getenv("VZ_PVG_TASK_ROLE");
    if (!version || strcmp(version, "27") || !role || strcmp(role, "server") ||
        getuid() != 501 || geteuid() != 501 || sizeof(NSUInteger) != 8)
        return false;
    void *header = dlsym(RTLD_MAIN_ONLY, "_mh_execute_header");
    Dl_info info = {0};
    char path[PATH_MAX];
    if (!header || !dladdr(header, &info) || info.dli_fbase != header ||
        !SafeString(info.dli_fname, path, sizeof(path)) ||
        (strcmp(path, mainVarPath) && strcmp(path, mainPrivatePath))) return false;
    struct stat var = {0}, private = {0};
    if (stat(mainVarPath, &var) || stat(mainPrivatePath, &private) ||
        !S_ISREG(var.st_mode) || !S_ISREG(private.st_mode) ||
        var.st_dev != private.st_dev || var.st_ino != private.st_ino ||
        !VerifyMainGeometryAndBytes((uintptr_t)header)) return false;
    *base = (uintptr_t)header;
    return true;
}

static bool SafeDiagnosticFormat(NSUInteger format) {
    // Known ordinary uncompressed color formats only. Unknown and depth/stencil
    // formats are not passed to the native private query (which may assert).
    return format == 1 || format == 10 || format == 30 || format == 70 ||
           format == 80 || format == 90 || format == 115;
}

static bool CanonicalHash(const char *hash, size_t length) {
    if (!hash || strnlen(hash, length+1) != length) return false;
    for (size_t n = 0; n < length; ++n)
        if (!((hash[n] >= '0' && hash[n] <= '9') ||
              (hash[n] >= 'a' && hash[n] <= 'f'))) return false;
    return true;
}

static bool PolicyAllows(const VerifiedNativePolicy *policy, NSUInteger format) {
    if (!policy || !policy->GPUReadbackVerified ||
        policy->publicAlignment != 64 || policy->privateAlignment != 16 ||
        !policy->formatCount || policy->formatCount > 7 ||
        !CanonicalHash(policy->evidenceManifestSHA256, 64) ||
        !CanonicalHash(policy->evidenceResultsSHA256, 64) ||
        !CanonicalHash(policy->nativeProbeSHA256, 64) ||
        !CanonicalHash(policy->nativeProbeCDHash, 40)) return false;
    bool found = false;
    for (unsigned n = 0; n < policy->formatCount; ++n) {
        if (!SafeDiagnosticFormat(policy->formats[n])) return false;
        if ((policy->formats[n] == 1 || policy->formats[n] == 90 || policy->formats[n] == 115) &&
            (!CanonicalHash(policy->additionalEvidenceManifestSHA256, 64) ||
             !CanonicalHash(policy->additionalEvidenceResultsSHA256, 64) ||
             !CanonicalHash(policy->additionalNativeProbeSHA256, 64) ||
             !CanonicalHash(policy->additionalNativeProbeCDHash, 40))) return false;
        for (unsigned k = 0; k < n; ++k)
            if (policy->formats[k] == policy->formats[n]) return false;
        found |= policy->formats[n] == format;
    }
    return found;
}

static bool ClaimDiagnostic(void) {
    unsigned value = __atomic_load_n(&diagnosticCount, __ATOMIC_RELAXED);
    while (value < 32)
        if (__atomic_compare_exchange_n(&diagnosticCount, &value, value+1,
            false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return true;
    return false;
}

static NSUInteger SelectAlignment(id device, SEL selector, NSUInteger format,
                uintptr_t caller, const VerifiedNativePolicy *policy) {
    // Immutable original IMP published before any method is installed.
    NSUInteger publicValue = nativeBinding.originalPublic(device, selector, format);
    int savedErrno = errno;
    bool exactCallsite = caller == nativeBinding.mainBase+0x57440;
    bool exactSelector = selector ==
        sel_registerName("minimumLinearTextureAlignmentForPixelFormat:");
    bool exactDevice = __atomic_load_n(&nativeBinding.usable, __ATOMIC_ACQUIRE) &&
                       device == nativeBinding.device &&
                       object_getClass(device) == nativeBinding.deviceClass;
    bool nativeKnown = false, replaced = false;
    NSUInteger privateValue = 0, returned = publicValue;
    if (exactCallsite && exactSelector && exactDevice && SafeDiagnosticFormat(format)) {
        @try {
            privateValue = nativeBinding.originalPrivate(device,
                sel_registerName("minLinearTextureAlignmentForPixelFormat:"), format);
            nativeKnown = true;
        } @catch (NSException *exception) {
            (void)exception;
            nativeKnown = false; // Original public result/path remains in effect.
        }
        if (nativeKnown && publicValue == 64 && privateValue == 16 &&
            PolicyAllows(policy, format)) {
            returned = privateValue;
            replaced = true;
        }
    }
    if (exactCallsite && ClaimDiagnostic())
        fprintf(stderr, "[ModernTexturePreflight] diagnosticOnly=%d exactCallsite=1 sameSelector=%d sameDevice=%d format=%llu nativePublic=%llu nativePrivateKnown=%d nativePrivate=%llu returned=%llu replacement=%d originalSingleForward=1\n",
            !(policy && policy->GPUReadbackVerified), exactSelector, exactDevice,
            (unsigned long long)format, (unsigned long long)publicValue,
            nativeKnown, (unsigned long long)privateValue,
            (unsigned long long)returned, replaced);
    errno = savedErrno;
    return returned;
}

static __attribute__((noinline)) NSUInteger ScopedNativeLinearMinimum(
                                      id device, SEL selector, NSUInteger format) {
    // Capture HERE, before calling a helper. The native selector stub uses BRAA
    // and preserves LR from BL@0x5743c, whose exact return PC is0x57440.
    void *caller = __builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    caller = ptrauth_strip(caller, ptrauth_key_return_address);
#endif
    return SelectAlignment(device, selector, format, (uintptr_t)caller,
                           &compiledNativePolicy);
}

static Method LocalMethod(Class cls, SEL selector) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned n = 0; n < count; ++n)
        if (method_getName(methods[n]) == selector) { result = methods[n]; break; }
    free(methods);
    return result;
}

static bool InstallOnActualClass(Class cls, SEL selector,
                                 IMP original, const char *encoding) {
    IMP replacement = (IMP)ScopedNativeLinearMinimum;
    if (class_addMethod(cls, selector, replacement, encoding)) return true;
    Method method = LocalMethod(cls, selector);
    if (!method || method_getImplementation(method) != original) return false;
    IMP removed = method_setImplementation(method, replacement);
    if (removed == original) return true;
    if (method_getImplementation(method) == replacement)
        method_setImplementation(method, removed);
    return false;
}

bool VZModernInstallTexturePreflightCallsiteBridge(id device) {
    int entryErrno = errno;
    bool installed = false;
    uintptr_t mainBase = 0;
    Class cls = device ? object_getClass(device) : Nil;
    if (!cls || strcmp(class_getName(cls), "AGXG14GDevice") ||
        !ActualServer27(&mainBase)) { errno = entryErrno; return false; }
    SEL publicSelector = sel_registerName("minimumLinearTextureAlignmentForPixelFormat:");
    SEL privateSelector = sel_registerName("minLinearTextureAlignmentForPixelFormat:");
    Method publicMethod = class_getInstanceMethod(cls, publicSelector);
    Method privateMethod = class_getInstanceMethod(cls, privateSelector);
    Method nameMethod = class_getInstanceMethod(cls, sel_registerName("name"));
    Method registryMethod = class_getInstanceMethod(cls, sel_registerName("registryID"));
    const char *objectArgs[] = {"@", ":"};
    if (!FormatABI(publicMethod) || !FormatABI(privateMethod) ||
        !FullMethodABI(nameMethod, "@", objectArgs, 2) ||
        !FullMethodABI(registryMethod, @encode(NSUInteger), objectArgs, 2)) {
        errno = entryErrno; return false;
    }
    id heldDevice = nil;
    @try {
        NSString *name = ((NativeNameGetter)method_getImplementation(nameMethod))(
            device, sel_registerName("name"));
        NSUInteger registry = ((NativeRegistryGetter)method_getImplementation(registryMethod))(
            device, sel_registerName("registryID"));
        if (![name isKindOfClass:NSString.class] || ![name isEqualToString:@"Apple M2 GPU"] || !registry) {
            errno = entryErrno; return false;
        }
        // Retain before entering the C lock. No Objective-C native call or
        // retain/release runs while it is held; finally always releases it.
        heldDevice = [device retain];
        pthread_mutex_lock(&installLock);
        @try {
            if (__atomic_load_n(&bindingPublished, __ATOMIC_ACQUIRE)) {
                installed = __atomic_load_n(&nativeBinding.usable, __ATOMIC_ACQUIRE) &&
                    nativeBinding.deviceClass == cls && nativeBinding.device == device &&
                    nativeBinding.registryID == registry && nativeBinding.mainBase == mainBase &&
                    method_getImplementation(class_getInstanceMethod(cls, publicSelector)) ==
                        (IMP)ScopedNativeLinearMinimum;
            } else if (NativeMethodImage(method_getImplementation(publicMethod)) &&
                       NativeMethodImage(method_getImplementation(privateMethod))) {
                nativeBinding.deviceClass = cls;
                nativeBinding.device = heldDevice;
                heldDevice = nil;
                nativeBinding.registryID = registry;
                nativeBinding.originalPublic = (NativeFormatGetter)method_getImplementation(publicMethod);
                nativeBinding.originalPrivate = (NativeFormatGetter)method_getImplementation(privateMethod);
                nativeBinding.mainBase = mainBase;
                __atomic_store_n(&nativeBinding.usable, false, __ATOMIC_RELEASE);
                __atomic_store_n(&bindingPublished, true, __ATOMIC_RELEASE);
                installed = InstallOnActualClass(cls, publicSelector,
                    (IMP)nativeBinding.originalPublic, method_getTypeEncoding(publicMethod));
                __atomic_store_n(&nativeBinding.usable, installed, __ATOMIC_RELEASE);
                // Keep the single immutable binding/device even on an install
                // race failure. A temporarily visible wrapper must never see
                // a released device or mutable original-IMP record.
            }
        } @finally {
            pthread_mutex_unlock(&installLock);
        }
    } @catch (NSException *exception) {
        (void)exception;
        installed = false;
    } @finally {
        [heldDevice release];
    }
    errno = entryErrno;
    return installed;
}
