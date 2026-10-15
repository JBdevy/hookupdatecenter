#pragma once
#include "Common.h"
namespace catlive {
// A timeline can reference thousands of files without keeping every file open
// or allocating read-ahead buffers for songs that are not playing. Disk access
// and cache retirement run on the read-ahead thread, never the device callback.
class StreamingReader final : public AudioFormatReader, private TimeSliceClient {
  public:
    StreamingReader(const File& path, const AudioFormatReader& metadata,
                    AudioFormatManager& manager, TimeSliceThread& worker)
        : AudioFormatReader(nullptr, metadata.getFormatName()), file(path), formats(manager), thread(worker) {
        sampleRate = metadata.sampleRate; lengthInSamples = metadata.lengthInSamples;
        numChannels = metadata.numChannels; bitsPerSample = 32; usesFloatingPointData = true;
        thread.addTimeSliceClient(this);
    }
    ~StreamingReader() override { thread.removeTimeSliceClient(this); }
    void setOffline(bool value) { offline.store(value); }
    void request(int64 position) noexcept {
        requested.store(jlimit(int64(0), std::max(int64(0), lengthInSamples - 1), position));
        lastDemand.store(Time::getMillisecondCounter());
    }
    bool ready(int64 position) {
        auto current = std::atomic_load(&reader);
        return current && probeAt(*current, position);
    }
    bool cached() const noexcept { return resident.load(); }
    std::atomic<uint64> cacheMisses{0}, inactiveMisses{0};
    bool readSamples(int* const* destination, int channels, int offset, int64 at, int count) override {
        request(at);
        const bool exporting = offline.load();
        if (exporting) {
            // Export may wait for disk; it must never lose a block merely
            // because the cache worker holds the metadata lock.
            const ScopedLock guard(lock);
            ensureReader();
        }
        // File opening and retirement never hold a lock needed by this read.
        // Retired delegates stay owned by the worker until every read finishes,
        // so releasing this local reference cannot destroy a decoder here.
        auto current = std::atomic_load(&reader);
        if (current) {
            current->setReadTimeout(exporting ? 5000 : 0);
            const bool ok = current->readSamples(destination, channels, offset, at, count);
            if (!ok) ++cacheMisses;
            return ok;
        }
        ++inactiveMisses;
        for (int c = 0; c < channels; ++c)
            if (destination[c]) FloatVectorOperations::clear(reinterpret_cast<float*>(destination[c]) + offset, count);
        return false;
    }
  private:
    File file;
    AudioFormatManager& formats;
    TimeSliceThread& thread;
    CriticalSection lock;
    std::shared_ptr<BufferingAudioReader> reader;
    std::vector<std::shared_ptr<BufferingAudioReader>> retired;
    std::atomic<int64> requested{-1};
    std::atomic<uint32> lastDemand{0};
    std::atomic<bool> offline{false}, resident{false};
    void ensureReader() {
        if (std::atomic_load(&reader)) return;
        std::unique_ptr<AudioFormatReader> source(formats.createReaderFor(file));
        if (source) {
            auto created = std::make_shared<BufferingAudioReader>(source.release(), thread, 131072);
            created->setReadTimeout(0);
            std::atomic_store(&reader, std::move(created));
            resident.store(true);
        }
    }
    bool probeAt(BufferingAudioReader& current, int64 at) {
        // Updating the delegate's read position also schedules its next block.
        AudioBuffer<float> probe(2, 1);
        return current.read(&probe, 0, 1, at, true, true);
    }
    int useTimeSlice() override {
        const ScopedTryLock guard(lock);
        if (!guard.isLocked()) return 5;
        retired.erase(std::remove_if(retired.begin(), retired.end(),
            [](const auto& entry) { return entry.use_count() == 1; }), retired.end());
        const auto at = requested.load();
        if (at < 0 || uint32(Time::getMillisecondCounter() - lastDemand.load()) > 2000) {
            if (auto previous = std::atomic_exchange(&reader, std::shared_ptr<BufferingAudioReader>{}))
                retired.push_back(std::move(previous));
            resident.store(false);
            return 100;
        }
        if (!std::atomic_load(&reader)) {
            ensureReader();
            if (auto created = std::atomic_load(&reader)) probeAt(*created, at);
        }
        return 100;
    }
};
}
