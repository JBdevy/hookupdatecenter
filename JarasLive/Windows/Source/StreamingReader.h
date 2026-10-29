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
            preparedFill.startThread(Priority::high);
            startThread(Priority::normal);
        }
        ~Service() override { stop(); }
        // The source context outlives its readers. Stop activation before either
        // fill worker, so no new delegates can be added during shutdown.
        void stop() { signalThreadShouldExit(); notify(); stopThread(-1); preparedFill.stopThread(-1); }
      private:
        friend class StreamingReader;
        AudioFormatManager& formats;
        TimeSliceThread& fillThread;
        // Cold fallback seeks must not stall already prepared playback sources.
        TimeSliceThread preparedFill{"CatLive prepared media read-ahead"};
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
    void setOffline(bool value, bool directRead = false) { offline.store(value); directOffline.store(value && directRead); }
    void request(int64 position) noexcept {
        if (directOffline.load(std::memory_order_relaxed)) return;
        requested.store(jlimit(int64(0), std::max(int64(0), lengthInSamples - 1), position));
        lastDemand.store(Time::getMillisecondCounter());
    }
    // Audio callback: reserve the nearest upcoming edit independently of the
    // forward decoder. A trimmed half can jump far ahead in the same MP3.
    void requestUpcoming(int64 position, double distance, uint64 block) noexcept {
        if (offline.load(std::memory_order_relaxed)) return;
        if (upcomingBlock != block) { upcomingBlock = block; upcomingDistance = std::numeric_limits<double>::infinity(); }
        if (distance >= upcomingDistance) return;
        upcomingDistance = distance;
        upcomingPosition.store(std::max<int64>(0, position));
        upcomingDemand.store(Time::getMillisecondCounter());
        request(position);
    }
    bool ready(int64 position, int count = 4096) {
        ReadAccess access(*this);
        for (auto &slot : publishedPinned) {
            const auto *cache = slot.load(std::memory_order_seq_cst);
            if (cache && cache->contains(position, count))
                return probeAt(*cache->forward, position, count);
        }
        return access.current && probeAt(*access.current, position, count);
    }
    bool cached() const noexcept { return resident.load(); }
    bool transitionReady(int64 at, int count, bool loop = false) {
        at=std::max<int64>(0,at);
        if(at>=lengthInSamples)return true;
        ReadAccess access(*this);
        for(int slot=loop?1:0;slot<2;++slot) {
            const auto *cache=publishedPinned[slot].load(std::memory_order_seq_cst);
            // The callback can reach a few samples past the queued destination.
            // Requiring another full second from that point would reject the
            // already decoded onset and unnecessarily seek every file again.
            if(cache && cache->contains(at,count))return true;
        }
        return false;
    }
    void keepTransitionWarm(bool loop=false) {
        if(loop)keepLoopReserve=true;
        pinnedDemand[loop?1:0]=Time::getMillisecondCounter();
    }
    // Control thread only. Decode the destination independently: probing the
    // active forward reader here would evict audio still being played before
    // the seek is committed. Two slots keep a loop start pinned across seeks.
    bool prepareTransition(int64 at, int count, bool loop = false, int reserve = -1) {
        if (reserve >= 2 && reserve < 4) pinnedDemand[reserve] = Time::getMillisecondCounter();
        else keepTransitionWarm(loop);
        if (loop) keepLoopReserve.store(true);
        at = std::max<int64>(0, at);
        if (at >= lengthInSamples) return true;
        const int slot = reserve >= 2 && reserve < 4 ? reserve : loop ? 1 : 0;
        // Include the zero-padded tail: the last device block can cross EOF.
        const auto wanted = int(std::max<int64>(count, int64(sampleRate)));
        const ScopedLock guard(lock);
        if (pinned[slot] && pinned[slot]->contains(at, count)) return true;
        // Decode the onset on the preparation worker, then transfer that same
        // decoder and its exact MP3 checkpoints to the forward stream. Creating
        // another cold decoder would repeat the prefix on the serial fill queue
        // and could leave the source silent when its onset reserve expires.
        if (!transitionDecoder) transitionDecoder.reset(service.formats.createReaderFor(file));
        if (!transitionDecoder) return false;
        auto next = std::make_unique<Pinned>(at, int(numChannels), wanted);
        if (!transitionDecoder->read(&next->pcm, 0, wanted, at, true, true)) return false;
        next->forward = std::make_unique<BufferingAudioReader>(transitionDecoder.release(), service.preparedFill, 131072);
        next->forward->setReadTimeout(0);
        probeAt(*next->forward, at);
        if (pinned[slot]) retiredPinned.push_back(std::move(pinned[slot]));
        pinned[slot] = std::move(next);
        publishedPinned[slot].store(pinned[slot].get(), std::memory_order_seq_cst);
        BufferingAudioReader *empty = nullptr;
        if (published.compare_exchange_strong(empty, pinned[slot]->forward.get(), std::memory_order_seq_cst)) {
            request(at);
            resident.store(true);
        }
        return true;
    }
    void clearLoopReserve() {
        // The old loop may still render while the next destination is being
        // prepared. Retire its reserve only after that source becomes idle.
        keepLoopReserve.store(false);
    }
    // Demand is published by the callback while the service examines it. A
    // newer timestamp must remain recent even if it crosses the service's
    // clock snapshot; unsigned subtraction alone makes it appear ~49 days old.
    // The half-range comparison also preserves normal millisecond-counter wrap.
    static bool demandExpired(uint32 timestamp, uint32 now) noexcept {
        const auto age = uint32(now - timestamp);
        return age > 2000 && age < 0x80000000u;
    }
    std::atomic<uint64> cacheMisses{0}, inactiveMisses{0};
    bool readSamples(int* const* destination, int channels, int offset, int64 at, int count) override {
        if (at >= lengthInSamples) {
            for (int c = 0; c < channels; ++c) if (destination[c])
                FloatVectorOperations::clear(reinterpret_cast<float *>(destination[c]) + offset, count);
            return true;
        }
        if (directOffline.load()) {
            // Offline rendering owns a decoder and a sequential PCM cache. It
            // must not wait for the realtime read-ahead thread on every fill.
            const ScopedLock guard(lock);
            if (!offlineDecoder) offlineDecoder.reset(service.formats.createReaderFor(file));
            if (!offlineDecoder) { ++inactiveMisses; return false; }
            if (offlineStart < 0 || at < offlineStart || at + count > offlineStart + offlinePCM.getNumSamples()) {
                offlinePCM.setSize(int(numChannels), std::max(65536, count), false, false, true);
                if (!offlineDecoder->read(offlinePCM.getArrayOfWritePointers(), int(numChannels), at, offlinePCM.getNumSamples())) {
                    offlineStart = -1; ++cacheMisses; return false;
                }
                offlineStart = at;
            }
            for (int c = 0; c < channels; ++c) if (destination[c]) {
                auto *out = reinterpret_cast<float *>(destination[c]) + offset;
                if (c < offlinePCM.getNumChannels()) FloatVectorOperations::copy(out, offlinePCM.getReadPointer(c, int(at - offlineStart)), count);
                else FloatVectorOperations::clear(out, count);
            }
            return true;
        }
        request(at);
        const bool exporting = offline.load();
        ReadAccess access(*this);
        if (!exporting) for (auto &slot : publishedPinned) {
            const auto *cache = slot.load(std::memory_order_seq_cst);
            if (!cache || !cache->contains(at, count)) continue;
            // Enter this prepared stream only when its reserved PCM is actually
            // consumed. Preparing a future seek must not move the outgoing head.
            // Its owner remains alive even after the onset slot is replaced.
            access.current = cache->forward.get();
            published.store(access.current, std::memory_order_seq_cst);
            // Complete publication before releasing ReadAccess. Reclamation
            // detects a retired reserve adopted by an already active callback.
            selectionRevision.fetch_add(1, std::memory_order_seq_cst);
            resident.store(true);
            access.current->readSamples(nullptr, 0, 0, at, count);
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
            access.current = published.load(std::memory_order_seq_cst);
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
        std::unique_ptr<BufferingAudioReader> forward;
        Pinned(int64 start, int channels, int count) : first(start), pcm(channels, count) {}
        bool contains(int64 at, int count) const { return at >= first && at - first + count <= pcm.getNumSamples(); }
    };
    std::unique_ptr<Pinned> pinned[4];
    std::atomic<Pinned *> publishedPinned[4]{};
    std::atomic<bool> keepLoopReserve{false};
    std::atomic<uint32> pinnedDemand[4]{};
    std::vector<std::unique_ptr<Pinned>> retiredPinned;
    // Ownership is only touched under lock, outside the device callback.
    std::unique_ptr<BufferingAudioReader> reader;
    std::unique_ptr<AudioFormatReader> transitionDecoder; // Worker-only, protected by lock.
    std::unique_ptr<AudioFormatReader> offlineDecoder;
    AudioBuffer<float> offlinePCM;
    int64 offlineStart = -1;
    std::vector<std::unique_ptr<BufferingAudioReader>> retired;
    std::atomic<BufferingAudioReader*> published{nullptr};
    std::atomic<uint64> selectionRevision{0};
    std::atomic<uint32> activeReads{0};
    static_assert(std::atomic<BufferingAudioReader*>::is_always_lock_free &&
                  std::atomic<uint32>::is_always_lock_free && std::atomic<uint64>::is_always_lock_free,
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
    std::atomic<int64> requested{-1}, upcomingPosition{-1};
    std::atomic<uint32> upcomingDemand{0};
    int64 preparedUpcomingPosition = -1; // service-thread only
    int upcomingSlot = 3;
    uint64 upcomingBlock = std::numeric_limits<uint64>::max(); // callback-owned
    double upcomingDistance = std::numeric_limits<double>::infinity();
    std::atomic<uint32> lastDemand{0};
    std::atomic<bool> offline{false}, directOffline{false}, resident{false};
    uint32 lastOpenAttempt = 0;
    bool attemptedOpen = false;
    void ensureReader() {
        if (published.load(std::memory_order_seq_cst)) return;
        const auto at = requested.load();
        for (const auto &cache : pinned) if (cache && cache->contains(at, 1)) {
            BufferingAudioReader *empty = nullptr;
            published.compare_exchange_strong(empty, cache->forward.get(), std::memory_order_seq_cst);
            resident.store(true);
            return;
        }
        if (!reader) {
            std::unique_ptr<AudioFormatReader> source(service.formats.createReaderFor(file));
            if (!source) return;
            reader = std::make_unique<BufferingAudioReader>(source.release(), service.fillThread, 131072);
            reader->setReadTimeout(0);
            probeAt(*reader, std::max<int64>(0, at));
        }
        // Opening a cold file may overlap adoption of a prepared stream. Never
        // overwrite that selection or hint it with this fallback's old position.
        BufferingAudioReader *empty = nullptr;
        published.compare_exchange_strong(empty, reader.get(), std::memory_order_seq_cst);
        resident.store(true);
    }
    bool probeAt(BufferingAudioReader& current, int64 at, int count = 1) {
        // Updating the delegate's read position also schedules its next block.
        AudioBuffer<float> probe(2, count);
        return current.read(&probe, 0, count, at, true, true);
    }
    static bool demandExpired(const std::atomic<uint32>& timestamp) noexcept {
        // Read publication first so a simultaneous callback cannot give this
        // check a timestamp from after its own clock snapshot.
        const auto demandedAt = timestamp.load(std::memory_order_relaxed);
        return demandExpired(demandedAt, Time::getMillisecondCounter());
    }
    void serviceDemand() {
        if (directOffline.load(std::memory_order_relaxed)) return;
        if (directOffline.load()) return;
        const ScopedTryLock guard(lock);
        if (!guard.isLocked()) return;
        // Keep this exact order, paired with callback store -> revision -> guard
        // release. A pre-existing callback may adopt a retired reserve after
        // this selection snapshot; its revision must then invalidate cleanup.
        // Readers entering after the zero check can only use this protected
        // selection or still-published reserves, whose owners stay under lock.
        const auto revision = selectionRevision.load(std::memory_order_seq_cst);
        const auto *selected = published.load(std::memory_order_seq_cst);
        if (activeReads.load(std::memory_order_seq_cst) == 0 &&
            selectionRevision.load(std::memory_order_seq_cst) == revision) {
            retired.erase(std::remove_if(retired.begin(), retired.end(), [=](const auto& old) {
                return old.get() != selected;
            }), retired.end());
            retiredPinned.erase(std::remove_if(retiredPinned.begin(), retiredPinned.end(), [=](const auto& old) {
                return old->forward.get() != selected;
            }), retiredPinned.end());
            if (reader && reader.get() != selected) retired.push_back(std::move(reader));
        }
        const auto at = requested.load();
        const auto future = upcomingPosition.load();
        const bool upcoming = future >= 0 && !demandExpired(upcomingDemand);
        if (!upcoming) {
            for (int slot=2; slot<4; ++slot) {
                publishedPinned[slot].store(nullptr, std::memory_order_seq_cst);
                if (pinned[slot]) retiredPinned.push_back(std::move(pinned[slot]));
            }
            preparedUpcomingPosition = -1;
        }
        if (at < 0 || demandExpired(lastDemand)) {
            if(demandExpired(pinnedDemand[0])) {
                if (!keepLoopReserve.load()) transitionDecoder.reset();
                publishedPinned[0].store(nullptr, std::memory_order_seq_cst);
                if (pinned[0]) retiredPinned.push_back(std::move(pinned[0]));
            }
            if (!keepLoopReserve.load()) {
                publishedPinned[1].store(nullptr, std::memory_order_seq_cst);
                if (pinned[1]) retiredPinned.push_back(std::move(pinned[1]));
            }
            published.store(nullptr, std::memory_order_seq_cst);
            if (reader) retired.push_back(std::move(reader));
            resident.store(false);
            return;
        }
        if (!published.load(std::memory_order_seq_cst)) {
            const auto now = Time::getMillisecondCounter();
            if (attemptedOpen && uint32(now - lastOpenAttempt) < 100) return;
            attemptedOpen = true;
            lastOpenAttempt = now;
            ensureReader();
        }
        if (upcoming) {
            // The previous onset is now audible. Keep it pinned while preparing
            // the following cut, until the forward decoder catches up.
            if (future != preparedUpcomingPosition) {
                upcomingSlot = upcomingSlot == 2 ? 3 : 2;
                preparedUpcomingPosition = future;
            }
            prepareTransition(future, 4096, false, upcomingSlot);
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
