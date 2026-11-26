#pragma once
#include <atomic>
#include <cstdint>

// Diagnostic executable only. Never link the replacement allocation functions
// into the shipping application or the native device library.
namespace catlive::native::audio::testing {
extern thread_local bool auditingCallbackAllocations;
extern std::atomic<std::uint64_t> callbackAllocations, callbackDeallocations;
struct AllocationAuditScope {
    bool previous = auditingCallbackAllocations;
    AllocationAuditScope() noexcept { auditingCallbackAllocations = true; }
    ~AllocationAuditScope() { auditingCallbackAllocations = previous; }
};
}
