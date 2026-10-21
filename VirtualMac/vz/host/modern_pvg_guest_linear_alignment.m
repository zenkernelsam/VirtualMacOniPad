#import "modern_pvg_guest_linear_alignment.h"
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <mach/mach_vm.h>
#else
// iOS exports this MIG entry point but its public mach_vm.h is unsupported.
extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
    mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
#endif
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

typedef NSUInteger (*AlignmentGetter)(id, SEL);
typedef NSUInteger (*FormatAlignmentGetter)(id, SEL, NSUInteger);
typedef void (*DeviceInfoGetter)(id, SEL, uint32_t, uint32_t, uint32_t);
typedef id (*MetalDeviceGetter)(id, SEL);

typedef struct {
    Class deviceClass;
    AlignmentGetter originalLinear;
    AlignmentGetter originalMinimum;
    FormatAlignmentGetter publicLinear;
    FormatAlignmentGetter publicTextureBuffer;
    bool usable;
} DeviceBinding;

typedef struct AlignmentScope {
    id device;
    const DeviceBinding *binding;
    NSUInteger publicRequirement;
    struct AlignmentScope *previous;
} AlignmentScope;

static pthread_mutex_t installationLock = PTHREAD_MUTEX_INITIALIZER;
static DeviceBinding m2Binding;
static bool bindingPublished;
static Class registeredPGDevice;
static DeviceInfoGetter originalDeviceInfo;
static MetalDeviceGetter originalMetalDevice;
static __thread AlignmentScope *currentScope;
static unsigned diagnosticCount;

// BEGIN V3 DIAGNOSTIC CONTEXT: this does not participate in alignment decisions.
typedef struct {
    unsigned sequence;
    uint32_t maxKey, capacity;
    bool active;
} InfoDiagnosticContext;
static __thread InfoDiagnosticContext currentInfoDiagnostic;
static unsigned infoObservationCount, getterObservationCount;

static unsigned ObservationSlot(unsigned *counter, unsigned limit) {
    unsigned before = __atomic_load_n(counter, __ATOMIC_RELAXED);
    while (before < limit) {
        if (__atomic_compare_exchange_n(counter, &before, before + 1, false,
                __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return before + 1;
    }
    return 0;
}

static void ObserveInfo(const char *phase, bool prepared, bool returned) {
    int savedErrno = errno;
    InfoDiagnosticContext context = currentInfoDiagnostic;
    if (context.active && context.sequence) {
        uint64_t threadID = 0;
        bool threadKnown = !pthread_threadid_np(NULL, &threadID);
        fprintf(stderr, "[ModernGuestLinearAlignment] info phase=%s sequence=%u maxKey=%u capacity=%u scopePrepared=%u originalReturned=%u threadKnown=%u threadID=%llu\n",
            phase, context.sequence, context.maxKey, context.capacity,
            prepared, returned, threadKnown, (unsigned long long)threadID);
    }
    errno = savedErrno;
}
// END V3 DIAGNOSTIC CONTEXT

// These nine uncompressed color formats were queried on the real M2 in the
// previous 99-case matrix. Depth/stencil and compressed formats are excluded:
// querying them as linear textures can trigger a native assertion. The public
// constraints are measured again on this actual device; no value is invented.
static const NSUInteger linearColorFormats[] = {
    MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm,
    MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB,
    MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB,
    MTLPixelFormatRGBA16Unorm, MTLPixelFormatRGBA16Float,
    MTLPixelFormatRGBA32Float,
};

static bool ABIType(Method method, unsigned argument, const char *expected) {
    char *type = argument == UINT_MAX ? method_copyReturnType(method) :
                                      method_copyArgumentType(method, argument);
    bool okay = type && !strcmp(type, expected);
    free(type);
    return okay;
}

static bool MethodABI(Method method, const char *result,
                      const char *const *arguments, unsigned count) {
    if (!method || method_getNumberOfArguments(method) != count ||
        !ABIType(method, UINT_MAX, result)) return false;
    for (unsigned n = 0; n < count; ++n)
        if (!ABIType(method, n, arguments[n])) return false;
    return method_getImplementation(method) != NULL;
}

static bool AlignmentABI(Method method, bool withFormat) {
    const char *args[] = {"@", ":", @encode(NSUInteger)};
    return MethodABI(method, @encode(NSUInteger), args, withFormat ? 3 : 2);
}

static bool AlignmentValid(NSUInteger value) {
    // Native power-of-two requirements can be conservatively combined by max.
    // 64 KiB bounds the CPU advertisement to a representable, usable constraint.
    return value && value <= 65536 && !(value & (value - 1));
}

static const DeviceBinding *BindingForDevice(id device) {
    if (!__atomic_load_n(&bindingPublished, __ATOMIC_ACQUIRE)) return NULL;
    Class cls = object_getClass(device);
    for (; cls; cls = class_getSuperclass(cls))
        if (cls == m2Binding.deviceClass) return &m2Binding;
    return NULL;
}


// BEGIN V3 GETTER OBSERVATION: only during the original getInfo invocation.
static void ObserveScopedGetter(id device, bool minimum,
                                const AlignmentScope *scope,
                                const DeviceBinding *binding,
                                NSUInteger nativeValue) {
    int savedErrno = errno;
    InfoDiagnosticContext context = currentInfoDiagnostic;
    if (context.active) {
        unsigned slot = ObservationSlot(&getterObservationCount, 32);
        if (slot) {
            bool sameDevice = scope && scope->device == device;
            bool scopeBinding = scope && scope->binding == binding;
            bool usedScope = sameDevice && scopeBinding && AlignmentValid(nativeValue);
            // Observe the unchanged return expression below; do not make a
            // second native query, alter the scope, or replace its return value.
            NSUInteger returned = usedScope && nativeValue < scope->publicRequirement ?
                                  scope->publicRequirement : nativeValue;
            uint64_t threadID = 0;
            bool threadKnown = !pthread_threadid_np(NULL, &threadID);
            fprintf(stderr, "[ModernGuestLinearAlignment] getter slot=%u infoSequence=%u selector=%s native=%llu returned=%llu sameDevice=%u scopeBinding=%u usedScope=%u maxKey=%u capacity=%u threadKnown=%u threadID=%llu\n",
                slot, context.sequence,
                minimum ? "deviceLinearTextureAlignmentBytes" : "linearTextureAlignmentBytes",
                (unsigned long long)nativeValue, (unsigned long long)returned,
                sameDevice, scopeBinding, usedScope, context.maxKey, context.capacity,
                threadKnown, (unsigned long long)threadID);
        }
    }
    errno = savedErrno;
}
// END V3 GETTER OBSERVATION

static NSUInteger ScopedAlignment(id device, SEL selector, bool minimum) {
    const DeviceBinding *binding = BindingForDevice(device);
    // Each wrapper is published only after its immutable original IMP record.
    // A missing record is an internal installation failure, never a fake zero.
    if (!binding) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
            reason:@"Missing native linear-alignment forwarding record"
            userInfo:nil];
    }
    AlignmentGetter original = minimum ? binding->originalMinimum :
                                         binding->originalLinear;
    NSUInteger nativeValue = original(device, selector);
    AlignmentScope *scope = currentScope;
    ObserveScopedGetter(device, minimum, scope, binding, nativeValue); // V3 log only
    if (!scope || scope->device != device || scope->binding != binding ||
        !AlignmentValid(nativeValue)) return nativeValue;
    return nativeValue > scope->publicRequirement ? nativeValue :
                                                    scope->publicRequirement;
}

static NSUInteger ScopedLinearAlignment(id device, SEL selector) {
    return ScopedAlignment(device, selector, false);
}

static NSUInteger ScopedMinimumAlignment(id device, SEL selector) {
    return ScopedAlignment(device, selector, true);
}

static Method LocalMethod(Class cls, SEL selector) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned n = 0; n < count; ++n) {
        if (method_getName(methods[n]) == selector) {
            result = methods[n];
            break;
        }
    }
    free(methods);
    return result;
}

static bool ReplaceOnActualClass(Class cls, SEL selector, IMP original,
                                IMP replacement, const char *encoding) {
    // class_addMethod shadows an inherited implementation on the M2 class.
    // It never modifies _MTLDevice or another system-wide/superclass method.
    if (class_addMethod(cls, selector, replacement, encoding)) return true;
    Method method = LocalMethod(cls, selector);
    if (!method || method_getImplementation(method) != original) return false;
    IMP removed = method_setImplementation(method, replacement);
    if (removed == original) return true;
    // Fail closed if another in-process hook changed this exact method.
    if (method_getImplementation(method) == replacement)
        method_setImplementation(method, removed);
    return false;
}

static void RestoreOwnedMethod(Class cls, SEL selector, IMP replacement,
                               IMP original) {
    Method method = LocalMethod(cls, selector);
    if (method && method_getImplementation(method) == replacement)
        method_setImplementation(method, original);
}

static const DeviceBinding *PrepareM2Binding(id device) {
    Class cls = object_getClass(device);
    if (!cls || strcmp(class_getName(cls), "AGXG14GDevice")) return NULL;
    pthread_mutex_lock(&installationLock);
    if (__atomic_load_n(&bindingPublished, __ATOMIC_ACQUIRE)) {
        const DeviceBinding *result = m2Binding.deviceClass == cls &&
                                      m2Binding.usable ? &m2Binding : NULL;
        pthread_mutex_unlock(&installationLock);
        return result;
    }
    SEL linear = sel_registerName("linearTextureAlignmentBytes");
    SEL minimum = sel_registerName("deviceLinearTextureAlignmentBytes");
    SEL publicLinear = sel_registerName("minimumLinearTextureAlignmentForPixelFormat:");
    SEL publicBuffer = sel_registerName("minimumTextureBufferAlignmentForPixelFormat:");
    Method methods[] = {
        class_getInstanceMethod(cls, linear),
        class_getInstanceMethod(cls, minimum),
        class_getInstanceMethod(cls, publicLinear),
        class_getInstanceMethod(cls, publicBuffer),
    };
    if (!AlignmentABI(methods[0], false) || !AlignmentABI(methods[1], false) ||
        !AlignmentABI(methods[2], true) || !AlignmentABI(methods[3], true)) {
        pthread_mutex_unlock(&installationLock);
        return NULL;
    }
    m2Binding.deviceClass = cls;
    m2Binding.originalLinear = (AlignmentGetter)method_getImplementation(methods[0]);
    m2Binding.originalMinimum = (AlignmentGetter)method_getImplementation(methods[1]);
    m2Binding.publicLinear = (FormatAlignmentGetter)method_getImplementation(methods[2]);
    m2Binding.publicTextureBuffer = (FormatAlignmentGetter)method_getImplementation(methods[3]);
    m2Binding.usable = false;
    __atomic_store_n(&bindingPublished, true, __ATOMIC_RELEASE);
    bool linearInstalled = ReplaceOnActualClass(cls, linear,
        (IMP)m2Binding.originalLinear, (IMP)ScopedLinearAlignment,
        method_getTypeEncoding(methods[0]));
    bool minimumInstalled = linearInstalled && ReplaceOnActualClass(cls, minimum,
        (IMP)m2Binding.originalMinimum, (IMP)ScopedMinimumAlignment,
        method_getTypeEncoding(methods[1]));
    if (!minimumInstalled) {
        RestoreOwnedMethod(cls, linear, (IMP)ScopedLinearAlignment,
                           (IMP)m2Binding.originalLinear);
        RestoreOwnedMethod(cls, minimum, (IMP)ScopedMinimumAlignment,
                           (IMP)m2Binding.originalMinimum);
    } else {
        m2Binding.usable = true;
    }
    const DeviceBinding *result = m2Binding.usable ? &m2Binding : NULL;
    pthread_mutex_unlock(&installationLock);
    return result;
}

static bool MeasurePublicRequirement(id device, const DeviceBinding *binding,
                       NSUInteger *requirement, NSUInteger *nativeLinear,
                       NSUInteger *nativeMinimum) {
    SEL linear = sel_registerName("linearTextureAlignmentBytes");
    SEL minimum = sel_registerName("deviceLinearTextureAlignmentBytes");
    *nativeLinear = binding->originalLinear(device, linear);
    *nativeMinimum = binding->originalMinimum(device, minimum);
    if (!AlignmentValid(*nativeLinear) || !AlignmentValid(*nativeMinimum))
        return false;
    SEL publicLinear = sel_registerName("minimumLinearTextureAlignmentForPixelFormat:");
    SEL publicBuffer = sel_registerName("minimumTextureBufferAlignmentForPixelFormat:");
    NSUInteger measured = 1;
    for (unsigned n = 0; n < sizeof(linearColorFormats)/sizeof(linearColorFormats[0]); ++n) {
        NSUInteger format = linearColorFormats[n];
        NSUInteger values[] = {
            binding->publicLinear(device, publicLinear, format),
            binding->publicTextureBuffer(device, publicBuffer, format),
        };
        for (unsigned k = 0; k < 2; ++k) {
            if (!AlignmentValid(values[k])) return false;
            if (values[k] > measured) measured = values[k];
        }
    }
    *requirement = measured;
    return true;
}

static void ScopedDeviceInfo(id pgDevice, SEL selector,
                            uint32_t maxKey, uint32_t capacity, uint32_t guestDst) {
    id device = nil;
    const DeviceBinding *binding = NULL;
    NSUInteger requirement = 0, nativeLinear = 0, nativeMinimum = 0;
    bool prepared = false;
    AlignmentScope *previous = currentScope;
    // A nested advertisement must measure true native constraints, not values
    // inherited from its outer scope. This also covers a throwing native getter.
    currentScope = NULL;
    @try {
        device = [originalMetalDevice(pgDevice,
                    sel_registerName("mtlDevice")) retain];
        binding = PrepareM2Binding(device);
        if (binding)
            prepared = MeasurePublicRequirement(device, binding, &requirement,
                                                &nativeLinear, &nativeMinimum);
    } @catch (NSException *exception) {
        (void)exception;
        prepared = false;
    } @finally {
        currentScope = previous;
    }
    AlignmentScope scope = {device, binding, requirement, previous};
    @try {
        currentScope = prepared ? &scope : NULL;
        if (prepared) {
            if (__sync_fetch_and_add(&diagnosticCount, 1) < 16)
                fprintf(stderr, "[ModernGuestLinearAlignment] nativeLinear=%llu nativeMinimum=%llu publicRequirement=%llu formats=9\n",
                    (unsigned long long)nativeLinear,
                    (unsigned long long)nativeMinimum,
                    (unsigned long long)requirement);
        }
        // This is the sole original PGDevice call. The destination is a 32-bit
        // guest VA, not a host pointer. We neither read nor modify guest data.
        // BEGIN V3 ORIGINAL-CALL OBSERVATION: never access guestDst.
        InfoDiagnosticContext previousDiagnostic = currentInfoDiagnostic;
        currentInfoDiagnostic = (InfoDiagnosticContext){
            ObservationSlot(&infoObservationCount, 8), maxKey, capacity, true};
        bool originalReturned = false;
        ObserveInfo("begin", prepared, false);
        @try {
            originalDeviceInfo(pgDevice, selector, maxKey, capacity, guestDst);
            originalReturned = true;
        } @finally {
            ObserveInfo("end", prepared, originalReturned);
            currentInfoDiagnostic = previousDiagnostic;
        }
        // END V3 ORIGINAL-CALL OBSERVATION
    } @finally {
        currentScope = previous;
        [device release];
    }
}

typedef struct {
    bool version, role, headerFound, dladdrKnown, sameBase, boundedPath;
    bool varRegular, privateRegular, sameFile, magic, arm64, execute;
    unsigned uid, euid, alias;
    int varErrno, privateErrno;
    kern_return_t readResult;
    mach_vm_size_t copied;
} MainIdentityEvidence;

static unsigned startupDiagnosticCount;
static const char *const VMMVarPath = "/var/root/VirtualMac2/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine";
static const char *const VMMPrivatePath = "/private/var/root/VirtualMac2/payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine";

static unsigned ExactVMMPathAlias(const char *path) {
    if (!path || strnlen(path, PATH_MAX) == PATH_MAX) return 0;
    if (!strcmp(path, VMMVarPath)) return 1;
    if (!strcmp(path, VMMPrivatePath)) return 2;
    return 0;
}

static bool SameVMMFile(MainIdentityEvidence *evidence) {
    struct stat a = {0}, b = {0};
    int aResult = stat(VMMVarPath, &a);
    evidence->varErrno = aResult ? errno : 0;
    int bResult = stat(VMMPrivatePath, &b);
    evidence->privateErrno = bResult ? errno : 0;
    evidence->varRegular = !aResult && S_ISREG(a.st_mode);
    evidence->privateRegular = !bResult && S_ISREG(b.st_mode);
    evidence->sameFile = evidence->varRegular && evidence->privateRegular &&
                         a.st_dev == b.st_dev && a.st_ino == b.st_ino;
    return evidence->sameFile;
}

static bool ActualVMM27(MainIdentityEvidence *evidence) {
    const char *version = getenv("VZ_PVG_BACKEND_VERSION");
    const char *role = getenv("VZ_PVG_TASK_ROLE");
    evidence->version = version && !strcmp(version, "27");
    evidence->role = !role || !strcmp(role, "client");
    evidence->uid = getuid();
    evidence->euid = geteuid();
    evidence->readResult = KERN_FAILURE;
    if (!evidence->version || !evidence->role || evidence->uid != 501 ||
        evidence->euid != 501) return false;
    // This exact VMM exports __mh_execute_header. dlsym uses the C name below.
    // Never substitute an observer dylib address or dyld image index0.
    void *header = dlsym(RTLD_MAIN_ONLY, "_mh_execute_header");
    evidence->headerFound = header != NULL;
    Dl_info info = {0};
    evidence->dladdrKnown = header && dladdr(header, &info);
    evidence->sameBase = evidence->dladdrKnown && info.dli_fbase == header;
    if (!evidence->sameBase || !info.dli_fname) return false;
    size_t length = strnlen(info.dli_fname, PATH_MAX);
    evidence->boundedPath = length && length < PATH_MAX;
    if (!evidence->boundedPath) return false;
    evidence->alias = ExactVMMPathAlias(info.dli_fname);
    if (!evidence->alias || !SameVMMFile(evidence)) return false;
    struct mach_header_64 actual = {0};
    evidence->readResult = mach_vm_read_overwrite(mach_task_self(),
        (mach_vm_address_t)(uintptr_t)header, sizeof(actual),
        (mach_vm_address_t)(uintptr_t)&actual, &evidence->copied);
    if (evidence->readResult != KERN_SUCCESS || evidence->copied != sizeof(actual))
        return false;
    evidence->magic = actual.magic == MH_MAGIC_64;
    evidence->arm64 = actual.cputype == CPU_TYPE_ARM64;
    evidence->execute = actual.filetype == MH_EXECUTE;
    return evidence->magic && evidence->arm64 && evidence->execute;
}

static void SafeEncoding(Method method, char output[64]) {
    const char *value = method ? method_getTypeEncoding(method) : NULL;
    if (!value) { strcpy(output, "missing"); return; }
    size_t length = strnlen(value, 64);
    if (!length || length == 64) { strcpy(output, "unsupported-length"); return; }
    for (size_t n = 0; n < length; ++n) {
        unsigned char c = (unsigned char)value[n];
        if (!(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'Z') &&
            !(c >= 'a' && c <= 'z') && !strchr("@:#^{}=+-*?[]()\"", c)) {
            strcpy(output, "unsupported-byte");
            return;
        }
    }
    memcpy(output, value, length + 1);
}

static void LogStartup(const MainIdentityEvidence *evidence, Class cls,
                       bool identity, bool installed) {
    // The disabled/default backend remains quiet. Print fixed stage/identity
    // fields only, never arbitrary environment values or image/system paths.
    if (!evidence->version || !__sync_bool_compare_and_swap(&startupDiagnosticCount, 0, 1))
        return;
    bool pgClass = cls && !strcmp(class_getName(cls), "_PGDevice");
    Method info = pgClass ? class_getInstanceMethod(cls,
        sel_registerName("getDeviceInfo:length:dst:")) : NULL;
    Method metal = pgClass ? class_getInstanceMethod(cls,
        sel_registerName("mtlDevice")) : NULL;
    const char *infoArgs[] = {"@", ":", @encode(uint32_t), @encode(uint32_t), @encode(uint32_t)};
    const char *metalArgs[] = {"@", ":"};
    bool infoABI = MethodABI(info, @encode(void), infoArgs, 5);
    bool metalABI = MethodABI(metal, "@", metalArgs, 2);
    char infoEncoding[64], metalEncoding[64];
    SafeEncoding(info, infoEncoding);
    SafeEncoding(metal, metalEncoding);
    const char *stage = installed ? "installed" :
        !evidence->role ? "role" :
        (evidence->uid != 501 || evidence->euid != 501) ? "credentials" :
        !evidence->headerFound ? "main-symbol" :
        !evidence->dladdrKnown ? "dladdr" : !evidence->sameBase ? "main-base" :
        !evidence->boundedPath ? "main-path-bounds" : !evidence->alias ? "main-path" :
        (!evidence->varRegular || !evidence->privateRegular) ? "alias-file" :
        !evidence->sameFile ? "alias-inode" :
        evidence->readResult != KERN_SUCCESS ? "header-read" :
        evidence->copied != sizeof(struct mach_header_64) ? "header-size" :
        (!evidence->magic || !evidence->arm64 || !evidence->execute) ? "header-contract" :
        !pgClass ? "pg-class" : !infoABI ? "pg-info-abi" :
        !metalABI ? "pg-metal-abi" : "method-ownership";
    fprintf(stderr, "[ModernGuestLinearAlignment] startup stage=%s identity=%u version=%u role=%u uid=%u euid=%u headerFound=%u dladdr=%u sameBase=%u boundedPath=%u alias=%u varRegular=%u privateRegular=%u sameFile=%u varErrno=%d privateErrno=%d readKr=%d copied=%llu magic=%u arm64=%u execute=%u pgClass=%u infoABI=%u metalABI=%u infoEncoding=%s metalEncoding=%s installed=%u\n",
        stage, identity, evidence->version, evidence->role, evidence->uid, evidence->euid,
        evidence->headerFound, evidence->dladdrKnown, evidence->sameBase,
        evidence->boundedPath, evidence->alias, evidence->varRegular,
        evidence->privateRegular, evidence->sameFile, evidence->varErrno,
        evidence->privateErrno, evidence->readResult,
        (unsigned long long)evidence->copied, evidence->magic, evidence->arm64,
        evidence->execute, pgClass, infoABI, metalABI, infoEncoding, metalEncoding,
        installed);
}

static bool InstallPGDeviceScope(Class cls) {
    if (!cls || strcmp(class_getName(cls), "_PGDevice") ||
        sizeof(NSUInteger) != 8 || sizeof(uint32_t) != 4) return false;
    SEL getInfo = sel_registerName("getDeviceInfo:length:dst:");
    SEL getMetal = sel_registerName("mtlDevice");
    const char *infoArgs[] = {"@", ":", @encode(uint32_t), @encode(uint32_t), @encode(uint32_t)};
    const char *metalArgs[] = {"@", ":"};
    Method info = class_getInstanceMethod(cls, getInfo);
    Method metal = class_getInstanceMethod(cls, getMetal);
    if (!MethodABI(info, @encode(void), infoArgs, 5) ||
        !MethodABI(metal, "@", metalArgs, 2)) return false;
    pthread_mutex_lock(&installationLock);
    if (registeredPGDevice) {
        bool installed = registeredPGDevice == cls &&
                         method_getImplementation(info) == (IMP)ScopedDeviceInfo;
        pthread_mutex_unlock(&installationLock);
        return installed;
    }
    originalDeviceInfo = (DeviceInfoGetter)method_getImplementation(info);
    originalMetalDevice = (MetalDeviceGetter)method_getImplementation(metal);
    bool installed = ReplaceOnActualClass(cls, getInfo, (IMP)originalDeviceInfo,
                    (IMP)ScopedDeviceInfo, method_getTypeEncoding(info));
    if (installed) registeredPGDevice = cls;
    pthread_mutex_unlock(&installationLock);
    return installed;
}

bool VZModernInstallGuestLinearAlignmentAdvertisement(Class pgDeviceClass) {
    int savedErrno = errno;
    MainIdentityEvidence evidence = {0};
    bool identity = ActualVMM27(&evidence);
    bool installed = identity && InstallPGDeviceScope(pgDeviceClass);
    LogStartup(&evidence, pgDeviceClass, identity, installed);
    errno = savedErrno;
    return installed;
}
