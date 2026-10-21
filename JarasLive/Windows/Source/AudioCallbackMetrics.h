#pragma once
#include "Common.h"
namespace catlive {
// Timing only: no logging, allocations or device/UI calls on the audio thread.
// Read on demand from the diagnostic snapshot, outside the device callback.
class AudioCallbackMetrics {
public:
    AudioCallbackMetrics() : profiling(SystemStats::getEnvironmentVariable("CATLIVE_AUDIO_DIAGNOSTICS", {}) == "1") {}
    class Detail {
    public:
        Detail(AudioCallbackMetrics& owner, size_t index) noexcept : metrics(owner), slot(index) {
            if (metrics.profiling) started=Time::getHighResolutionTicks();
        }
        ~Detail() noexcept { finish(); }
        void finish() noexcept {
            if (started == 0) return;
            const auto elapsed=Time::getHighResolutionTicks()-started;
            metrics.detailTicks[slot].fetch_add(elapsed,std::memory_order_relaxed);
            maximum(metrics.detailMaxTicks[slot],elapsed);
            started=0;
        }
    private:
        AudioCallbackMetrics& metrics;
        size_t slot;
        int64 started=0;
    };
    class RenderProfile {
    public:
        explicit RenderProfile(AudioCallbackMetrics &owner) noexcept : metrics(owner) {
            if (metrics.profiling) started = Time::getHighResolutionTicks();
        }
        void mark() noexcept {
            if (!metrics.profiling || stage >= 5) return;
            const auto now = Time::getHighResolutionTicks();
            metrics.stageTicks[size_t(stage)].fetch_add(now - started, std::memory_order_relaxed);
            maximum(metrics.stageMaxTicks[size_t(stage)], now - started);
            started = now; ++stage;
        }
        ~RenderProfile() noexcept { mark(); }
    private:
        AudioCallbackMetrics &metrics;
        int stage = 0;
        int64 started = 0;
    };
    class Scope {
    public:
        Scope(AudioCallbackMetrics& owner, int samples, double rate) noexcept
            : metrics(owner), started(Time::getHighResolutionTicks()),
              budget(rate > 0 ? int64(samples * (double)Time::getHighResolutionTicksPerSecond() / rate) : 0) {
            if (metrics.profiling) {
                cpuStarted = threadCPU();
                metrics.threadID.store(GetCurrentThreadId(), std::memory_order_relaxed);
                metrics.threadPriority.store(GetThreadPriority(GetCurrentThread()), std::memory_order_relaxed);
            }
            const auto previous = metrics.lastStart.exchange(started, std::memory_order_relaxed);
            const auto previousBudget = metrics.lastBudget.exchange(budget, std::memory_order_relaxed);
            if (previous > 0 && previousBudget > 0) {
                const auto late = std::max(int64(0), started - previous - previousBudget);
                maximum(metrics.maxLateTicks, late);
                if (late > std::max(previousBudget / 2, Time::getHighResolutionTicksPerSecond() / 1000))
                    metrics.lateCallbacks.fetch_add(1, std::memory_order_relaxed);
            }
            metrics.callbacks.fetch_add(1, std::memory_order_relaxed);
        }
        ~Scope() noexcept {
            const auto elapsed = Time::getHighResolutionTicks() - started;
            maximum(metrics.maxRenderTicks, elapsed);
            metrics.renderTicks.fetch_add(elapsed, std::memory_order_relaxed);
            if (metrics.profiling) metrics.cpuTicks.fetch_add(threadCPU() - cpuStarted, std::memory_order_relaxed);
            if (budget > 0 && elapsed > budget) metrics.overBudget.fetch_add(1, std::memory_order_relaxed);
        }
    private:
        AudioCallbackMetrics& metrics;
        int64 started, budget;
        uint64 cpuStarted = 0;
    };
    void deviceStarted() noexcept { starts.fetch_add(1); lastStart.store(0); lastBudget.store(0); }
    void deviceStopped() noexcept { stops.fetch_add(1); lastStart.store(0); }
    void renderedSegment() noexcept { segments.fetch_add(1, std::memory_order_relaxed); }
    var snapshot() const {
        auto result = object();
        const double ms = 1000. / Time::getHighResolutionTicksPerSecond();
        put(result, "callbacks", (int64)callbacks.load());
        put(result, "renderSegments", (int64)segments.load());
        put(result, "lateCallbacks", (int64)lateCallbacks.load());
        put(result, "overBudget", (int64)overBudget.load());
        put(result, "maxRenderMs", maxRenderTicks.load() * ms);
        put(result, "maxSchedulingDelayMs", maxLateTicks.load() * ms);
        put(result, "totalRenderMs", renderTicks.load() * ms);
        if (profiling) {
            put(result, "threadCPUMs", cpuTicks.load() / 10000.);
            put(result, "threadID", (int64)threadID.load());
            put(result, "threadPriority", threadPriority.load());
            auto stages = object();
            const char *names[]{"setup", "voices", "buses", "master", "clock"};
            for (size_t i=0;i<5;++i) {
                auto stage = object(); put(stage, "totalMs", stageTicks[i].load()*ms);
                put(stage, "maxMs", stageMaxTicks[i].load()*ms); put(stages, Identifier(names[i]), stage);
            }
            put(result, "renderStages", stages);
            auto details=object();
            const char* detailNames[]{"itemRead", "itemGain", "itemFX", "itemTraversal", "generators"};
            for(size_t i=0;i<5;++i){auto detail=object();put(detail,"totalMs",detailTicks[i].load()*ms);put(detail,"maxMs",detailMaxTicks[i].load()*ms);put(details,Identifier(detailNames[i]),detail);}
            put(result,"renderDetails",details);
        }
        put(result, "deviceStarts", (int64)starts.load());
        put(result, "deviceStops", (int64)stops.load());
        return result;
    }
private:
    static uint64 threadCPU() noexcept {
        FILETIME creation{}, exit{}, kernel{}, user{};
        if (!GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user)) return 0;
        return (uint64(kernel.dwHighDateTime)<<32) + kernel.dwLowDateTime +
               (uint64(user.dwHighDateTime)<<32) + user.dwLowDateTime;
    }
    static void maximum(std::atomic<int64>& value, int64 candidate) noexcept {
        auto current = value.load(std::memory_order_relaxed);
        while (current < candidate && !value.compare_exchange_weak(current, candidate, std::memory_order_relaxed)) {}
    }
    std::atomic<int64> lastStart{0}, lastBudget{0}, maxRenderTicks{0}, maxLateTicks{0};
    std::atomic<uint64> callbacks{0}, lateCallbacks{0}, overBudget{0}, starts{0}, stops{0}, segments{0};
    const bool profiling;
    std::atomic<int64> renderTicks{0};
    std::atomic<uint64> cpuTicks{0}, threadID{0};
    std::atomic<int> threadPriority{0};
    std::array<std::atomic<int64>,5> stageTicks{}, stageMaxTicks{};
    std::array<std::atomic<int64>,5> detailTicks{}, detailMaxTicks{};
};
}
