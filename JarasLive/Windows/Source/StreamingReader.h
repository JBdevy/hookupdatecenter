#pragma once
#include "Common.h"
namespace catlive {
// A timeline can reference thousands of files without keeping every file open
// or allocating read-ahead buffers for songs that are not playing. Disk access
// and cache retirement run outside the device callback. Inactive timeline files
// never enter the high-priority read-ahead queue.
class StreamingReader final : public AudioFormatReader {
  public:
    class Service final : private Thread {
      public:
        Service(AudioFormatManager& manager, TimeSliceThread& worker)
            : Thread("CatLive media activation"), formats(manager), fillThread(worker) {
            startThread(Priority::normal);
        }
        ~Service() override { stop(); }
        // The owner stops this worker before shutting down the fill thread.
        void stop() { signalThreadShouldExit(); notify(); stopThread(-1); }
      private:
        friend class StreamingReader;
        AudioFormatManager& formats;
        TimeSliceThread& fillThread;
        CriticalSection clientsLock;
        std::vector<StreamingReader*> clients;
        void add(StreamingReader* reader) {
            const ScopedLock guard(clientsLock);
            clients.push_back(reader);
        }
        void remove(StreamingReader* reader) {
            // Destruction is off the audio thread. Wait until any outstanding
            // activation has finished before releasing its reader/format refs.
            const ScopedLock guard(clientsLock);
            clients.erase(std::remove(clients.begin(), clients.end(), reader), clients.end());
        }
        void run() override;
    };
    struct Metadata {
        String format;
        double sampleRate = 0;
        int64 frames = 0;
        unsigned int channels = 0;
        Metadata() = default;
        Metadata(const AudioFormatReader& reader) : format(reader.getFormatName()),
            sampleRate(reader.sampleRate), frames(reader.lengthInSamples), channels(reader.numChannels) {}
    };
    StreamingReader(const File& path, const AudioFormatReader& metadata,
                    Service& worker)
        : StreamingReader(path, Metadata(metadata), worker) {}
    StreamingReader(const File& path, const Metadata& metadata,
                    Service& worker)
        : AudioFormatReader(nullptr, metadata.format), file(path), service(worker) {
        sampleRate = metadata.sampleRate; lengthInSamples = metadata.frames;
        numChannels = metadata.channels; bitsPerSample = 32; usesFloatingPointData = true;
        service.add(this);
    }
    ~StreamingReader() override { service.remove(this); }
    void setOffline(bool value) { offline.store(value); }
    void request(int64 position) noexcept {
        requested.store(jlimit(int64(0), std::max(int64(0), lengthInSamples - 1), position));
        lastDemand.store(Time::getMillisecondCounter());
    }
    bool ready(int64 position, int count = 4096) {
        ReadAccess access(*this);
        return access.current && probeAt(*access.current, position, count);
    }
    bool cached() const noexcept { return resident.load(); }
    // Control thread only. Decode the destination independently: probing the
    // active forward reader here would evict audio still being played before
    // the seek is committed. Two slots keep a loop start pinned across seeks.
    bool prepareTransition(int64 at, int count, bool loop = false) {
        if (loop) keepLoopReserve.store(true);
        at = std::max<int64>(0, at);
        if (at >= lengthInSamples) return true;
        const int slot = loop ? 1 : 0;
        // Include the zero-padded tail: the last device block can cross EOF.
        const auto wanted = int(std::max<int64>(count, int64(sampleRate)));
        const ScopedLock guard(lock);
        if (pinned[slot] && pinned[slot]->contains(at, wanted)) return true;
        std::unique_ptr<AudioFormatReader> source(service.formats.createReaderFor(file));
        if (!source) return false;
        auto next = std::make_unique<Pinned>(at, int(numChannels), wanted);
        if (!source->read(&next->pcm, 0, wanted, at, true, true)) return false;
        if (pinned[slot]) retiredPinned.push_back(std::move(pinned[slot]));
        pinned[slot] = std::move(next);
        publishedPinned[slot].store(pinned[slot].get(), std::memory_order_seq_cst);
        return true;
    }
    void clearLoopReserve() {
        // The old loop may still render while the next destination is being
        // prepared. Retire its reserve only after that source becomes idle.
        keepLoopReserve.store(false);
    }
    std::atomic<uint64> cacheMisses{0}, inactiveMisses{0};
    bool readSamples(int* const* destination, int channels, int offset, int64 at, int count) override {
        if (at >= lengthInSamples) {
            for (int c = 0; c < channels; ++c) if (destination[c])
                FloatVectorOperations::clear(reinterpret_cast<float *>(destination[c]) + offset, count);
            return true;
        }
        request(at);
        const bool exporting = offline.load();
        ReadAccess access(*this);
        if (!exporting) for (auto &slot : publishedPinned) {
            const auto *cache = slot.load(std::memory_order_seq_cst);
            if (!cache || !cache->contains(at, count)) continue;
            // Hint the normal read-ahead worker without copying missing data
            // over the reserved PCM. It catches up before the reserve ends.
            if (access.current) access.current->readSamples(nullptr, 0, 0, at, count);
            for (int c = 0; c < channels; ++c) if (destination[c]) {
                auto *out = reinterpret_cast<float *>(destination[c]) + offset;
                if (c < cache->pcm.getNumChannels())
                    FloatVectorOperations::copy(out, cache->pcm.getReadPointer(c, int(at - cache->first)), count);
                else FloatVectorOperations::clear(out, count);
            }
            return true;
        }
        if (exporting) {
            // Export may wait for disk; it must never lose a block merely
            // because the cache worker holds the metadata lock.
            const ScopedLock guard(lock);
            ensureReader();
            // Opening a slow file can outlast the idle deadline. Acquire its
            // pointer while still holding the owner lock; the read guard is
            // already active if the service withdraws it immediately after.
            access.current = reader.get();
        }
        // MSVC's atomic shared_ptr functions use a process-wide lock. Publish a
        // raw pointer instead; the worker owns all delegates and only reclaims
        // retired readers after every guarded read has left. The callback never
        // changes ownership, waits for the publication lock, or deletes a file.
        if (access.current) {
            access.current->setReadTimeout(exporting ? 5000 : 0);
            const bool ok = access.current->readSamples(destination, channels, offset, at, count);
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
    Service& service;
    CriticalSection lock;
    struct Pinned {
        int64 first;
        AudioBuffer<float> pcm;
        Pinned(int64 start, int channels, int count) : first(start), pcm(channels, count) {}
        bool contains(int64 at, int count) const { return at >= first && at - first + count <= pcm.getNumSamples(); }
    };
    std::unique_ptr<Pinned> pinned[2];
    std::atomic<Pinned *> publishedPinned[2]{};
    std::atomic<bool> keepLoopReserve{false};
    std::vector<std::unique_ptr<Pinned>> retiredPinned;
    // Ownership is only touched under lock, outside the device callback.
    std::unique_ptr<BufferingAudioReader> reader;
    std::vector<std::unique_ptr<BufferingAudioReader>> retired;
    std::atomic<BufferingAudioReader*> published{nullptr};
    std::atomic<uint32> activeReads{0};
    static_assert(std::atomic<BufferingAudioReader*>::is_always_lock_free &&
                  std::atomic<uint32>::is_always_lock_free,
                  "Streaming reader publication must not take a library lock");
    struct ReadAccess {
        explicit ReadAccess(StreamingReader& value) noexcept : owner(value) {
            // Keep the increment, pointer load, withdrawal, and zero-read test
            // in one sequential order. A read that sees the old pointer has
            // already incremented before withdrawal; a later read sees null.
            owner.activeReads.fetch_add(1, std::memory_order_seq_cst);
            current = owner.published.load(std::memory_order_seq_cst);
        }
        ~ReadAccess() noexcept { owner.activeReads.fetch_sub(1, std::memory_order_seq_cst); }
        ReadAccess(const ReadAccess&) = delete;
        ReadAccess& operator=(const ReadAccess&) = delete;
        StreamingReader& owner;
        BufferingAudioReader* current = nullptr;
    };
    std::atomic<int64> requested{-1};
    std::atomic<uint32> lastDemand{0};
    std::atomic<bool> offline{false}, resident{false};
    uint32 lastOpenAttempt = 0;
    bool attemptedOpen = false;
    void ensureReader() {
        if (reader) return;
        std::unique_ptr<AudioFormatReader> source(service.formats.createReaderFor(file));
        if (source) {
            reader = std::make_unique<BufferingAudioReader>(source.release(), service.fillThread, 131072);
            reader->setReadTimeout(0);
            published.store(reader.get(), std::memory_order_seq_cst);
            resident.store(true);
        }
    }
    bool probeAt(BufferingAudioReader& current, int64 at, int count = 1) {
        // Updating the delegate's read position also schedules its next block.
        AudioBuffer<float> probe(2, count);
        return current.read(&probe, 0, count, at, true, true);
    }
    void serviceDemand() {
        const ScopedTryLock guard(lock);
        if (!guard.isLocked()) return;
        if (activeReads.load(std::memory_order_seq_cst) == 0) { retired.clear(); retiredPinned.clear(); }
        const auto at = requested.load();
        if (at < 0 || uint32(Time::getMillisecondCounter() - lastDemand.load()) > 2000) {
            publishedPinned[0].store(nullptr, std::memory_order_seq_cst);
            if (pinned[0]) retiredPinned.push_back(std::move(pinned[0]));
            if (!keepLoopReserve.load()) {
                publishedPinned[1].store(nullptr, std::memory_order_seq_cst);
                if (pinned[1]) retiredPinned.push_back(std::move(pinned[1]));
            }
            if (reader) {
                published.store(nullptr, std::memory_order_seq_cst);
                retired.push_back(std::move(reader));
            }
            resident.store(false);
            return;
        }
        if (!reader) {
            const auto now = Time::getMillisecondCounter();
            if (attemptedOpen && uint32(now - lastOpenAttempt) < 100) return;
            attemptedOpen = true;
            lastOpenAttempt = now;
            ensureReader();
            if (reader) probeAt(*reader, at);
        }
    }
};
inline void StreamingReader::Service::run() {
    while (!threadShouldExit()) {
        {
            const ScopedLock guard(clientsLock);
            // One linear pass per interval, rather than one whole-queue search
            // for every inactive source as in TimeSliceThread scheduling.
            // Decoder opening can block here without holding up active fills.
            for (auto* reader : clients) {
                if (threadShouldExit()) break;
                reader->serviceDemand();
            }
        }
        wait(20);
    }
}
}
