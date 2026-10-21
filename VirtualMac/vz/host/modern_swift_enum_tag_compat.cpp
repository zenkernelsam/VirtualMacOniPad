// This source file adapts the Swift.org open source project's runtime code.
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception.
// See https://swift.org/LICENSE.txt for license information.
// Scoped Swift compact-value-witness enum-tag implementation.
// Adapted from Swift commit 5ea0a2a5d8e126628da27747739e8d017c1d4882,
// stdlib/public/runtime/BytecodeLayouts.cpp, swift_cvw_enumFn_getEnumTagImpl.
// Apache-2.0 with Runtime Library Exception. Preserve upstream notices in upstream/.
// Exact arm64e layout/PAC contract independently confirmed in the pinned macOS27
// libswiftCore UUID C9B36DA7-BB34-35AF-BC5D-91ECBCAA9ED0, VA 0x194e49f08.
// This is the default implementation, not Swift's compatibility-override registry.
// Call only with valid, matching compiler-generated compact enum metadata.
#include <cstdint>
#include <cstring>
#include <ptrauth.h>

static_assert(sizeof(void *) == 8, "Audited LP64 layout only");
static_assert(sizeof(unsigned) == 4, "Swift enum witness returns a 32-bit tag");
using GetEnumTag = unsigned (*)(const uint8_t *);

extern "C" __attribute__((visibility("default")))
unsigned swift_cvw_enumFn_getEnumTag(const void *value, const void *metadata) {
    // This is Metadata::getLayoutString(), not the value-witness table at -8.
    auto slot = reinterpret_cast<const uint8_t *>(metadata) - 16;
    const uint8_t *layout;
    std::memcpy(&layout, slot, sizeof(layout));
#if __has_feature(ptrauth_calls)
    if (layout) {
        layout = static_cast<const uint8_t *>(ptrauth_auth_data(
            layout, ptrauth_key_process_independent_data,
            ptrauth_blend_discriminator(slot, 0x8b65)));
    }
#endif
    // The pinned native implementation traps for the tagged representation.
    if (reinterpret_cast<uintptr_t>(layout) & 1) __builtin_trap();
    auto relativeSlot = layout + 24; // two-word header, then the first opcode.
    int32_t offset;
    std::memcpy(&offset, relativeSlot, sizeof(offset));
    auto callbackAddress = reinterpret_cast<uintptr_t>(relativeSlot) +
                           static_cast<intptr_t>(offset);
    GetEnumTag callback;
#if __has_feature(ptrauth_calls)
    callback = reinterpret_cast<GetEnumTag>(ptrauth_sign_unauthenticated(
        reinterpret_cast<void *>(callbackAddress),
        ptrauth_key_function_pointer, 0));
#else
    callback = reinterpret_cast<GetEnumTag>(callbackAddress);
#endif
    return callback(static_cast<const uint8_t *>(value));
}
