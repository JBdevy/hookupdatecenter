#include "AllocationAudit.h"
#include <cstdlib>
#include <new>
#if defined(_WIN32)
#include <malloc.h>
#endif

namespace catlive::native::audio::testing {
thread_local bool auditingCallbackAllocations = false;
std::atomic<std::uint64_t> callbackAllocations { 0 }, callbackDeallocations { 0 };
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
}
namespace {
using namespace catlive::native::audio::testing;
void allocation() noexcept
{
    if (auditingCallbackAllocations) callbackAllocations.fetch_add(1, std::memory_order_relaxed);
}
void deallocation() noexcept
{
    if (auditingCallbackAllocations) callbackDeallocations.fetch_add(1, std::memory_order_relaxed);
}
void* allocate(std::size_t size)
{
    allocation();
    if (auto* value = std::malloc(size ? size : 1)) return value;
    throw std::bad_alloc();
}
void* allocateAligned(std::size_t size, std::size_t alignment)
{
    allocation();
#if defined(_WIN32)
    if (auto* value = _aligned_malloc(size ? size : 1, alignment)) return value;
#else
    void* value = nullptr;
    if (posix_memalign(&value, alignment, size ? size : 1) == 0) return value;
#endif
    throw std::bad_alloc();
}
void releaseAligned(void* value) noexcept
{
    deallocation();
#if defined(_WIN32)
    _aligned_free(value);
#else
    std::free(value);
#endif
}
}
void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void operator delete(void* value) noexcept { deallocation(); std::free(value); }
void operator delete[](void* value) noexcept { deallocation(); std::free(value); }
void operator delete(void* value, std::size_t) noexcept { deallocation(); std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { deallocation(); std::free(value); }
void* operator new(std::size_t size, std::align_val_t alignment) { return allocateAligned(size, static_cast<std::size_t>(alignment)); }
void* operator new[](std::size_t size, std::align_val_t alignment) { return allocateAligned(size, static_cast<std::size_t>(alignment)); }
void operator delete(void* value, std::align_val_t) noexcept { releaseAligned(value); }
void operator delete[](void* value, std::align_val_t) noexcept { releaseAligned(value); }
void operator delete(void* value, std::size_t, std::align_val_t) noexcept { releaseAligned(value); }
void operator delete[](void* value, std::size_t, std::align_val_t) noexcept { releaseAligned(value); }
