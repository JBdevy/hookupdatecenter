#pragma once
#include <windows.h>
#include <avrt.h>

namespace catlive {
// ASIO invokes us on a driver-owned thread. Register that actual thread, never
// the UI/preparation thread and never the whole process as realtime. WASAPI
// already registers its own Pro Audio task in JUCE.
class AudioThreadScheduling final {
public:
    struct Status {
        DWORD threadID = 0, registrationError = 0, priorityError = 0;
        int priority = THREAD_PRIORITY_NORMAL;
        bool mmcss = false, critical = false, fallback = false;
    };
    AudioThreadScheduling() noexcept {
        state.threadID = GetCurrentThreadId();
        originalPriority = GetThreadPriority(GetCurrentThread());
        DWORD task = 0;
        handle = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
        state.mmcss = handle != nullptr;
        if (handle) {
            state.critical = AvSetMmThreadPriority(handle, AVRT_PRIORITY_CRITICAL) != FALSE;
            if (!state.critical) state.priorityError = GetLastError();
        } else {
            state.registrationError = GetLastError();
            // MMCSS may be disabled by the machine policy. Retain a driver's
            // higher priority; otherwise request the highest normal level.
            if (originalPriority != THREAD_PRIORITY_ERROR_RETURN && originalPriority < THREAD_PRIORITY_HIGHEST)
                state.fallback = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST) != FALSE;
        }
        state.priority = GetThreadPriority(GetCurrentThread());
    }
    ~AudioThreadScheduling() noexcept {
        // Thread-local lifetime guarantees AvRevert runs on its owning thread.
        if (handle) AvRevertMmThreadCharacteristics(handle);
        if (state.fallback) SetThreadPriority(GetCurrentThread(), originalPriority);
    }
    AudioThreadScheduling(const AudioThreadScheduling&) = delete;
    AudioThreadScheduling& operator=(const AudioThreadScheduling&) = delete;
    const Status& status() const noexcept { return state; }
    static const Status& asioCallback() noexcept {
        // One registration per driver thread, shared by all project callbacks.
        // Subsequent audio blocks perform no AVRT calls, allocation or logging.
        thread_local AudioThreadScheduling scheduling;
        return scheduling.status();
    }
private:
    HANDLE handle = nullptr;
    int originalPriority = THREAD_PRIORITY_NORMAL;
    Status state;
};
}
