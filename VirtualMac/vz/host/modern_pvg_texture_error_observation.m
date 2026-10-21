#include "modern_pvg_texture_error_observation.h"
#include <errno.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <limits.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_OSX
#include <mach/mach_vm.h>
#else
// Same MIG ABI as the SDK's macOS mach_vm.h. iOS SDK hides the header, while
// the audited native libSystem exports the 64-bit read-only entry point.
extern kern_return_t mach_vm_read_overwrite(vm_map_read_t, mach_vm_address_t,
                                          mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
#endif
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// Exact native evidence: GPUtask 682dc -> 634c8/634ac/6350c -> OSlog.
// 22-byte buffer: 02 02 20 08, cstring at+4, 20 08, cstring at+14.
// First string must be "texture", second is the original Expected error.
// No generic OSlog decoder or C++ Expected/shared_ptr ABI interception.
_Static_assert(sizeof(uintptr_t) == 8, "Audited ABI requires 64-bit pointers");
static const char directoryPath[] = "/var/root/VirtualMac2/diagnostics/pvg-fault-observation";
static const char nativeFormat[] = "Failed to get %s (%s)";
static const char nativeResource[] = "texture";
enum { ErrorLimit = 128, ErrorCapacity = 256, JournalCapacity = 1152 };
static atomic_bool enabled = false;
static atomic_flag attempted = ATOMIC_FLAG_INIT;
static atomic_uint accepted = 0;
static const void *taskImageHeader;
static int journalFD = -1;

static bool ExactStat(const struct stat *st, bool directory) {
    return st->st_uid == geteuid() &&
        (directory ? S_ISDIR(st->st_mode) : S_ISREG(st->st_mode)) &&
        (st->st_mode & 07777) == (directory ? 0700 : 0600) &&
        (directory || st->st_nlink == 1);
}

static bool PrivateFlag(int directoryFD) {
    struct stat before, after;
    struct stat dir;
    if (fstat(directoryFD, &dir) || !ExactStat(&dir, true)) return false;
    int fd = openat(directoryFD, "enabled", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return false;
    char bytes[3] = {0};
    bool valid = fstat(fd, &before) == 0 && ExactStat(&before, false) && before.st_size == 2;
    ssize_t count = valid ? read(fd, bytes, sizeof(bytes)) : -1;
    valid = valid && count == 2 && bytes[0] == '1' && bytes[1] == '\n' &&
        fstat(fd, &after) == 0 && ExactStat(&after, false) && after.st_size == 2 &&
        after.st_dev == before.st_dev && after.st_ino == before.st_ino;
    close(fd);
    return valid;
}

static bool EnvironmentAllows(const char *value, int directoryFD) {
    // A present env has precedence, including empty/invalid values disabling.
    return value ? !strcmp(value, "1") : PrivateFlag(directoryFD);
}

static bool ReadBytes(uintptr_t address, void *target, size_t length) {
    if (!address || !length || address > UINTPTR_MAX - length) return false;
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)address,
        (mach_vm_size_t)length, (mach_vm_address_t)(uintptr_t)target, &copied) == KERN_SUCCESS &&
        copied == length;
}

static bool ReadError(uintptr_t address, char *output, size_t *count, bool *truncated) {
    *count = 0;
    *truncated = false;
    if (!address || !vm_page_size) return false;
    for (size_t used = 0; used < ErrorCapacity - 1;) {
        if (address > UINTPTR_MAX - used) return false;
        uintptr_t current = address + used;
        size_t chunk = 16;
        size_t remainingPage = vm_page_size - current % vm_page_size;
        if (chunk > remainingPage) chunk = remainingPage;
        if (chunk > ErrorCapacity - 1 - used) chunk = ErrorCapacity - 1 - used;
        char bytes[16];
        if (!ReadBytes(current, bytes, chunk)) return false;
        for (size_t n = 0; n < chunk; ++n) {
            if (!bytes[n]) {
                output[used + n] = 0;
                *count = used + n;
                return true;
            }
            output[used + n] = bytes[n];
        }
        used += chunk;
        *count = used;
    }
    output[ErrorCapacity - 1] = 0;
    *truncated = true;
    return true;
}

static void RecordError(unsigned sequence, uintptr_t errorAddress) {
    char reason[ErrorCapacity] = {0};
    size_t count = 0;
    bool truncated = false;
    bool known = ReadError(errorAddress, reason, &count, &truncated);
    // Hex preserves original bytes; the short preview cannot inject new lines.
    char hex[ErrorCapacity * 2 + 1] = {0}, preview[81] = {0};
    static const char alphabet[] = "0123456789abcdef";
    if (known) {
        for (size_t i = 0; i < count; ++i) {
            unsigned char c = (unsigned char)reason[i];
            hex[i * 2] = alphabet[c >> 4];
            hex[i * 2 + 1] = alphabet[c & 15];
            if (i < sizeof(preview) - 1) preview[i] = c >= 32 && c <= 126 && c != '"' && c != '\\' ? (char)c : '?';
        }
    }
    struct timespec now = {0};
    (void)clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t tid = 0;
    (void)pthread_threadid_np(NULL, &tid);
    char line[JournalCapacity];
    int length = snprintf(line, sizeof(line),
        "[PVGTextureError] n=%u mono=%lld.%09ld pid=%d tid=%llu dso=%p type=0x10 size=22 resource=texture originalError=0x%llx known=%d truncated=%d bytes=%zu preview=\"%s\" errorHex=%s original-six-args-unchanged=1\n",
        sequence, (long long)now.tv_sec, now.tv_nsec, getpid(), (unsigned long long)tid,
        taskImageHeader, (unsigned long long)errorAddress, known, truncated, known ? count : 0, preview, hex);
    if (length > 0 && length < (int)sizeof(line)) (void)write(journalFD, line, (size_t)length);
}

static void ObserveIfMatch(void *dso, os_log_type_t type, const char *format, uint8_t *buffer, uint32_t size) {
    if (!atomic_load_explicit(&enabled, memory_order_acquire) || dso != taskImageHeader ||
        type != OS_LOG_TYPE_ERROR || size != 22) return;
    char actualFormat[sizeof(nativeFormat)];
    if (!ReadBytes((uintptr_t)format, actualFormat, sizeof(actualFormat)) ||
        memcmp(actualFormat, nativeFormat, sizeof(nativeFormat))) return;
    uint8_t payload[22];
    if (!ReadBytes((uintptr_t)buffer, payload, sizeof(payload)) ||
        payload[0] != 2 || payload[1] != 2 || payload[2] != 0x20 || payload[3] != 8 ||
        payload[12] != 0x20 || payload[13] != 8) return;
    uintptr_t resourceAddress, errorAddress;
    memcpy(&resourceAddress, payload + 4, sizeof(resourceAddress));
    memcpy(&errorAddress, payload + 14, sizeof(errorAddress));
    char resource[sizeof(nativeResource)];
    if (!ReadBytes(resourceAddress, resource, sizeof(resource)) ||
        memcmp(resource, nativeResource, sizeof(nativeResource))) return;
    unsigned previous = atomic_load_explicit(&accepted, memory_order_relaxed);
    do {
        if (previous >= ErrorLimit + 1) return;
    } while (!atomic_compare_exchange_weak_explicit(&accepted, &previous, previous + 1,
                                                   memory_order_relaxed, memory_order_relaxed));
    unsigned n = previous + 1;
    if (n <= ErrorLimit) RecordError(n, errorAddress);
    else if (n == ErrorLimit + 1) {
        static const char exhausted[] = "[PVGTextureError] quota-exhausted=128 original-forwarding-continues=1\n";
        (void)write(journalFD, exhausted, sizeof(exhausted) - 1);
    }
}

#if defined(VZ_TEXTURE_ERROR_OBSERVER_TESTING)
// Testing-only stand-in is absent from the signed production candidate. It
// proves parameter identity and errno preservation without issuing malformed
// calls to system OSlog. No mock is used by the production wrapper.
extern void VZTextureErrorTestOriginal(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
#define NativeOSLog VZTextureErrorTestOriginal
#else
#define NativeOSLog _os_log_error_impl
#endif

static void TextureErrorOSLog(void *dso, os_log_t log, os_log_type_t type,
                              const char *format, uint8_t *buffer, uint32_t size) {
    int entryError = errno;
    ObserveIfMatch(dso, type, format, buffer, size);
    errno = entryError;
    // Standard dyld interpose keeps references in the interposing image bound
    // to the original. Always one call, all six arguments and payload intact.
    NativeOSLog(dso, log, type, format, buffer, size);
}

#if !defined(VZ_TEXTURE_ERROR_OBSERVER_TESTING)
__attribute__((used)) static const struct { const void *replacement, *original; }
    textureErrorInterpose __attribute__((section("__DATA,__interpose"))) =
    {(const void *)TextureErrorOSLog, (const void *)_os_log_error_impl};
#endif

static bool ImageNameMatches(const char *image) {
    static const char expected[] = "com.apple.gpusw.ParavirtualizedGraphicsGPUTask";
    uintptr_t address = (uintptr_t)image;
    size_t basenameLength = 0;
    bool match = true;
    if (!address || !vm_page_size) return false;
    // Read only the SDK-exposed image name, retain no arbitrary path, and
    // reject unreadable/unterminated names. The last component must be exact.
    for (size_t used = 0; used < PATH_MAX;) {
        if (address > UINTPTR_MAX - used) return false;
        uintptr_t current = address + used;
        size_t chunk = 16, remainingPage = vm_page_size - current % vm_page_size;
        if (chunk > remainingPage) chunk = remainingPage;
        if (chunk > PATH_MAX - used) chunk = PATH_MAX - used;
        char bytes[16];
        if (!ReadBytes(current, bytes, chunk)) return false;
        for (size_t i = 0; i < chunk; ++i) {
            if (!bytes[i]) return match && basenameLength == sizeof(expected) - 1;
            if (bytes[i] == '/') { basenameLength = 0; match = true; }
            else {
                if (basenameLength >= sizeof(expected) - 1 || bytes[i] != expected[basenameLength]) match = false;
                ++basenameLength;
            }
        }
        used += chunk;
    }
    return false;
}

static bool ServerIdentity(const char *backend, const char *role, const char *image,
                           const struct mach_header *mainHeader, uid_t uid) {
    struct mach_header_64 header;
    return uid == 501 && backend && !strcmp(backend, "27") && role && !strcmp(role, "server") &&
        ImageNameMatches(image) &&
        ReadBytes((uintptr_t)mainHeader, &header, sizeof(header)) && header.magic == MH_MAGIC_64 &&
        header.cputype == CPU_TYPE_ARM64 && header.filetype == MH_EXECUTE;
}

typedef struct {
    const struct mach_header *header;
    const char *image;
    bool addressInfoKnown, sameBase;
} MainImage;

static MainImage ResolveMainImage(void) {
    // Real GPUtask exports __mh_execute_header atRVA0. RTLD_MAIN_ONLY scopes
    // the C name _mh_execute_header to the executable. Do not use image0 or
    // dladdr(an observer function), which names this interposing dylib.
    const struct mach_header *candidate = dlsym(RTLD_MAIN_ONLY, "_mh_execute_header");
    Dl_info info = {0};
    bool known = candidate && dladdr(candidate, &info) != 0;
    return (MainImage){candidate, known ? info.dli_fname : NULL, known,
                       known && info.dli_fbase == (const void *)candidate};
}

static bool ValidMainIdentity(const MainImage *main, const char *backend, const char *role, uid_t uid) {
    return main->addressInfoKnown && main->sameBase &&
        ServerIdentity(backend, role, main->image, main->header, uid);
}

static bool DiagnosticRequested(const char *backend, const char *role) {
    if (!backend || strcmp(backend, "27") || !role || strcmp(role, "server")) return false;
    const char *value = getenv("VZ_PVG_FAULT_OBSERVE");
    if (value) return !strcmp(value, "1");
    int dir = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    bool valid = dir >= 0 && PrivateFlag(dir);
    if (dir >= 0) close(dir);
    return valid;
}

typedef struct {
    kern_return_t kr;
    mach_vm_size_t copied;
    bool read, magic, cpu, execute;
} HeaderDiagnostic;

static HeaderDiagnostic DiagnoseHeader(const struct mach_header *address) {
    struct mach_header_64 bytes = {0};
    HeaderDiagnostic d = {.kr = KERN_INVALID_ADDRESS};
    uintptr_t pointer = (uintptr_t)address;
    if (pointer && pointer <= UINTPTR_MAX - sizeof(bytes))
        d.kr = mach_vm_read_overwrite(mach_task_self(), pointer, sizeof(bytes),
                                      (uintptr_t)&bytes, &d.copied);
    d.read = d.kr == KERN_SUCCESS && d.copied == sizeof(bytes);
    d.magic = d.read && bytes.magic == MH_MAGIC_64;
    d.cpu = d.read && bytes.cputype == CPU_TYPE_ARM64;
    d.execute = d.read && bytes.filetype == MH_EXECUTE;
    return d;
}

static void StartupDiagnostic(const char *stage, const char *backend, const char *role,
                              const MainImage *main, bool directoryValid, int stageError) {
    int savedError = errno;
    if (!DiagnosticRequested(backend, role)) { errno = savedError; return; }
    static atomic_flag reported = ATOMIC_FLAG_INIT;
    if (atomic_flag_test_and_set_explicit(&reported, memory_order_relaxed)) { errno = savedError; return; }
    const struct mach_header *zero = _dyld_get_image_header(0);
    HeaderDiagnostic zd = DiagnoseHeader(zero), md = DiagnoseHeader(main->header);
    char line[640];
    int count = snprintf(line, sizeof(line),
        "[PVGTextureStartup] stage=%s pid=%d uid501=%d backend27=1 server=1 image0Name=%d image0Present=%d image0Read=%d image0Kr=%d image0Copied=%llu image0Magic=%d image0CPU=%d image0Execute=%d selectedPresent=%d selectedAddressInfo=%d selectedSameBase=%d selectedName=%d selectedRead=%d selectedKr=%d selectedCopied=%llu selectedMagic=%d selectedCPU=%d selectedExecute=%d directoryValid=%d stageErrno=%d originalGatePreserved=1\n",
        stage, getpid(), geteuid() == 501, ImageNameMatches(_dyld_get_image_name(0)), zero != NULL,
        zd.read, zd.kr, (unsigned long long)zd.copied, zd.magic, zd.cpu, zd.execute,
        main->header != NULL, main->addressInfoKnown, main->sameBase, ImageNameMatches(main->image),
        md.read, md.kr, (unsigned long long)md.copied, md.magic, md.cpu, md.execute, directoryValid, stageError);
    if (count > 0 && count < (int)sizeof(line)) (void)write(STDERR_FILENO, line, (size_t)count);
    errno = savedError;
}

bool VZModernInstallTextureErrorObservation(void) {
    int savedError = errno;
    if (atomic_flag_test_and_set_explicit(&attempted, memory_order_acquire)) {
        bool active = atomic_load_explicit(&enabled, memory_order_acquire);
        errno = savedError;
        return active;
    }
    const char *backend = getenv("VZ_PVG_BACKEND_VERSION");
    const char *role = getenv("VZ_PVG_TASK_ROLE");
    MainImage main = ResolveMainImage();
    if (!ValidMainIdentity(&main, backend, role, geteuid())) {
        StartupDiagnostic("identity", backend, role, &main, false, errno);
        errno = savedError;
        return false;
    }
    int directoryFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat st;
    bool valid = directoryFD >= 0 && fstat(directoryFD, &st) == 0 && ExactStat(&st, true);
    if (!valid || !EnvironmentAllows(getenv("VZ_PVG_FAULT_OBSERVE"), directoryFD)) {
        StartupDiagnostic(valid ? "opt-in" : "directory", backend, role, &main, valid, errno);
        if (directoryFD >= 0) close(directoryFD);
        errno = savedError;
        return false;
    }
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now)) {
        StartupDiagnostic("clock", backend, role, &main, valid, errno);
        close(directoryFD); errno = savedError; return false;
    }
    char filename[112];
    int n = snprintf(filename, sizeof(filename), "pvgtexture-%d-%lld-%09ld.log", getpid(), (long long)now.tv_sec, now.tv_nsec);
    int fd = n > 0 && n < (int)sizeof(filename) ? openat(directoryFD, filename,
        O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600) : -1;
    close(directoryFD);
    if (fd < 0 || fstat(fd, &st) || !ExactStat(&st, false)) {
        StartupDiagnostic(fd < 0 ? "journal-open" : "journal-stat", backend, role, &main, valid, errno);
        if (fd >= 0) close(fd);
        errno = savedError;
        return false;
    }
    taskImageHeader = main.header;
    if (!taskImageHeader) {
        StartupDiagnostic("selected-header-null", backend, role, &main, valid, errno);
        close(fd); errno = savedError; return false;
    }
    journalFD = fd;
    atomic_store_explicit(&enabled, true, memory_order_release);
    StartupDiagnostic("enabled", backend, role, &main, valid, 0);
    errno = savedError;
    return true;
}

#if defined(VZ_TEXTURE_ERROR_OBSERVER_TESTING)
void VZTextureErrorTestConfigure(const void *header, int fd, bool on) {
    taskImageHeader = header;
    journalFD = fd;
    atomic_store_explicit(&accepted, 0, memory_order_relaxed);
    atomic_store_explicit(&enabled, on, memory_order_release);
}
void VZTextureErrorTestCall(void *dso, os_log_t log, os_log_type_t type,
                          const char *format, uint8_t *buffer, uint32_t size) {
    TextureErrorOSLog(dso, log, type, format, buffer, size);
}
unsigned VZTextureErrorTestAccepted(void) { return atomic_load_explicit(&accepted, memory_order_relaxed); }
bool VZTextureErrorTestEnvironment(const char *value, int directoryFD) { return EnvironmentAllows(value, directoryFD); }
bool VZTextureErrorTestIdentity(const char *backend, const char *role, const char *image,
                               const struct mach_header *header, uid_t uid) {
    return ServerIdentity(backend, role, image, header, uid);
}
bool VZTextureErrorTestMain(const char *backend, const char *role, const char *image,
                           const struct mach_header *header, uid_t uid, bool addressInfo, bool sameBase) {
    MainImage main = {header, image, addressInfo, sameBase};
    return ValidMainIdentity(&main, backend, role, uid);
}
bool VZTextureErrorTestNativeMain(bool *addressInfo, bool *sameBase, bool *execute) {
    int savedError = errno;
    MainImage main = ResolveMainImage();
    HeaderDiagnostic d = DiagnoseHeader(main.header);
    *addressInfo = main.addressInfoKnown; *sameBase = main.sameBase; *execute = d.execute;
    errno = savedError;
    return main.header && d.magic && d.cpu && d.execute;
}
#endif
