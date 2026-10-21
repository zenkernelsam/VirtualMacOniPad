// Runtime backports for the experimental macOS 27 PVG port on iPadOS 16.
// Typed allocation descriptors are advisory: Apple's malloc/_malloc.h uses
// malloc/realloc as its own back-deployment fallback. C++ new retains its normal
// throwing allocation semantics. Build with -fno-typed-cxx-new-delete so these
// forwarding calls cannot be rewritten into calls to themselves.
#import <Foundation/Foundation.h>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <typeinfo>

extern "C" void *VZMallocTypeMalloc(size_t, uint64_t)
    __asm("_malloc_type_malloc");
extern "C" void *VZMallocTypeRealloc(void *, size_t, uint64_t)
    __asm("_malloc_type_realloc");
extern "C" void *VZMallocTypeMalloc(size_t size, uint64_t descriptor) {
    (void)descriptor;
    return std::malloc(size);
}
extern "C" void *VZMallocTypeRealloc(void *pointer, size_t size,
                                    uint64_t descriptor) {
    (void)descriptor;
    return std::realloc(pointer, size);
}

// This opaque 64-bit enum is the signature in Apple's global_typed_new_delete.h.
namespace std { enum class __type_descriptor_t : unsigned long long; }
void *operator new(size_t size, std::__type_descriptor_t) {
    return ::operator new(size);
}
void operator delete(void *pointer, std::__type_descriptor_t) noexcept {
    ::operator delete(pointer);
}
void *operator new[](size_t size, std::__type_descriptor_t) {
    return ::operator new[](size);
}
void operator delete[](void *pointer, std::__type_descriptor_t) noexcept {
    ::operator delete[](pointer);
}

// libc++abi's class_type_info and si_class_type_info own no destructor-managed
// members. Their complete destructors reduce to the public type_info destructor.
// Keep the OS's RTTI vtables and type identities; do not introduce a second ABI.
extern "C" void VZClassTypeInfoD1(void *)
    __asm("__ZN10__cxxabiv117__class_type_infoD1Ev");
extern "C" void VZSIClassTypeInfoD1(void *)
    __asm("__ZN10__cxxabiv120__si_class_type_infoD1Ev");
extern "C" void VZClassTypeInfoD1(void *object) {
    static_cast<std::type_info *>(object)->std::type_info::~type_info();
}
extern "C" void VZSIClassTypeInfoD1(void *object) {
    static_cast<std::type_info *>(object)->std::type_info::~type_info();
}

typedef struct MTLAddressRange {
    uint64_t address;
    uint64_t length;
} MTLAddressRange;

// The class is absent on iPadOS 16.1. Its storage layout and method signatures
// were measured on the source macOS 27 runtime. It stores real address ranges;
// it does not manufacture resource addresses or change GPU capabilities.
#ifdef VZ_RUNTIME_COMPAT_NATIVE_TEST
#define MTLResourceAddressRangeArray VZTestResourceAddressRangeArray
#endif
@interface MTLResourceAddressRangeArray : NSObject <NSCopying> {
    NSUInteger _count;
    MTLAddressRange *_ranges;
}
- (instancetype)initWithCount:(NSUInteger)count;
- (instancetype)initWithRanges:(const MTLAddressRange *)ranges
                         count:(NSUInteger)count;
- (MTLAddressRange *)ranges;
- (NSUInteger)count;
@end

@implementation MTLResourceAddressRangeArray
- (instancetype)initWithCount:(NSUInteger)count {
    self = [super init];
    if (!self) return nil;
    if (count > SIZE_MAX / sizeof(*_ranges)) {
        [self release];
        return nil;
    }
    _ranges = count ? (MTLAddressRange *)calloc(count, sizeof(*_ranges)) : NULL;
    if (count && !_ranges) {
        [self release];
        return nil;
    }
    _count = count;
    return self;
}
- (instancetype)initWithRanges:(const MTLAddressRange *)ranges
                         count:(NSUInteger)count {
    if (count && !ranges) { [self release]; return nil; }
    self = [self initWithCount:count];
    if (self && count) memcpy(_ranges, ranges, count * sizeof(*_ranges));
    return self;
}
- (MTLAddressRange *)ranges { return _ranges; }
- (NSUInteger)count { return _count; }
- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithRanges:_ranges count:_count];
}
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[MTLResourceAddressRangeArray class]]) return NO;
    return _count == [other count] && (!_count ||
        memcmp(_ranges, [other ranges], _count * sizeof(*_ranges)) == 0);
}
- (NSUInteger)hash {
    NSUInteger value = _count;
    for (NSUInteger i = 0; i < _count; ++i) {
        value = value * 31 + _ranges[i].address;
        value = value * 31 + _ranges[i].length;
    }
    return value;
}
- (NSString *)formattedDescription:(NSUInteger)indent {
    NSMutableString *text = [NSMutableString stringWithFormat:@"%*s<%@: %p; count=%lu>",
        (int)MIN(indent, (NSUInteger)128), "", NSStringFromClass([self class]),
        self, (unsigned long)_count];
    for (NSUInteger i = 0; i < _count; ++i)
        [text appendFormat:@"\n  { address=0x%llx, length=0x%llx }",
            (unsigned long long)_ranges[i].address,
            (unsigned long long)_ranges[i].length];
    return text;
}
- (NSString *)description { return [self formattedDescription:0]; }
- (void)dealloc { free(_ranges); [super dealloc]; }
@end
