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
        probe.setSize(2, 1);
        thread.addTimeSliceClient(this);
    }
    ~StreamingReader() override { thread.removeTimeSliceClient(this); }
    void setOffline(bool value) { offline.store(value); }
    void request(int64 position) noexcept {
        requested.store(jlimit(int64(0), std::max(int64(0), lengthInSamples - 1), position));
        lastDemand.store(Time::getMillisecondCounter());
    }
    bool ready(int64 position) {
        const ScopedTryLock guard(lock);
        return guard.isLocked() && reader && probeAt(position);
    }
    bool cached() const noexcept { return resident.load(); }
    bool readSamples(int* const* destination, int channels, int offset, int64 at, int count) override {
        request(at);
        if (offline.load()) {
            // Export may wait for disk; it must never lose a block merely
            // because the cache worker holds the metadata lock.
            const ScopedLock guard(lock);
            ensureReader();
            if (reader) {
                reader->setReadTimeout(5000);
                return reader->readSamples(destination, channels, offset, at, count);
            }
        }
        const ScopedTryLock guard(lock);
        if (guard.isLocked()) {
            if (reader) {
                reader->setReadTimeout(0);
                return reader->readSamples(destination, channels, offset, at, count);
            }
        }
        for (int c = 0; c < channels; ++c)
            if (destination[c]) FloatVectorOperations::clear(reinterpret_cast<float*>(destination[c]) + offset, count);
        return false;
    }
  private:
    File file;
    AudioFormatManager& formats;
    TimeSliceThread& thread;
    CriticalSection lock;
    std::unique_ptr<BufferingAudioReader> reader;
    AudioBuffer<float> probe;
    std::atomic<int64> requested{-1};
    std::atomic<uint32> lastDemand{0};
    std::atomic<bool> offline{false}, resident{false};
    void ensureReader() {
        if (reader) return;
        std::unique_ptr<AudioFormatReader> source(formats.createReaderFor(file));
        if (source) {
            reader = std::make_unique<BufferingAudioReader>(source.release(), thread, 131072);
            reader->setReadTimeout(0);
            resident.store(true);
        }
    }
    bool probeAt(int64 at) {
        // Updating the delegate's read position also schedules its next block.
        reader->setReadTimeout(0);
        return reader->read(&probe, 0, 1, at, true, true);
    }
    int useTimeSlice() override {
        const ScopedTryLock guard(lock);
        if (!guard.isLocked()) return 5;
        const auto at = requested.load();
        if (at < 0 || uint32(Time::getMillisecondCounter() - lastDemand.load()) > 2000) {
            reader.reset(); resident.store(false);
            return 100;
        }
        ensureReader();
        if (reader) probeAt(at);
        return 10;
    }
};
}
