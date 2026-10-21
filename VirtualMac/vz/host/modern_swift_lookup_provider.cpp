// Fail-closed binding to the exact existing old iPad stock Swift image.
// Shared-cache fileoff is provenance, never a runtime-address formula.
// No global lookup, provider fallback, constructor or metadata call.
#include "modern_swift_lookup_compat.h"
#include "old_entry_pins.h"
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <pthread.h>

namespace {
constexpr char CorePath[] = "/usr/lib/swift/libswiftCore.dylib";
constexpr uint8_t CoreUUID[16] = {
    0xf8,0x96,0xd1,0x45,0xe0,0x25,0x39,0xd6,
    0xaf,0xd3,0xbc,0x0a,0x2a,0xd4,0xf8,0x39};
constexpr uint64_t CoreVMaddr = 0x180bd5000;
constexpr uint64_t CoreTextSize = 0x569000;
constexpr uint64_t CoreTextFileoff = 0xb7d000;
constexpr uint32_t CoreFlags = 0x82110085;
constexpr uint32_t CoreCommandCount = 20;
constexpr uint32_t CoreCommandBytes = 5344;
constexpr uint32_t CoreBuildTool = 3;
constexpr uint32_t CoreBuildToolVersion = 53739776;

struct Epoch {
    const mach_header_64 *header;
    uint32_t index;
    intptr_t slide;
};
struct Binding {
    Epoch epoch{};
    void *handle = nullptr; // Retain the provider for this library's lifetime.
    lookup_compat::Provider functions{};
};
Binding Original{};
pthread_once_t Once = PTHREAD_ONCE_INIT;

[[noreturn]] void RejectProvider() {
    // A provider failure is not a genuine Swift lookup returning null.
    __builtin_trap();
}
void Require(bool valid) {
    if (!valid) RejectProvider();
}
bool AddSlide(uint64_t vmaddr, intptr_t slide, uintptr_t *result) {
    if (vmaddr > UINTPTR_MAX) return false;
    if (slide >= 0) {
        const auto add = static_cast<uintptr_t>(slide);
        if (vmaddr > UINTPTR_MAX - add) return false;
        *result = static_cast<uintptr_t>(vmaddr) + add;
    } else {
        const auto subtract = static_cast<uintptr_t>(-(slide + 1)) + 1;
        if (vmaddr < subtract) return false;
        *result = static_cast<uintptr_t>(vmaddr) - subtract;
    }
    return true;
}
bool SameEpoch(const Epoch &epoch) {
    if (epoch.index >= _dyld_image_count()) return false;
    const char *name = _dyld_get_image_name(epoch.index);
    return name && !std::strcmp(name, CorePath) &&
        _dyld_get_image_header(epoch.index) ==
            reinterpret_cast<const mach_header *>(epoch.header) &&
        _dyld_get_image_vmaddr_slide(epoch.index) == epoch.slide;
}
Epoch FindCore() {
    Epoch found{};
    unsigned matches = 0;
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || std::strcmp(name, CorePath)) continue;
        found = {reinterpret_cast<const mach_header_64 *>(
                     _dyld_get_image_header(i)),
                 i, _dyld_get_image_vmaddr_slide(i)};
        ++matches;
    }
    Require(matches == 1 && found.header && count == _dyld_image_count() &&
            SameEpoch(found));
    return found;
}
bool HeaderExact(const Epoch &epoch) {
    if (!SameEpoch(epoch)) return false;
    const auto *h = epoch.header;
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64 ||
        static_cast<uint32_t>(h->cpusubtype) != 0x80000002U ||
        h->filetype != MH_DYLIB || h->flags != CoreFlags ||
        h->ncmds != CoreCommandCount || h->sizeofcmds != CoreCommandBytes)
        return false;
    const uintptr_t headerAddress = reinterpret_cast<uintptr_t>(h);
    if (headerAddress > UINTPTR_MAX - sizeof(*h) - CoreCommandBytes)
        return false;
    const uint8_t *at = reinterpret_cast<const uint8_t *>(h + 1);
    const uint8_t *end = at + CoreCommandBytes;
    unsigned uuidCount = 0, buildCount = 0, textCount = 0;
    for (uint32_t i = 0; i < CoreCommandCount; ++i) {
        if (static_cast<size_t>(end - at) < sizeof(load_command)) return false;
        const auto *command = reinterpret_cast<const load_command *>(at);
        if (command->cmdsize < sizeof(*command) || command->cmdsize % 8 ||
            command->cmdsize > static_cast<size_t>(end - at)) return false;
        if (command->cmd == LC_UUID) {
            if (++uuidCount != 1 || command->cmdsize != sizeof(uuid_command) ||
                std::memcmp(reinterpret_cast<const uuid_command *>(at)->uuid,
                            CoreUUID, sizeof(CoreUUID))) return false;
        } else if (command->cmd == LC_BUILD_VERSION) {
            if (++buildCount != 1 || command->cmdsize !=
                    sizeof(build_version_command) + sizeof(build_tool_version))
                return false;
            const auto *build = reinterpret_cast<const build_version_command *>(at);
            const auto *tool = reinterpret_cast<const build_tool_version *>(build + 1);
            if (build->platform != 2 || build->minos != 0xf0400 ||
                build->sdk != 0x100100 || build->ntools != 1 ||
                tool->tool != CoreBuildTool ||
                tool->version != CoreBuildToolVersion) return false;
        } else if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(segment_command_64)) return false;
            const auto *segment = reinterpret_cast<const segment_command_64 *>(at);
            const size_t sectionBytes = command->cmdsize - sizeof(*segment);
            if (sectionBytes % sizeof(section_64) ||
                segment->nsects != sectionBytes / sizeof(section_64)) return false;
            if (!std::strncmp(segment->segname, "__TEXT", sizeof(segment->segname))) {
                uintptr_t runtimeBegin = 0;
                if (++textCount != 1 || segment->vmaddr != CoreVMaddr ||
                    segment->vmsize != CoreTextSize ||
                    segment->filesize != CoreTextSize ||
                    segment->fileoff != CoreTextFileoff ||
                    segment->initprot != 5 || segment->maxprot != 5 ||
                    !AddSlide(segment->vmaddr, epoch.slide, &runtimeBegin) ||
                    runtimeBegin != headerAddress ||
                    CoreTextSize > UINTPTR_MAX - runtimeBegin) return false;
            }
        }
        at += command->cmdsize;
    }
    return at == end && uuidCount == 1 && buildCount == 1 && textCount == 1 &&
        SameEpoch(epoch);
}
bool EntryExact(const Epoch &epoch, const void *signedPointer, uintptr_t rva,
                const uint8_t expected[128]) {
    if (!signedPointer || !HeaderExact(epoch)) return false;
    const void *plain = ptrauth_strip(signedPointer, ptrauth_key_function_pointer);
    const auto address = reinterpret_cast<uintptr_t>(plain);
    const auto base = reinterpret_cast<uintptr_t>(epoch.header);
    Dl_info info{};
    return rva <= CoreTextSize - 128 && base <= UINTPTR_MAX - rva &&
        address == base + rva && dladdr(plain, &info) &&
        info.dli_fbase == epoch.header && info.dli_fname &&
        !std::strcmp(info.dli_fname, CorePath) &&
        !std::memcmp(plain, expected, 128) && SameEpoch(epoch);
}
void Bind() {
    Original.epoch = FindCore();
    Require(HeaderExact(Original.epoch));
    const auto count = _dyld_image_count();
    // NOLOAD permits only the already identified stock provider. No private or
    // modern Swift candidate, global dlsym scope, or fallback is accepted.
    Original.handle = dlopen(CorePath, RTLD_NOLOAD | RTLD_NOW | RTLD_LOCAL);
    Require(Original.handle && count == _dyld_image_count() &&
            HeaderExact(Original.epoch));
    void *context = dlsym(Original.handle, "swift_getTypeByMangledNameInContext");
    void *state = dlsym(Original.handle,
                       "swift_getTypeByMangledNameInContextInMetadataState");
    Require(EntryExact(Original.epoch, context, OLD_LEGACY_RVA, OLD_LEGACY_BODY) &&
            EntryExact(Original.epoch, state, OLD_STATE_RVA, OLD_STATE_BODY));
    Original.functions.context = reinterpret_cast<lookup_compat::ContextLookup>(
        ptrauth_sign_unauthenticated(
            ptrauth_strip(context, ptrauth_key_function_pointer),
            ptrauth_key_function_pointer, 0));
    Original.functions.state = reinterpret_cast<lookup_compat::StateLookup>(
        ptrauth_sign_unauthenticated(
            ptrauth_strip(state, ptrauth_key_function_pointer),
            ptrauth_key_function_pointer, 0));
}
void CheckBinding() {
    Require(HeaderExact(Original.epoch) &&
        EntryExact(Original.epoch,
            reinterpret_cast<const void *>(Original.functions.context),
            OLD_LEGACY_RVA, OLD_LEGACY_BODY) &&
        EntryExact(Original.epoch,
            reinterpret_cast<const void *>(Original.functions.state),
            OLD_STATE_RVA, OLD_STATE_BODY));
}
}

namespace lookup_compat {
Provider AcquireVerifiedProvider() {
    Require(pthread_once(&Once, Bind) == 0);
    CheckBinding();
    return Original.functions;
}
void VerifyProvider() {
    CheckBinding();
}
}
