// Only the two missing entry contracts are implemented. Genuine old Swift
// owns decoding, substitutions, metadata caching, state checks and failures.
#include "modern_swift_lookup_compat.h"
#include <ptrauth.h>

namespace {
constexpr uintptr_t ContextDiscriminator = 0xb5e3;
const void *AuthenticateExternalContext(const void *signedContext) {
    if (!signedContext) return nullptr;
    const void *authenticated = ptrauth_auth_data(
        signedContext, ptrauth_key_process_independent_data,
        ContextDiscriminator);
    // Match the real new entries' explicit AUTDA / XPACD / compare / BRK
    // failure boundary. Never strip an unauthenticated input and continue.
    const void *stripped = ptrauth_strip(
        authenticated, ptrauth_key_process_independent_data);
    if (authenticated != stripped) {
        __asm__ volatile("brk #0xc472" ::: "memory");
        __builtin_unreachable();
    }
    // The old entries expect a raw unsigned context. No DB signing is needed
    // for their opaque void* ABI. Valid signed null also becomes null here.
    return authenticated;
}
}

extern "C" __attribute__((swiftcall, visibility("default")))
const void *swift_getTypeByMangledNameInContext2(
    const char *name, std::size_t length, const void *signedContext,
    const void *const *genericArgs) {
    const void *context = AuthenticateExternalContext(signedContext);
    const auto provider = lookup_compat::AcquireVerifiedProvider();
    const void *result = provider.context(name, length, context, genericArgs);
    lookup_compat::VerifyProvider();
    return result;
}

extern "C" __attribute__((swiftcall, visibility("default")))
const void *swift_getTypeByMangledNameInContextInMetadataState2(
    std::size_t metadataState, const char *name, std::size_t length,
    const void *signedContext, const void *const *genericArgs) {
    const void *context = AuthenticateExternalContext(signedContext);
    const auto provider = lookup_compat::AcquireVerifiedProvider();
    // Forward the complete register value unchanged. The actual old State
    // entry, like the new original, clears bit 8 to form a blocking request.
    // This is a MetadataState API, not a MetadataResponse/nonblocking API.
    const void *result = provider.state(
        metadataState, name, length, context, genericArgs);
    lookup_compat::VerifyProvider();
    // Preserve genuine nullable metadata; binding/PAC failures never forge
    // a null metadata result as an apparent successful lookup.
    return result;
}
