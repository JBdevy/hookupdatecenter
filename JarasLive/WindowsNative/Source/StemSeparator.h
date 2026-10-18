#pragma once
#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
namespace catlive::native::stem {
inline constexpr const char *modelSHA = "34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd";
inline constexpr const char *effectName = "CatStemSeparation 5";
struct Mix {
    bool enabled = false;
    std::array<float,5> gains{{1,1,1,1,1}};
    unsigned muteMask = 0, soloMask = 0;
};
struct Status {
    std::string state, error;
    bool ready = false, workerRunning = false;
    unsigned latencyFrames = 0;
    uint64_t underruns = 0, overruns = 0;
};
struct Paths {
    std::filesystem::path python, worker, model;
    static Paths bundled();
    bool available() const;
};
class Processor {
public:
    Processor(Paths, unsigned sampleRate, bool offline, bool prewarm = true);
    ~Processor();
    Processor(const Processor&) = delete;
    Processor &operator=(const Processor&) = delete;
    void configure(const Mix &) noexcept;
    // Called only on audio/offline render thread. Realtime never waits/allocates.
    void process(float *left,float *right,unsigned count,double seconds,bool playing) noexcept;
    unsigned latency() const noexcept;
    unsigned availableLatency() const noexcept;
    void activate(bool force=false) noexcept;
    bool pending()const noexcept;
    void reset()noexcept;
    Status status() const;
    bool isOffline() const noexcept;
    unsigned sampleRate() const noexcept;
    void waitReady(); // offline export/control worker only
private:
    struct Impl;
    std::shared_ptr<Impl> impl;
};
} // namespace catlive::native::stem
