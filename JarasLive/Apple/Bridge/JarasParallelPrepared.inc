// Prepared source DSP only. The device callback still consumes its PCM ring;
// helpers prepare later sources while the graph mixes earlier ones. Each source
// waits only for its own DSP, then the graph joins all jobs before ending a pull.
#include <optional>
#include <mach/mach.h>
#include <pthread.h>

namespace {
struct PreparedRenderSource {
    virtual ~PreparedRenderSource() = default;
    virtual bool prepareParallel(unsigned frames, double rate, uint64_t host) = 0;
    virtual void executeParallel() = 0;
    virtual void finishParallel() = 0;
};

struct PreparedRenderSources {
    using Sources = std::vector<std::shared_ptr<PreparedRenderSource>>;
    catlive::audio::SingleReaderSlots<Sources, 1> snapshots;
    std::mutex control;
    Sources sources;
    std::optional<decltype(snapshots)::Lease> activeLease;
    unsigned activeCount = 0;
    std::array<PreparedRenderSource *, 4096> jobs{};
    std::array<semaphore_t, 3> wakes{};
    semaphore_t done = SEMAPHORE_NULL;
    std::vector<std::thread> workers;
    std::atomic<unsigned> next{0}, count{0}, finished{0};
    std::atomic<bool> closing{false};
    bool enabled = false;

    PreparedRenderSources() {
#if TARGET_OS_OSX
        const char *option = getenv("CATLIVE_PARALLEL_STRETCH");
        enabled = option && strcmp(option, "1") == 0;
#endif
        if (!enabled) return;
        semaphore_create(mach_task_self(), &done, SYNC_POLICY_FIFO, 0);
        const char *threadOption = getenv("CATLIVE_STRETCH_THREADS");
        const unsigned total = std::clamp(threadOption ? unsigned(std::max(1, atoi(threadOption)))
                                                       : std::thread::hardware_concurrency(), 1u, 4u);
        for (unsigned n = 0; n + 1 < total; ++n) {
            semaphore_create(mach_task_self(), &wakes[n], SYNC_POLICY_FIFO, 0);
            workers.emplace_back([this, n] {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
                while (true) {
                    semaphore_wait(wakes[n]);
                    if (closing.load(std::memory_order_acquire)) return;
                    work();
                    finished.fetch_add(1, std::memory_order_release);
                    semaphore_signal(done);
                }
            });
        }
    }
    ~PreparedRenderSources() {
        finish();
        closing.store(true, std::memory_order_release);
        for (size_t n = 0; n < workers.size(); ++n) semaphore_signal(wakes[n]);
        for (auto &worker : workers) worker.join();
        for (size_t n = 0; n < workers.size(); ++n) semaphore_destroy(mach_task_self(), wakes[n]);
        if (done != SEMAPHORE_NULL) semaphore_destroy(mach_task_self(), done);
    }
    void add(std::shared_ptr<PreparedRenderSource> source) {
        if (!enabled) return;
        std::lock_guard<std::mutex> lock(control);
        sources.push_back(std::move(source));
        snapshots.publish(0, std::make_unique<Sources>(sources));
    }
    void remove(PreparedRenderSource *source) {
        if (!enabled) return;
        std::lock_guard<std::mutex> lock(control);
        sources.erase(std::remove_if(sources.begin(), sources.end(), [source](const auto &value) {
            return value.get() == source;
        }), sources.end());
        snapshots.publish(0, std::make_unique<Sources>(sources));
    }
    void work() {
        jaras::ScopedAudioDenormals denormals;
        const auto size = count.load(std::memory_order_acquire);
        for (auto index = next.fetch_add(1, std::memory_order_relaxed); index < size;
             index = next.fetch_add(1, std::memory_order_relaxed)) jobs[index]->executeParallel();
    }
    void prepare(unsigned frames) {
        // Manual offline rendering and the iPad callback do not join workers.
        if (!enabled || !jaras::realtimeClock.host || jaras::realtimeClock.rate <= 0) return;
        assert(!activeCount && !activeLease);
        activeLease.emplace(snapshots);
        const auto *current = activeLease->get(0);
        if (!current) { activeLease.reset(); return; }
        unsigned size = 0;
        for (const auto &source : *current) {
            if (size == jobs.size()) break;
            if (!source->prepareParallel(frames, jaras::realtimeClock.rate, jaras::realtimeClock.host)) continue;
            jobs[size++] = source.get();
        }
        if (size >= 8) {
            next.store(0, std::memory_order_relaxed); finished.store(0, std::memory_order_relaxed);
            count.store(size, std::memory_order_release);
            for (size_t n = 0; n < workers.size(); ++n) semaphore_signal(wakes[n]);
            activeCount=size;
            return;
        }
        for (unsigned n = 0; n < size; ++n) jobs[n]->finishParallel();
        activeLease.reset();
    }
    void finish() {
        if(activeCount) {
            for (size_t n=0;n<workers.size();++n) semaphore_wait(done);
            assert(finished.load(std::memory_order_acquire)==workers.size());
            for (unsigned n=0;n<activeCount;++n) jobs[n]->finishParallel();
            activeCount=0;
        }
        activeLease.reset();
    }
};
}
