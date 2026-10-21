// Eight app-private CPU runtime definitions for macOS27 consumers.
// LLVM65a82906, Apache-2.0 WITH LLVM-exception; SDK27.1 class ABI.
// No system replacement or CPU capability advertisement.
// App-private narrow ABI backports. Old ModernRuntimeCompat remains untouched.
// Hash/expected key definitions follow LLVM65a82906 upstream functional.cpp and
// expected.cpp; SDK27.1 headers supply the exact class/mangled function ABI.
// Atomic global table follows upstream monitor->sequence->wait->notify semantics
// using older pthread primitives. This provider's monitor/wait/notify must travel
// together; its private table must not be mixed with another provider's table.
#include <__functional/hash.h>
#include <__expected/bad_expected_access.h>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <pthread.h>
#include <limits>

extern "C" void *VZMallocTypeCalloc(size_t,size_t,uint64_t) __asm("_malloc_type_calloc");
extern "C" void *VZMallocTypeCalloc(size_t count,size_t size,uint64_t descriptor) {
    (void)descriptor;
    // Apple's SDK malloc_type_calloc_backdeploy uses this old-calloc fallback.
    // Leave overflow, zero-size, errno, allocation and free ownership to calloc.
    auto original=std::calloc;
    return original(count,size);
}

_LIBCPP_BEGIN_NAMESPACE_STD
size_t __hash_memory(_LIBCPP_NOESCAPE const void *data,size_t size) noexcept {
    return __murmur2_or_cityhash<size_t>()(data,size);
}
const char *bad_expected_access<void>::what() const noexcept {
    return "bad access to std::expected";
}
_LIBCPP_END_NAMESPACE_STD

static_assert(sizeof(void*)==8 && sizeof(size_t)==8 && sizeof(long long)==8,
    "Audited LP64 native-v2 ABI only");
static_assert(sizeof(std::bad_expected_access<void>)==sizeof(std::exception),
    "bad_expected_access<void> has only its inherited exception layout");
namespace {
struct alignas(64) Bucket {
    pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
    uint64_t sequence=0;
    unsigned waiters=0;
};
Bucket buckets[256];
Bucket& Entry(const void *address) noexcept {
    // Same pointer CityHash and 256-bucket selection as upstream atomic.cpp.
    return buckets[std::__murmur2_or_cityhash<size_t>()(&address,sizeof(address))&255];
}
void Check(int result) noexcept { if(result) std::abort(); }
void Lock(Bucket& b) noexcept { Check(pthread_mutex_lock(&b.mutex)); }
void Unlock(Bucket& b) noexcept { Check(pthread_mutex_unlock(&b.mutex)); }
long long Ticket(uint64_t value) noexcept {
    long long result; std::memcpy(&result,&value,sizeof(result));return result;
}
uint64_t Bits(long long value) noexcept {
    uint64_t result;std::memcpy(&result,&value,sizeof(result));return result;
}
}
_LIBCPP_BEGIN_NAMESPACE_STD
long long __atomic_monitor_global(const void *address) noexcept {
    Bucket& b=Entry(address);Lock(b);long long result=Ticket(b.sequence);Unlock(b);return result;
}
void __atomic_wait_global_table(const void *address,long long monitor) noexcept {
    Bucket& b=Entry(address);Lock(b);
    ++b.waiters;
    // Notify-before-wait cannot be lost: the monitor ticket is checked under
    // the exact same mutex used by notification. Bucket collisions may wake
    // unrelated callers; native header predicate loops permit such wakeups.
    while(b.sequence==Bits(monitor)) Check(pthread_cond_wait(&b.condition,&b.mutex));
    --b.waiters;Unlock(b);
}
void __atomic_notify_all_global_table(const void *address) noexcept {
    Bucket& b=Entry(address);Lock(b);++b.sequence;
    Check(pthread_cond_broadcast(&b.condition));Unlock(b);
}
_LIBCPP_END_NAMESPACE_STD

// LLVM65a82906 exception_pointer_cxxabi.ipp factory only.
// Apache-2.0 WITH LLVM-exception; retain the genuine native C++ ABI exception.
#include <exception>
#include <cxxabi.h>
static_assert(sizeof(std::exception_ptr)==sizeof(void*),"audited LP64 class size");
namespace std {
exception_ptr exception_ptr::__from_native_exception_pointer(void *exception) noexcept {
    exception_ptr pointer;
    pointer.__ptr_=exception;
    __cxxabiv1::__cxa_increment_exception_refcount(pointer.__ptr_);
    return pointer;
}
}
