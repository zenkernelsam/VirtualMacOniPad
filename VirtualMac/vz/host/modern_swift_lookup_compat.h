// App-private entry adaptation verified in an isolated iPad probe.
// The old stock runtime still owns parsing; full Swift27 parser equivalence is unproven.
// API and PAC contract: official Swift 5ea0a2a5d8e126628da27747739e8d017c1d4882;
// exact original macOS27 entry instructions and old iPad source pins accompany
// this candidate. The old runtime creates/checks the real metadata.
#ifndef VZ_PRIVATE_LOOKUP_COMPAT_H
#define VZ_PRIVATE_LOOKUP_COMPAT_H
#include <cstddef>
#include <cstdint>

#if !defined(__arm64e__) || !__has_feature(ptrauth_calls)
#error "This compatibility module requires the audited arm64e PAC ABI"
#endif
#if !__has_attribute(swiftcall)
#error "SwiftCC is required"
#endif

namespace lookup_compat {
using ContextLookup = const void *(__attribute__((swiftcall)) *)(
    const char *, std::size_t, const void *, const void *const *);
using StateLookup = const void *(__attribute__((swiftcall)) *)(
    std::size_t, const char *, std::size_t, const void *, const void *const *);
struct Provider {
    ContextLookup context;
    StateLookup state;
};
// Hidden, fail-closed binding; no Swift metadata call is performed here.
__attribute__((visibility("hidden"))) Provider AcquireVerifiedProvider();
__attribute__((visibility("hidden"))) void VerifyProvider();
}

// Register-level ABI is four/five SwiftCC parameters, one nullable pointer
// result. signedContext carries DA, no address diversity, discriminator b5e3.
// It is intentionally opaque void* here: a ptrauth_struct ContextDescriptor
// C++ type would add an implicit DB conversion before explicit DA auth.
extern "C" __attribute__((swiftcall, visibility("default")))
const void *swift_getTypeByMangledNameInContext2(
    const char *name, std::size_t length, const void *signedContext,
    const void *const *genericArgs);
extern "C" __attribute__((swiftcall, visibility("default")))
const void *swift_getTypeByMangledNameInContextInMetadataState2(
    std::size_t metadataState, const char *name, std::size_t length,
    const void *signedContext, const void *const *genericArgs);
#endif
