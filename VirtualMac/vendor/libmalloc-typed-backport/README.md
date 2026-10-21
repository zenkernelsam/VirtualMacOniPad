This directory retains Apple libmalloc source/SDK notices and APSL-2.0 for the
private typed-allocator fallback adaptation. The pinned public source commit is
c49dafa25f1efe8607701ae6014a663ad2ee437f (libmalloc812.100.31). `provenance.json`
records exact originals, source ranges, SDK differences and actual test evidence.

Project sources are `vz/host/modern_typed_allocator_compat.c` and
`vz/host/modern_typed_allocator.h`. Their tested implementation bodies remain
byte-identical to the frozen original; only source notices were added.

The development builder defines VZ_TYPED_ALLOCATOR_INCREMENTAL_ONLY=1 and exports
only malloc_type_posix_memalign and malloc_type_zone_malloc_with_options. It
never replaces the stock allocator or automatically binds general consumers.

Actual iPad PID72688 tested the original two-export library:25 cases/137 checks,
20 real allocations and20 native-owner frees. A new project library build is
not thereby installed or executed. The three other source fallback functions
remain conditional and require their separate native verification before any
full-five claim. No Swift27/VMM27/Apple8/GPU success follows from these tests.
