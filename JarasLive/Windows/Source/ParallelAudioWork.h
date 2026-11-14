#pragma once
#include "Common.h"
#include "AudioThreadScheduling.h"
#include <thread>

namespace catlive {
// Fixed workers and scratch buffers are created with the graph, never in render.
// Each task owns a different decoder/DSP history; summing/routing stays ordered
// on the callback. Idle workers sleep instead of polling or burning CPU.
class ParallelAudioWork final {
  public:
    using Function=void(*)(void *,size_t,AudioBuffer<float> &) noexcept;
    explicit ParallelAudioWork(unsigned helpers, bool realtime = true) {
        helpers=std::min(10u,helpers);
        scratch.setSize(2,131080);
        for(unsigned i=0;i<helpers;++i) {
            auto worker=std::make_unique<Worker>();
            worker->scratch.setSize(2,131080);
            worker->start=CreateEventW(nullptr,FALSE,FALSE,nullptr);
            worker->done=CreateEventW(nullptr,FALSE,FALSE,nullptr);
            if(!worker->start || !worker->done)throw std::runtime_error("Could not prepare audio workers");
            workers.push_back(std::move(worker));
        }
        try {
            for(auto &worker:workers)worker->thread=std::thread([this,w=worker.get(),realtime] {
                std::optional<AudioThreadScheduling> priority;
                if(realtime)priority.emplace();
                ScopedNoDenormals noDenormals;
                for(;;) {
                    WaitForSingleObject(w->start,INFINITE);
                    if(stopping.load(std::memory_order_acquire))return;
                    generation.load(std::memory_order_acquire);
                    execute(w->scratch);
                    w->complete.store(true,std::memory_order_release);
                    SetEvent(w->done);
                }
            });
        } catch(...) {stop();throw;}
    }
    ~ParallelAudioWork(){stop();}
    unsigned helperCount() const noexcept {return unsigned(workers.size());}
    void run(size_t amount,void *owner,Function work) noexcept {
        count=amount;context=owner;function=work;next.store(0,std::memory_order_relaxed);
        for(auto &worker:workers)worker->complete.store(false,std::memory_order_relaxed);
        generation.fetch_add(1,std::memory_order_release);
        for(auto &worker:workers)SetEvent(worker->start);
        execute(scratch);
        for(auto &worker:workers) {
            WaitForSingleObject(worker->done,INFINITE);
            // The acquire also publishes the task's PCM/DSP writes to C++.
            (void)worker->complete.load(std::memory_order_acquire);
        }
    }
  private:
    struct Worker {
        HANDLE start=nullptr,done=nullptr;
        std::thread thread;
        AudioBuffer<float> scratch;
        std::atomic<bool> complete{false};
        ~Worker(){if(start)CloseHandle(start);if(done)CloseHandle(done);}
    };
    std::vector<std::unique_ptr<Worker>> workers;
    AudioBuffer<float> scratch;
    std::atomic<bool> stopping{false};
    std::atomic<unsigned> generation{0};
    std::atomic<size_t> next{0};
    size_t count=0;void *context=nullptr;Function function=nullptr;
    void execute(AudioBuffer<float> &buffer) noexcept {
        for(;;){const auto i=next.fetch_add(1,std::memory_order_relaxed);if(i>=count)return;function(context,i,buffer);}
    }
    void stop() noexcept {
        stopping.store(true,std::memory_order_release);
        for(auto &worker:workers)SetEvent(worker->start);
        for(auto &worker:workers)if(worker->thread.joinable())worker->thread.join();
    }
};
}
