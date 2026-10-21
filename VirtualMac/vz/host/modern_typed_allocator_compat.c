/*
 * Copyright (c) 1999, 2000, 2003, 2005, 2008, 2012 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

// Modified/adapted 2026-10-04 for VirtualMac: private legacy-allocator fallback.
// Portions Copyright (c) 2022 Apple Computer, Inc. All rights reserved.
// Source for this adaptation is available under APSL-2.0 in this project,
// with original notices/source in vendor/libmalloc-typed-backport/upstream.
// The previously tested implementation body below is preserved unchanged.

// App-private allocator ABI candidate; no system/stock allocator replacement.
// First four wrappers follow Apple's genuine SDK backdeployment branches.
// Zone options follow the non-MTE old-zone fallback in Apple libmalloc/malloc.c
// _malloc_zone_malloc_with_options_outlined. API names are aliased to prevent
// compiler typed-memory rewriting into this provider. Link only named consumers.
#include "modern_typed_allocator.h"
#include <string.h>

_Static_assert(sizeof(void *) == 8 && sizeof(size_t) == 8 && sizeof(uint64_t) == 8,
    "Only audited Darwin LP64 ABI");
_Static_assert(sizeof(malloc_type_id_t) == 8 && sizeof(malloc_zone_malloc_options_t) == 8,
    "Exact SDK type-id/options ABI");

// Stable public old APIs. These spellings are not recognized malloc builtins.
extern void *VZOriginalMalloc(size_t) __asm("_malloc");
extern void *VZOriginalCalloc(size_t, size_t) __asm("_calloc");
extern void *VZOriginalRealloc(void *, size_t) __asm("_realloc");
extern int VZOriginalPosixMemalign(void **, size_t, size_t) __asm("_posix_memalign");
extern malloc_zone_t *VZOriginalDefaultZone(void) __asm("_malloc_default_zone");
extern void *VZOriginalZoneMalloc(malloc_zone_t *, size_t) __asm("_malloc_zone_malloc");
extern void *VZOriginalZoneCalloc(malloc_zone_t *, size_t, size_t) __asm("_malloc_zone_calloc");
extern void *VZOriginalZoneMemalign(malloc_zone_t *, size_t, size_t) __asm("_malloc_zone_memalign");
extern void VZOriginalZoneFree(malloc_zone_t *, void *) __asm("_malloc_zone_free");

#ifndef VZ_TYPED_ALLOCATOR_INCREMENTAL_ONLY
void *VZTypedMalloc(size_t size, uint64_t type_id) {
    (void)type_id;
    return VZOriginalMalloc(size);
}
void *VZTypedCalloc(size_t count, size_t size, uint64_t type_id) {
    (void)type_id;
    return VZOriginalCalloc(count, size);
}
void *VZTypedRealloc(void *pointer, size_t size, uint64_t type_id) {
    (void)type_id;
    return VZOriginalRealloc(pointer, size);
}
#endif
int VZTypedPosixMemalign(void **memptr, size_t alignment, size_t size, uint64_t type_id) {
    (void)type_id;
    return VZOriginalPosixMemalign(memptr, alignment, size);
}
void *VZTypedZoneWithOptions(malloc_zone_t *zone, size_t alignment, size_t size,
                           uint64_t type_id, malloc_zone_malloc_options_t options) {
    (void)type_id;
    // Official >=26.1 default8 accepts a nonmultiple; explicit alignment follows
    // the original public libmalloc power-of-two/multiple test. align0 follows
    // the actual libmalloc default-allocation branch, although public docs
    // recommend a nonzero alignment. No resizing or hidden padding is applied.
    if (alignment != MALLOC_ZONE_MALLOC_DEFAULT_ALIGN && alignment != 0 &&
        ((alignment & (alignment - 1)) != 0 || (size & (alignment - 1)) != 0)) {
        return NULL;
    }
    const uint64_t known = MALLOC_ZONE_MALLOC_OPTION_CLEAR |
        MALLOC_ZONE_MALLOC_OPTION_CANONICAL_TAG;
    // Apple's old-zone fallback traps for unknown options. Preserve this error
    // contract rather than accepting unimplemented future requests.
    if ((uint64_t)options & ~known) __builtin_trap();
    if (!zone) zone = VZOriginalDefaultZone();
    void *result;
    if (alignment > MALLOC_ZONE_MALLOC_DEFAULT_ALIGN) {
        result = VZOriginalZoneMemalign(zone, alignment, size);
        if (result && ((uint64_t)options & MALLOC_ZONE_MALLOC_OPTION_CLEAR))
            memset(result, 0, size);
    } else if ((uint64_t)options & MALLOC_ZONE_MALLOC_OPTION_CLEAR) {
        result = VZOriginalZoneCalloc(zone, 1, size);
    } else {
        result = VZOriginalZoneMalloc(zone, size);
    }
    // This backport implements no modern allocator MTE/TSD option interface.
    // A canonical request is satisfied only by a genuine untagged allocation.
    // Never strip a tag or alter thread/kernel flags. If a custom zone returns
    // a tagged pointer, release it through its real owner and report failure.
    if (result && ((uint64_t)options & MALLOC_ZONE_MALLOC_OPTION_CANONICAL_TAG) &&
        ((uintptr_t)result >> 56) != 0) {
        VZOriginalZoneFree(zone, result);
        return NULL;
    }
    return result;
}
