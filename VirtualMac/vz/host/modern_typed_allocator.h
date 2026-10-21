/*
 * Copyright (c) 2022 Apple Computer, Inc. All rights reserved.
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

#ifndef VZ_MODERN_TYPED_ALLOCATOR_H
#define VZ_MODERN_TYPED_ALLOCATOR_H
#include <stddef.h>
#include <stdint.h>
#include <malloc/malloc.h>
#ifdef __cplusplus
extern "C" {
#endif
#define VZ_TYPED_EXPORT __attribute__((visibility("default")))
VZ_TYPED_EXPORT void *VZTypedMalloc(size_t, uint64_t) __asm("_malloc_type_malloc");
VZ_TYPED_EXPORT void *VZTypedCalloc(size_t, size_t, uint64_t) __asm("_malloc_type_calloc");
VZ_TYPED_EXPORT void *VZTypedRealloc(void *, size_t, uint64_t) __asm("_malloc_type_realloc");
VZ_TYPED_EXPORT int VZTypedPosixMemalign(void **, size_t, size_t, uint64_t) __asm("_malloc_type_posix_memalign");
// Exact SDK public ABI: type_id is fourth, options fifth. No new zone layout.
VZ_TYPED_EXPORT void *VZTypedZoneWithOptions(malloc_zone_t *, size_t, size_t,
    uint64_t, malloc_zone_malloc_options_t) __asm("_malloc_type_zone_malloc_with_options");
#ifdef __cplusplus
}
#endif
#endif
