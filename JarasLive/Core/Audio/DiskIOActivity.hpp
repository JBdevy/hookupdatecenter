#pragma once

#include <chrono>
#include <cstdint>
#include <mutex>

namespace catlive::audio {

// Count time spent inside audio reads/writes, including overlapping operations
// only once. Call this from the media workers, never the device callback.
class DiskIOActivity {
public:
    using Clock = std::chrono::steady_clock;

    void begin() {
        const std::lock_guard<std::mutex> lock(mutex);
        if (active++ == 0) started = Clock::now();
    }

    void end() {
        const std::lock_guard<std::mutex> lock(mutex);
        if (--active == 0) occupied += Clock::now() - started;
    }

    class Operation {
    public:
        explicit Operation(DiskIOActivity& meter) : meter(meter) { meter.begin(); }
        ~Operation() { meter.end(); }
        Operation(const Operation&) = delete;
        Operation& operator=(const Operation&) = delete;
    private:
        DiskIOActivity& meter;
    };

    // The display skips a contended sample so the UI never waits for a worker.
    std::int64_t occupiedNanoseconds() {
        const std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock) return -1;
        const auto total = active == 0 ? occupied : occupied + (Clock::now() - started);
        return std::chrono::duration_cast<std::chrono::nanoseconds>(total).count();
    }

private:
    std::mutex mutex;
    unsigned active = 0;
    Clock::time_point started{};
    Clock::duration occupied{};
};

inline DiskIOActivity diskIOActivity;
}
