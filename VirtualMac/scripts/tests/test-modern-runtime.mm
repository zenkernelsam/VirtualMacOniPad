#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <stdio.h>

// Compare the backported LLVM conversions against the OS's complete libc++.
// Exercise all nine overloads, boundaries, precision, and too-small buffers.
template<class T> static bool Check(void *lib, const char *letter, T value,
                                    size_t capacity, std::chars_format format,
                                    int precision, unsigned overload) {
    char symbol[128];
    snprintf(symbol, sizeof(symbol), "_ZNSt3__18to_charsEPcS0_%s%s", letter,
        overload == 0 ? "" : overload == 1 ? "NS_12chars_formatE" : "NS_12chars_formatEi");
    void *address = dlsym(lib, symbol);
    if (!address) { fprintf(stderr, "missing %s\n", symbol); return false; }
    char expected[1024], actual[1024];
    std::to_chars_result a, b;
    if (overload == 0) {
        a = std::to_chars(expected, expected + capacity, value);
        b = ((std::to_chars_result (*)(char*, char*, T))address)(actual, actual + capacity, value);
    } else if (overload == 1) {
        a = std::to_chars(expected, expected + capacity, value, format);
        b = ((std::to_chars_result (*)(char*, char*, T, std::chars_format))address)(actual, actual + capacity, value, format);
    } else {
        a = std::to_chars(expected, expected + capacity, value, format, precision);
        b = ((std::to_chars_result (*)(char*, char*, T, std::chars_format, int))address)(actual, actual + capacity, value, format, precision);
    }
    bool ok = a.ec == b.ec && (a.ptr - expected) == (b.ptr - actual) &&
        (a.ec != std::errc{} || memcmp(expected, actual, a.ptr - expected) == 0);
    if (!ok) fprintf(stderr, "conversion mismatch %s value=%La capacity=%zu format=%d precision=%d\n",
        symbol, (long double)value, capacity, (int)format, precision);
    return ok;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 3; }
    auto allocateArray = (void *(*)(size_t, uint64_t))dlsym(lib, "_ZnamSt19__type_descriptor_t");
    auto deleteArray = (void (*)(void *, uint64_t))dlsym(lib, "_ZdaPvSt19__type_descriptor_t");
    if (!allocateArray || !deleteArray) return 6;
    unsigned char *array = (unsigned char *)allocateArray(4096, 0x12345678);
    if (!array) return 6;
    memset(array, 0x5a, 4096);
    if (array[0] != 0x5a || array[4095] != 0x5a) return 6;
    deleteArray(array, 0x12345678);
    uint64_t rng = 0xa2e71cf001,
             checks = 0;
    std::chars_format formats[] = {std::chars_format::general, std::chars_format::fixed,
        std::chars_format::scientific, std::chars_format::hex};
    for (unsigned i = 0; i < 6000; ++i) {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        double value;
        memcpy(&value, &rng, sizeof(value));
        if (i == 0) value = 0;
        if (i == 1) value = -0.;
        if (i == 2) value = std::numeric_limits<double>::infinity();
        if (i == 3) value = -std::numeric_limits<double>::infinity();
        if (i == 4) value = std::numeric_limits<double>::denorm_min();
        if (i == 5) value = std::numeric_limits<double>::max();
        size_t capacity = i % 7 == 0 ? i % 17 : 1024;
        for (unsigned overload = 0; overload < 3; ++overload) {
            auto format = formats[(i / 3) % 4];
            int precision = (int)(i % 25);
            if (!Check(lib, "d", value, capacity, format, precision, overload) ||
                !Check(lib, "f", (float)value, capacity, format, precision, overload) ||
                !Check(lib, "e", (long double)value, capacity, format, precision, overload)) return 4;
            checks += 3;
        }
    }
    @autoreleasepool {
        Class cls = NSClassFromString(@"VZTestResourceAddressRangeArray");
        struct { uint64_t address, length; } input[] = {{0x123456789abc, 0x4000}, {0x98760000, 0x8000}};
        id object = ((id (*)(id, SEL, const void *, NSUInteger))objc_msgSend)([cls alloc],
            sel_registerName("initWithRanges:count:"), input, 2);
        id copy = [object copy];
        void *stored = ((void *(*)(id, SEL))objc_msgSend)(object, sel_registerName("ranges"));
        if (!object || !copy || stored == input || memcmp(stored, input, sizeof(input)) ||
            ![object isEqual:copy] || [object hash] != [copy hash]) return 5;
        [copy release]; [object release];
    }
    printf("PASS: %llu floating conversions against native libc++; range-array ownership/copy; typed array allocation/deletion\n",
        (unsigned long long)checks);
    return 0;
}
