// Included by JarasEffects.mm. Only file playback uses this source; live inputs
// and plug-in routing stay on AVAudioEngine's existing graph.
#if TARGET_OS_OSX || TARGET_OS_IOS
// Keep history ready for live rate/pitch edits. Changed spectra use Apple's
// vectorized FFT on both Intel and ARM. The portable implementation remains
// available to Windows; the CatLive warmup optimizations below are opt-in.
#define SIGNALSMITH_USE_ACCELERATE 1
#define CATLIVE_SIGNALSMITH_NEUTRAL_WARMUP 1
#define CATLIVE_SIGNALSMITH_BATCH_OUTPUT 1
#define CATLIVE_SIGNALSMITH_NEUTRAL_SYNTHESIS 1
#define CATLIVE_SIGNALSMITH_STATE_COPY 1
#include "../../Windows/ThirdParty/Signalsmith/signalsmith-stretch.h"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <deque>
#include <optional>
#include <map>
#include <sys/stat.h>
#include "../../Core/Audio/SingleReaderSlots.hpp"
#include "../../Core/Audio/RealtimeRunState.hpp"
#include "JarasRealtimeClock.hpp"
#include "../../Core/Audio/SharedRenderPool.hpp"

#include "JarasParallelPrepared.inc"
#include "JarasPreparedTiming.inc"

namespace {
struct PreparedPCMBlock {
    int64_t first = 0;
    int count = 0;
    std::array<std::vector<float>, 2> samples;
};

// Preparation/workers only. Independent playheads share immutable decoded
// media, never their positions, loop ranges, effects or render-side leases.
// A copied track must not open another descriptor for every reserved voice.
struct PreparedPCMReader {
    AVAudioFile *__strong file;
    std::mutex mutex;
    std::map<int64_t, std::weak_ptr<const PreparedPCMBlock>> blocks;
    std::deque<std::shared_ptr<const PreparedPCMBlock>> recent;
    size_t recentBytes = 0;
    explicit PreparedPCMReader(AVAudioFile *value) : file(value) {}
    static std::shared_ptr<PreparedPCMReader> open(NSURL *url, NSError **error) {
        static std::mutex registryMutex;
        static std::map<std::string, std::weak_ptr<PreparedPCMReader>> registry;
        std::string key = url.standardizedURL.absoluteString.UTF8String ?: "";
        struct stat status{};
        // A replaced/edited file at the same URL starts a fresh decoder. The
        // preceding immutable blocks remain alive for any existing readers.
        if (url.isFileURL && stat(url.fileSystemRepresentation, &status) == 0) {
            key += ":" + std::to_string(status.st_dev) + ":" + std::to_string(status.st_ino) +
                   ":" + std::to_string(status.st_size) + ":" + std::to_string(status.st_mtimespec.tv_sec) +
                   ":" + std::to_string(status.st_mtimespec.tv_nsec) + ":" + std::to_string(status.st_ctimespec.tv_sec) +
                   ":" + std::to_string(status.st_ctimespec.tv_nsec);
        }
        std::lock_guard<std::mutex> lock(registryMutex);
        for (auto it = registry.begin(); it != registry.end();) {
            if (it->second.expired()) it = registry.erase(it); else ++it;
        }
        if (auto found = registry.find(key); found != registry.end()) {
            if (auto reader = found->second.lock()) return reader;
        }
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
        if (!file) return {};
        auto reader = std::make_shared<PreparedPCMReader>(file);
        registry[key] = reader;
        return reader;
    }
    std::shared_ptr<const PreparedPCMBlock> read(int64_t first, AVAudioFrameCount frames,
                                                NSError **error, bool background, bool &busy) {
        std::unique_lock<std::mutex> lock(mutex, std::defer_lock);
        busy = false;
        if (background) {
            if (!lock.try_lock()) { busy = true; return {}; }
        } else { lock.lock(); }
        auto it = blocks.upper_bound(first);
        if (it != blocks.begin()) {
            --it;
            if (auto block = it->second.lock(); block && first < block->first + block->count) return block;
        }
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];
        if (file.framePosition != first) file.framePosition = first;
        if (!buffer || ![file readIntoBuffer:buffer frameCount:frames error:error]) return {};
        if (buffer.frameLength == 0 || buffer.format.channelCount == 0 || !buffer.floatChannelData) {
            if (error) *error = [NSError errorWithDomain:@"CatLive.PreparedAudio" code:3
                userInfo:@{NSLocalizedDescriptionKey:@"Could not decode source audio"}];
            return {};
        }
        auto block = std::make_shared<PreparedPCMBlock>();
        block->first = first; block->count = int(buffer.frameLength);
        const auto channels = buffer.format.channelCount;
        const auto stride = buffer.stride;
        const auto data = buffer.floatChannelData;
        for (int channel = 0; channel < 2; ++channel) {
            const float *input = data[std::min(channel, int(channels) - 1)];
            auto &output = block->samples[channel];
            if (stride == 1) output.assign(input, input + block->count);
            else {
                output.resize(block->count);
                for (int n = 0; n < block->count; ++n) output[n] = input[n * stride];
            }
        }
        blocks[first] = block;
        recent.push_back(block); recentBytes += size_t(block->count) * 2 * sizeof(float);
        // Bound idle lookahead per file. Active pages retain their own shared
        // blocks independently, so eviction never removes audio in use.
        while (recentBytes > 8 * 1024 * 1024 && recent.size() > 1) {
            recentBytes -= size_t(recent.front()->count) * 2 * sizeof(float); recent.pop_front();
        }
        if (blocks.size() > 128) {
            for (auto entry = blocks.begin(); entry != blocks.end();) {
                if (entry->second.expired()) entry = blocks.erase(entry); else ++entry;
            }
        }
        return block;
    }
};

struct PreparedPCMPage {
    int64_t first = 0;
    int count = 0;
    std::shared_ptr<const PreparedPCMBlock> block;
    std::array<const float *, 2> samples{};
};

struct PreparedPCMCache {
    // Slots are cheap until populated. Keep six streaming pages plus spectral
    // lookahead; very high source rates/speeds need more initial coverage.
    static constexpr int pageSize = 32768, pageCount = 64;
    std::shared_ptr<PreparedPCMReader> reader;
    AVAudioFile *__strong file;
    NSURL *__strong url;
    int64_t length;
    double sampleRate;
    std::mutex decoder;
    using Pages = catlive::audio::SingleReaderSlots<PreparedPCMPage, pageCount>;
    Pages pages;
    std::atomic<double> requested{0}, loopStart{0}, loopEnd{0};
    std::atomic<bool> active{false};
    std::atomic<int> lookaheadPages{6};
    std::chrono::steady_clock::time_point retryAfter{}; // Decoder lock only.
    struct Request {
        double frame, loopStart, loopEnd;
        int pages;
        bool operator==(const Request &other) const {
            return frame == other.frame && loopStart == other.loopStart &&
                   loopEnd == other.loopEnd && pages == other.pages;
        }
    };
    // Decoder lock only. A completed request owns all its wanted pages until
    // another prefetch changes this cache; there is no external page eviction.
    std::optional<Request> readyRequest;
    enum class Prefetch { ready, pending, busy, failed };

    explicit PreparedPCMCache(std::shared_ptr<PreparedPCMReader> value)
        : reader(std::move(value)), file(reader->file), url(file.url), length(file.length), sampleRate(file.processingFormat.sampleRate) {}
    explicit PreparedPCMCache(AVAudioFile *f) : PreparedPCMCache(std::make_shared<PreparedPCMReader>(f)) {}
    double wrapped(double frame) const {
        const double start = loopStart.load(), end = loopEnd.load();
        if (end > start && frame >= start) return start + std::fmod(frame - start, end - start);
        return frame;
    }
    const PreparedPCMPage* pageAt(int64_t first, const Pages::Lease& lease) const {
        for (size_t i=0;i<pageCount;++i) {
            const auto* page=lease.get(i);
            if(page && page->first==first)return page;
        }
        return nullptr;
    }
    const PreparedPCMPage* producerPageAt(int64_t first) const {
        for(size_t i=0;i<pageCount;++i) {
            const auto* page=pages.producerView(i);
            if(page && page->first==first)return page;
        }
        return nullptr;
    }
    Prefetch prefetch(int count, NSError **error = nullptr, bool background = false) {
        // A slow decoder/preparation must not make every other stem wait behind
        // its mutex. The callback never takes this lock or performs file I/O.
        std::unique_lock<std::mutex> lock(decoder, std::defer_lock);
        if (background) {
            if (!active.load()) return Prefetch::ready;
            if (!lock.try_lock()) return Prefetch::busy;
        } else {
            lock.lock();
            retryAfter = {};
        }
        const Request request{requested.load(), loopStart.load(), loopEnd.load(), std::min(count, pageCount)};
        if (readyRequest && *readyRequest == request) {
            // A reader may have kept old payloads alive during the final
            // publication. Reclaim them after quiescence even on a cache hit.
            if (pages.retiredCount() != 0) pages.collectRetired();
            return Prefetch::ready;
        }
        // A different request can evict pages before returning pending/failed.
        // Never let a later seek reuse the earlier request's readiness claim.
        readyRequest.reset();
        if (background && std::chrono::steady_clock::now() < retryAfter) return Prefetch::busy;
        // Physical pages on opposite sides of a loop can have the same ring
        // index. Keep the whole lookahead set resident instead of letting one
        // side evict the other (also handles loops not aligned to page edges).
        std::array<int64_t, pageCount> wanted{};
        int wantedCount = 0;
        const auto wantedEnd = [&] { return wanted.begin() + wantedCount; };
        const auto contains = [&](int64_t first) {
            return std::find(wanted.begin(), wantedEnd(), first) != wantedEnd();
        };
        const double start = request.loopStart, end = request.loopEnd;
        double frame = request.frame;
        if (end > start && frame >= start) frame = start + std::fmod(frame - start, end - start);
        for (int i = 0; i < request.pages; ++i) {
            const int64_t first = int64_t(std::max(0., frame)) / pageSize * pageSize;
            if (first >= length || contains(first)) break;
            wanted[wantedCount++] = first;
            const double next = double(first + pageSize);
            frame = end > start && next >= end ? start : next;
        }
        int decoded = 0;
        for (int i = 0; i < wantedCount; ++i) {
            const auto first = wanted[i];
            if (producerPageAt(first)) continue;
            if (background) {
                if (!active.load()) return Prefetch::ready;
                // One bounded read per stem per pass keeps refills fair.
                if (decoded != 0) return Prefetch::pending;
            }
            // Amortize storage/decoder latency over a contiguous read. Also
            // keep a small forward reserve beyond the requested window: if we
            // only fill its single missing page, every stem incurs another
            // physical read as soon as playback crosses the next page edge.
            // Never evict a wanted page, cross a loop seam, or exceed the fixed
            // cache capacity. The callback still only leases immutable PCM.
            std::array<size_t, 4> slots{};
            int batchPages = 0;
            for (int pageIndex = 0; pageIndex < int(slots.size()); ++pageIndex) {
                const int64_t pageFirst = first + int64_t(pageIndex) * pageSize;
                if (pageFirst >= length || producerPageAt(pageFirst) ||
                    (pageIndex > 0 && end > start && pageFirst >= end)) break;
                size_t slot = 0;
                for (; slot < pageCount; ++slot) {
                    if (std::find(slots.begin(), slots.begin() + batchPages, slot) != slots.begin() + batchPages) continue;
                    const auto* page = pages.producerView(slot);
                    if (!page || !contains(page->first)) break;
                }
                if (slot == pageCount) break;
                slots[batchPages++] = slot;
            }
            if (batchPages == 0) return Prefetch::failed;
            const auto readFrames = AVAudioFrameCount(batchPages * pageSize);
            bool readerBusy = false;
            const auto block = reader->read(first, readFrames, error, background, readerBusy);
            if (readerBusy) return Prefetch::busy;
            if (!block) {
                // An unavailable/cloud-backed file cannot consume every pass
                // with repeated failing reads while healthy tracks need PCM.
                retryAfter = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
                return Prefetch::failed;
            }
            for (int pageIndex = 0; pageIndex < batchPages; ++pageIndex) {
                const int offset = int(first - block->first) + pageIndex * pageSize;
                if (offset >= block->count) break;
                auto page = std::make_unique<PreparedPCMPage>();
                page->first = first + pageIndex * pageSize;
                page->count = std::min(pageSize, block->count - offset);
                page->block = block;
                for (int channel = 0; channel < 2; ++channel) page->samples[channel] = block->samples[channel].data() + offset;
                pages.publish(slots[pageIndex], std::move(page));
            }
            ++decoded;
        }
        pages.collectRetired();
        readyRequest = request;
        return Prefetch::ready;
    }

};

class PreparedPCMWorkers {
    std::mutex mutex;
    std::condition_variable wake;
    bool closing = false;
    uint64_t wakeGeneration = 0;
    std::vector<std::weak_ptr<PreparedPCMCache>> caches;
    std::array<std::thread, 2> threads;
    void run() {
        std::unique_lock<std::mutex> lock(mutex);
        while (!closing) {
            std::vector<std::shared_ptr<PreparedPCMCache>> work;
            for (auto it = caches.begin(); it != caches.end();) {
                if (auto cache = it->lock()) { if (cache->active.load()) work.push_back(cache); ++it; }
                else it = caches.erase(it);
            }
            const auto observedWake = wakeGeneration;
            lock.unlock();
            bool pending = false;
            @autoreleasepool {
                for (auto &cache : work) {
                    const auto result = cache->prefetch(cache->lookaheadPages.load(), nullptr, true);
                    pending = pending || result == PreparedPCMCache::Prefetch::pending;
                }
            }
            lock.lock();
            if (!pending) {
                wake.wait_for(lock, std::chrono::milliseconds(10), [this, observedWake] {
                    return closing || wakeGeneration != observedWake;
                });
            }
        }
    }
    PreparedPCMWorkers() {
        // A blocked file decoder must not prevent healthy stems from refilling.
        // The per-cache try-lock serializes each decoder without blocking the
        // other worker; neither worker runs on the audio callback.
        for (auto &thread : threads) thread = std::thread([this] {
#if TARGET_OS_OSX
            // Decoding fills a seconds-long read-ahead window. Keep it below
            // the current audio render when many independent MP3s refill at
            // once; otherwise decoder bursts steal the DSP deadline on Intel.
            pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
            run();
        });
    }
public:
    static PreparedPCMWorkers &shared() { static PreparedPCMWorkers workers; return workers; }
    void add(const std::shared_ptr<PreparedPCMCache> &cache) { std::lock_guard<std::mutex> lock(mutex); caches.push_back(cache); ++wakeGeneration; wake.notify_all(); }
    // Control/preparation threads only; the audio callback never signals locks.
    void requestWake() { std::lock_guard<std::mutex> lock(mutex); ++wakeGeneration; wake.notify_all(); }
    ~PreparedPCMWorkers() { { std::lock_guard<std::mutex> lock(mutex); closing = true; } wake.notify_all(); for (auto &thread : threads) thread.join(); }
};

#include "JarasSharedStretch.inc"

struct PreparedClipKernel : PreparedRenderSource {
    const bool diagnosticsEnabled = [] { const char *value = getenv("CATLIVE_BUFFERED_MAC_AUDIO_DIAGNOSTICS"); return value && strcmp(value, "1") == 0; }();
    std::atomic<uint64_t> diagnosticRuns{0}, diagnosticHits{0}, diagnosticHistory{0};
    std::atomic<double> diagnosticAhead{0}, diagnosticRate{1};
    std::atomic<int> diagnosticFirstFrames{0};
    const double sampleRate;
    const int channels;
    const uint64_t timingID = [] { static std::atomic<uint64_t> next{0}; return ++next; }();
    std::shared_ptr<PreparedTimingState> timing;
    std::atomic<uint64_t> timingRun{0};
    std::shared_ptr<PreparedPCMCache> cache;
    std::mutex preparation;
    std::shared_ptr<PreparedStretchGroup> stretchGroup;
    PreparedStretchGroup::Pool::Lease stretch;
    PreparedStretchGroup::Pool::Lease pendingStretch;
    PreparedStretchKey parallelKey;
    // 0: idle, 1: queued, 2: running, 3: completed. The graph can claim its
    // source before a helper does, while helpers prepare the remaining tracks.
    std::atomic<unsigned> parallelJob{0};
    bool parallelInPlaceReady = false, parallelInPlaceOK = true;
    int parallelConsumed = 0;
    int pendingConsumed = 0;
    int seekFrames = 0;
    std::array<std::vector<float>, 2> input, output;
    catlive::audio::RealtimeRunState playback;
    std::atomic<uint64_t> startHost{0}, misses{0};
    std::atomic<double> rate{1}, semitones{0}, endFrame{0}, position{0};
    double source = 0, ahead = 0, preparedFrame = -1, preparedRate = 1, preparedPitch = 0;
    double dryClockFrame = 0;
    uint64_t dryClockHost = 0;
    double dryNextSample = std::numeric_limits<double>::quiet_NaN();
    // Control-side only, protected by preparation. A cache URL/range alone is
    // not evidence that its PCM and spectral history were successfully primed.
    bool prepared = false;
    bool spectral = false, ramp = false;
    bool nativeTempo = true;
    bool mobileClockAnchored = false;
    double mobileClockOffset = 0;
    int rampFrame = 0;
    PreparedClipKernel(double sr, int ch) : sampleRate(sr), channels(ch) {
        for (auto &buffer : output) buffer.resize(PreparedStretchState::maximumFrames);
    }
    ~PreparedClipKernel() { if (timing) timing->remove(timingID); }
    void configureStretchGroup() {
        if (stretchGroup && stretchGroup->reader == cache->reader) return;
        pendingStretch.reset(); pendingConsumed = 0;
        stretch.reset();
        stretchGroup = PreparedStretchGroup::open(cache->reader, sampleRate);
        stretch = stretchGroup->pool.acquire();
        seekFrames = stretch->pitch.outputSeekLength(1.f);
        for (auto &buffer : input) buffer.resize(std::max(8192, seekFrames));
    }
    bool read(double first, double step, int frames, float *left, float *right) {
        if (!cache) return false;
        auto lease = cache->pages.read();
        std::array<const PreparedPCMPage*, PreparedPCMCache::pageCount> leases{};
        bool ok = true;
        auto value = [&](int64_t frame, int channel) -> float {
            if (frame < 0 || frame >= cache->length) return 0;
            const int64_t pageFirst = frame / PreparedPCMCache::pageSize * PreparedPCMCache::pageSize;
            const int slot = int(frame / PreparedPCMCache::pageSize % PreparedPCMCache::pageCount);
            auto &page = leases[slot];
            if (!page || page->first != pageFirst) page = cache->pageAt(pageFirst, lease);
            if (!page || page->first != pageFirst) { ok = false; return 0; }
            const auto index = frame - pageFirst;
            return index < page->count ? page->samples[channel][size_t(index)] : 0;
        };
        const double end = endFrame.load();
        const double loopFirst = cache->loopStart.load(), loopEnd = cache->loopEnd.load();
        const double wrappedFirst = cache->wrapped(first);
        // Normal-speed reads between loop/file boundaries need exact PCM,
        // not interpolation or atomic loop queries for every sample. Both the
        // dry signal and its warm spectral history use this bounded copy path.
        if (step == 1 && wrappedFirst >= 0 && std::floor(wrappedFirst) == wrappedFirst &&
            first + frames <= end && wrappedFirst + frames <= cache->length &&
            (loopEnd <= loopFirst || wrappedFirst + frames <= loopEnd)) {
            int copied = 0;
            while (copied < frames) {
                const auto frame = int64_t(wrappedFirst) + copied;
                const auto pageFirst = frame / PreparedPCMCache::pageSize * PreparedPCMCache::pageSize;
                const auto *page = cache->pageAt(pageFirst, lease);
                const int offset = int(frame - pageFirst);
                const int count = std::min(frames - copied, PreparedPCMCache::pageSize - offset);
                const int available = page ? std::clamp(page->count - offset, 0, count) : 0;
                if (available > 0) {
                    std::copy_n(page->samples[0] + offset, available, left + copied);
                    std::copy_n(page->samples[1] + offset, available, right + copied);
                }
                if (available < count) {
                    std::fill_n(left + copied + available, count - available, 0.f);
                    std::fill_n(right + copied + available, count - available, 0.f);
                    if (!page) ok = false;
                }
                copied += count;
            }
            return ok;
        }
        // A changed BPM usually still reads entirely inside one decoded page.
        // Resolve that page once instead of querying wrap/page ownership four
        // times per stereo sample. Keep the same double-precision source clock
        // and linear interpolation as the boundary-aware path below.
        const double last = wrappedFirst + std::max(0, frames - 1) * step;
        if (frames > 0 && step > 0 && wrappedFirst >= 0 &&
            first + (frames - 1) * step < end && last + 1 < cache->length &&
            (loopEnd <= loopFirst || (wrappedFirst >= loopFirst && last + 1 < loopEnd))) {
            const int64_t pageFirst = int64_t(wrappedFirst) / PreparedPCMCache::pageSize * PreparedPCMCache::pageSize;
            const auto *page = cache->pageAt(pageFirst, lease);
            if (page && last + 1 < pageFirst + page->count) {
                for (int n = 0; n < frames; ++n) {
                    const double frame = wrappedFirst + n * step;
                    const int64_t index = int64_t(frame);
                    const float fraction = float(frame - index);
                    const auto offset = index - pageFirst;
                    const float l = page->samples[0][offset], r = page->samples[1][offset];
                    left[n] = fraction == 0 ? l : l + fraction * (page->samples[0][offset + 1] - l);
                    right[n] = fraction == 0 ? r : r + fraction * (page->samples[1][offset + 1] - r);
                }
                return true;
            }
        }
        for (int n = 0; n < frames; ++n) {
            const double unwrapped = first + n * step;
            if (unwrapped >= end) { left[n] = right[n] = 0; continue; }
            const double frame = cache->wrapped(unwrapped);
            const int64_t index = int64_t(std::floor(frame));
            const float fraction = float(frame - index);
            const int64_t next = int64_t(cache->wrapped(double(index + 1)));
            const float l = value(index, 0), r = value(index, 1);
            left[n] = fraction == 0 ? l : l + fraction * (value(next, 0) - l);
            right[n] = fraction == 0 ? r : r + fraction * (value(next, 1) - r);
        }
        return ok;
    }
    int prefetchPages(double speed) const {
        // Exact dry PCM and the warm spectral processor have separate cursors.
        // Include their separation even at high source rates/live rate changes;
        // a fixed six-page window can otherwise evict needed FFT lookahead.
        // Six pages cover seconds at ordinary rates, but only 32 ms at
        // 192 kHz / 32x. Preserve at least 100 ms of decoded output ahead of
        // the spectral cursor, including worker wake/scheduling jitter.
        const double streamingFrames = std::max(6.0 * PreparedPCMCache::pageSize,
                                                sampleRate * speed * 0.1);
        const double spectralFrames = seekFrames * speed;
        return std::clamp(int(std::ceil((streamingFrames + spectralFrames) /
                                      PreparedPCMCache::pageSize)),
                          6, PreparedPCMCache::pageCount);
    }
    bool prime(double frame, double speed, double tuning) {
        parallelInPlaceReady = false; parallelConsumed = 0;
        pendingStretch.reset(); pendingConsumed = 0;
        source = ahead = frame;
        spectral = std::abs(tuning - 12 * std::log2(speed)) >= 1e-8;
        // Feed tempo directly to the stretcher instead of resampling every
        // sample and undoing that pitch change with spectral frequency mapping.
        // Keep exact varispeed playback on its existing neutral/resampling path.
        // This choice belongs to the scheduled run and its shared DSP history.
        nativeTempo = !(speed != 1 && !spectral);
        seekFrames = stretch->pitch.outputSeekLength(nativeTempo ? speed : 1);
        for (auto &buffer : input) if (buffer.size() < size_t(seekFrames)) buffer.resize(seekFrames);
        const PreparedStretchKey key{frame, speed, tuning, endFrame.load(), cache->loopStart.load(),
                                     cache->loopEnd.load(), seekFrames, spectral, frame, nativeTempo};
        std::lock_guard<std::mutex> lock(stretchGroup->preparation);
        auto seeded = stretchGroup->seed(key);
        if (seeded) {
            stretch = std::move(seeded);
        } else {
            if (!stretchGroup->pool.makeExclusive(stretch)) stretch = stretchGroup->pool.acquire();
            if (!stretch) return false;
            auto &pitch = stretch->pitch;
            pitch.setNeutralWarmup(!spectral);
            pitch.reset();
            pitch.setTransposeSemitones(float(nativeTempo ? tuning : tuning - 12 * std::log2(speed)));
            if (!read(nativeTempo ? std::floor(frame) : frame, nativeTempo ? 1 : speed, seekFrames, input[0].data(), input[1].data())) return false;
            const float *pointers[]{input[0].data(), input[1].data()};
            pitch.outputSeek(pointers, seekFrames);
            stretch->key = key;
            stretchGroup->rememberSeed(stretch);
        }
        ahead += seekFrames * (nativeTempo ? 1 : speed);
        preparedFrame = frame; preparedRate = speed; preparedPitch = tuning;
        position.store(frame); rampFrame = 0;
        return true;
    }
    bool fillStretch(PreparedStretchState &state, const PreparedStretchKey &key) {
        auto &pitch = state.pitch;
        pitch.setTransposeSemitones(float(key.nativeTempo ? key.tuning : key.tuning - 12 * std::log2(key.speed)));
        pitch.setNeutralWarmup(!key.spectral);
        bool ok = true;
        double readFrame = key.frame;
        for (int done = 0; done < key.count;) {
            const int capacity = key.nativeTempo
                ? int(input[0].size() / std::max(1., key.speed)) - 1 : 512;
            const int chunk = std::min({4096, key.count - done, capacity});
            const double inputFirst = key.nativeTempo ? std::floor(readFrame) : readFrame;
            const double inputEnd = std::floor(readFrame + chunk * key.speed);
            const int inputCount = key.nativeTempo ? int(inputEnd - inputFirst) : chunk;
            ok = read(inputFirst, key.nativeTempo ? 1 : key.speed, inputCount, input[0].data(), input[1].data()) && ok;
            const float *inputs[]{input[0].data(), input[1].data()};
            float *outputs[]{state.output[0].data() + done, state.output[1].data() + done};
            // The absolute input clock keeps converter prefix/suffix pulls
            // identical to an unsplit render, even at fractional tempo ratios.
            pitch.process(inputs, inputCount, outputs, chunk, key.nativeTempo ? key.speed : 0, readFrame);
            if (!key.spectral) ok = read(key.source + done * key.speed, key.speed, chunk, outputs[0], outputs[1]) && ok;
            if (key.source + (done + chunk - 1) * key.speed >= key.end) {
                for (int n = 0; n < chunk; ++n) if (key.source + (done + n) * key.speed >= key.end)
                    outputs[0][n] = outputs[1][n] = 0;
            }
            readFrame += chunk * key.speed;
            done += chunk;
        }
        state.key = key; state.complete = ok;
        state.owner = timingID; state.run = timingRun.load();
        return ok;
    }
    bool sameStretchControls(const PreparedStretchState &state, double speed, double tuning) const {
        if (state.key.speed == speed && state.key.tuning == tuning) return true;
        // A converter may still need the suffix already rendered for another
        // copy. A project-wide tempo edit applies after that common PCM, rather
        // than forking a new history at every converter's rounding boundary.
        // An individual rate/pitch edit must still branch independently.
        double ownerRate = state.key.speed, ownerPitch = state.key.tuning;
        return timing && timing->read(state.owner, state.run, ownerRate, ownerPitch) &&
            ownerRate == speed && ownerPitch == tuning;
    }
    bool matchesStretch(const PreparedStretchState &state, double speed, double tuning, int consumed) const {
        const auto &key = state.key;
        return state.complete && key.frame + consumed * key.speed == ahead &&
            key.source + consumed * key.speed == source && key.end == endFrame.load() &&
            key.nativeTempo == nativeTempo &&
            key.loopStart == cache->loopStart.load() && key.loopEnd == cache->loopEnd.load() &&
            sameStretchControls(state, speed, tuning);
    }
    bool forkConsumedStretch(bool &ok) {
        // Keep the ancestor until every cached sample has been consumed. A
        // private edit in a partially consumed block resumes its exact prefix,
        // without adopting the other copy's unplayed rate/pitch or PCM.
        auto fork = stretchGroup->pool.acquire();
        assert(fork);
        if (!fork) return false;
        fork->copyStateFrom(*stretch);
        auto prefix = pendingStretch->key;
        prefix.count = pendingConsumed;
        if (prefix.count) ok = fillStretch(*fork, prefix) && ok;
        stretch = std::move(fork);
        pendingStretch.reset(); pendingConsumed = 0;
        return true;
    }
    bool processStretch(double speed, double tuning, int count) {
        bool ok = true;
        for (int done = 0; done < count;) {
            if (parallelInPlaceReady) {
                const auto &key = stretch->key;
                const int available = std::min(count - done, key.count - parallelConsumed);
                for (int ch = 0; ch < 2; ++ch)
                    std::copy_n(stretch->output[ch].data() + parallelConsumed, available, output[ch].data() + done);
                parallelConsumed += available; done += available;
                ahead = key.frame + parallelConsumed * key.speed;
                source = key.source + parallelConsumed * key.speed;
                ok = parallelInPlaceOK && ok;
                if (parallelConsumed == key.count) { parallelInPlaceReady = false; parallelConsumed = 0; }
                continue;
            }
            if (pendingStretch && !matchesStretch(*pendingStretch, speed, tuning, pendingConsumed)) {
                if (!forkConsumedStretch(ok)) return false;
            }
            if (!pendingStretch) {
                auto cached = stretch.cachedSuccessor();
                if (cached && matchesStretch(*cached, speed, tuning, 0)) {
                    if (diagnosticsEnabled) ++diagnosticHits;
                    pendingStretch = std::move(cached); pendingConsumed = 0;
                } else {
                    cached.reset();
                    if (diagnosticsEnabled) ++diagnosticRuns;
                    const PreparedStretchKey key{ahead, speed, tuning, endFrame.load(), cache->loopStart.load(),
                        cache->loopEnd.load(), count - done, spectral, source, nativeTempo};
                    if (stretchGroup->pool.makeExclusive(stretch)) {
                        ok = fillStretch(*stretch, key) && ok;
                        for (int ch = 0; ch < 2; ++ch)
                            std::copy_n(stretch->output[ch].data(), key.count, output[ch].data() + done);
                        ahead = key.frame + key.count * key.speed;
                        source = key.source + key.count * key.speed;
                        done += key.count;
                        continue;
                    }
                    auto fork = stretchGroup->pool.acquire();
                    assert(fork);
                    if (!fork) return false;
                    fork->copyStateFrom(*stretch);
                    ok = fillStretch(*fork, key) && ok;
                    if (fork->complete) stretch.publishSuccessor(fork);
                    pendingStretch = std::move(fork); pendingConsumed = 0;
                }
            }
            const auto &key = pendingStretch->key;
            const int available = std::min(count - done, key.count - pendingConsumed);
            for (int ch = 0; ch < 2; ++ch)
                std::copy_n(pendingStretch->output[ch].data() + pendingConsumed, available, output[ch].data() + done);
            pendingConsumed += available; done += available;
            ahead = key.frame + pendingConsumed * key.speed;
            source = key.source + pendingConsumed * key.speed;
            if (pendingConsumed == key.count) {
                stretch = std::move(pendingStretch); pendingConsumed = 0;
            }
        }
        return ok;
    }
    bool prepareParallel(unsigned frames, double graphRate, uint64_t host) override {
        if (!playback.enter()) return false;
        bool accepted = false;
        struct Exit { PreparedClipKernel &kernel; bool &accepted;
            ~Exit() { if (!accepted) kernel.playback.leave(); } } exit{*this, accepted};
        if (parallelInPlaceReady) return false;
        if (!cache || !stretch || source >= endFrame.load() || source == preparedFrame) return false;
        if (startHost.load() > host) return false;
        double speed = rate.load(), tuning = semitones.load();
        if (timing) timing->read(timingID, timingRun.load(), speed, tuning);
        const bool processing = spectral || std::abs(tuning - 12 * std::log2(speed)) >= 1e-8;
        if (!processing) return false;
        // Only compute the guaranteed prefix. A converter may ask for one
        // extra frame; serial rendering finishes that tail at the current
        // controls instead of carrying old tempo PCM into the next graph pull.
        int count = std::clamp(int(std::floor(frames * sampleRate / graphRate)), 1,
                                     PreparedStretchState::maximumFrames);
        // Shared copies already reuse their common DSP on the serial path.
        // Only advance histories exclusively owned by this source. This avoids
        // copying large FFT state and cannot consume another copy's prefix.
        if (pendingStretch || stretch.cachedSuccessor() || !stretchGroup->pool.makeExclusive(stretch)) return false;
        parallelKey = {ahead, speed, tuning, endFrame.load(), cache->loopStart.load(),
                       cache->loopEnd.load(), count, processing, source, nativeTempo};
        parallelJob.store(1, std::memory_order_release);
        accepted = true;
        return true;
    }
    void executeParallel() override {
        unsigned expected = 1;
        if (!parallelJob.compare_exchange_strong(expected, 2, std::memory_order_acq_rel)) return;
        parallelInPlaceOK = fillStretch(*stretch, parallelKey);
        parallelConsumed = 0; parallelInPlaceReady = true;
        playback.leave();
        parallelJob.store(3, std::memory_order_release);
    }
    void finishParallel() override {
        const auto previous = parallelJob.exchange(0, std::memory_order_acq_rel);
        if (previous == 1) playback.leave();
        assert(previous != 2);
    }
    OSStatus render(const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *buffers) {
        jaras::ScopedAudioDenormals denormals;
        if (parallelJob.load(std::memory_order_acquire)) {
            executeParallel();
            while (parallelJob.load(std::memory_order_acquire) == 2) std::this_thread::yield();
            parallelJob.store(0, std::memory_order_release);
        }
        for (UInt32 ch = 0; ch < buffers->mNumberBuffers; ++ch)
            if (buffers->mBuffers[ch].mData) memset(buffers->mBuffers[ch].mData, 0, buffers->mBuffers[ch].mDataByteSize);
        if (!playback.enter()) return noErr;
        struct Exit { catlive::audio::RealtimeRunState& state; ~Exit(){state.leave();} } exit{playback};
        if (!cache) return noErr;
        // RemoteIO drives the iPad graph in manual realtime mode. Its nodes
        // only carry sample timestamps; use the physical callback's common
        // clock rather than starting each source on its first render pull.
        auto sourceTime = *time;
        if (jaras::realtimeClock.host && jaras::realtimeClock.rate > 0 &&
            (time->mFlags & kAudioTimeStampSampleTimeValid)) {
            // A rate converter owns a local sample epoch. After it has been
            // gated or reset, dividing that counter by its rate does not give
            // the device timeline. Anchor each scheduled run to the physical
            // callback during preroll (the converter can reset while other
            // sources are connected), then retain sample-accurate progression
            // once PCM starts, including converter lookahead.
            if (!mobileClockAnchored || source == preparedFrame) {
                mobileClockOffset = jaras::realtimeClock.sample / jaras::realtimeClock.rate - time->mSampleTime / sampleRate;
                mobileClockAnchored = true;
            }
            sourceTime.mSampleTime += mobileClockOffset * sampleRate;
        }
        const auto physicalTime = jaras::physicalRenderTime(sourceTime, sampleRate);
        time = &physicalTime;
        const uint64_t start = startHost.load();
        int offset = 0;
        if (time->mFlags & kAudioTimeStampHostTimeValid) {
            if (start > time->mHostTime) {
                const double wait = double(start - time->mHostTime) * [AVAudioTime secondsForHostTime:1] * sampleRate;
                if (wait >= frames) return noErr;
                offset = int(std::ceil(wait));
            }
        }
        double speed = rate.load(), tuning = semitones.load();
        if (timing) timing->read(timingID, timingRun.load(), speed, tuning);
        if (speed != preparedRate || tuning != preparedPitch) {
            const double shift = tuning - 12 * std::log2(speed);
            // Like Windows adoptTiming, retain the already-read input cursor.
            // Rescaling this lookahead would reread/skip PCM on every BPM edit.

            spectral = spectral || std::abs(shift) >= 1e-8;
            preparedRate = speed; preparedPitch = tuning;
            cache->lookaheadPages.store(prefetchPages(speed));
            if (time->mFlags & kAudioTimeStampHostTimeValid) {
                dryClockHost = time->mHostTime + [AVAudioTime hostTimeForSeconds:double(offset) / sampleRate];
                dryClockFrame = source;
                dryNextSample = std::numeric_limits<double>::quiet_NaN();
            }
        }
        if (!spectral && dryClockHost && (time->mFlags & kAudioTimeStampHostTimeValid)) {
            // A live graph edit can miss a render pull for only some tracks.
            // Dry copies must remain on the common host timeline rather than
            // permanently lagging by those missing buffers. No decoding or
            // spectral reset runs here; the prepared lookahead covers the jump.
            const double elapsed = time->mHostTime >= dryClockHost
                ? double(time->mHostTime - dryClockHost) * [AVAudioTime secondsForHostTime:1]
                : -double(dryClockHost - time->mHostTime) * [AVAudioTime secondsForHostTime:1];
            // Once started, the device's sample counter is authoritative.
            // HAL host timestamps can jitter by a few samples even during
            // perfectly continuous rendering; chasing that jitter would add
            // discontinuities. Host time is needed only for onset/epoch reset.
            const bool sampleValid = time->mFlags & kAudioTimeStampSampleTimeValid;
            const bool sampleEpoch = sampleValid && std::isfinite(dryNextSample);
            const double gap = sampleEpoch
                ? time->mSampleTime - dryNextSample : -1;
            const double expected = sampleEpoch && gap >= -1.5
                ? source + std::max(0., gap) * speed
                : dryClockFrame + (elapsed * sampleRate + offset) * speed;
            if (std::abs(expected - source) > 1.5 * speed) {
                const double aligned = speed == 1 ? std::round(expected) : expected;
                ahead += aligned - source;
                source = aligned;
            }
            if (sampleValid) dryNextSample = time->mSampleTime + frames;
        }
        for (int batchStart = offset; batchStart < int(frames);) {
            const int batchCount = std::min(PreparedStretchState::maximumFrames, int(frames) - batchStart);
            if (diagnosticsEnabled && source == preparedFrame) diagnosticFirstFrames.store(batchCount);
            const bool processed = processStretch(speed, tuning, batchCount);
            for (int done = 0; done < batchCount;) {
                const int count = std::min(512, batchCount - done);
                bool ok = processed;
                if (!ok) ++misses;
                const int rampLength = std::max(1, int(std::ceil(sampleRate * .003)));
                if (!ramp || rampFrame >= rampLength) {
                    for (int ch = 0; ch < channels && ch < int(buffers->mNumberBuffers); ++ch) {
                        auto *data = static_cast<float *>(buffers->mBuffers[ch].mData);
                        if (data) std::copy_n(output[std::min(ch, 1)].data() + done, count, data + batchStart + done);
                    }
                } else {
                    for (int n = 0; n < count; ++n) {
                        float gain = 1.f;
                        if (ramp && rampFrame < rampLength) gain *= float(rampFrame++) / float(std::max(1, rampLength - 1));
                        for (int ch = 0; ch < channels && ch < int(buffers->mNumberBuffers); ++ch) {
                            auto *data = static_cast<float *>(buffers->mBuffers[ch].mData);
                            if (data) data[batchStart + done + n] = output[std::min(ch, 1)][done + n] * gain;
                        }
                    }
                }
                done += count;
            }
            batchStart += batchCount;
        }
        position.store(source);
        if (diagnosticsEnabled) {
            diagnosticHistory.store(stretch.handle(), std::memory_order_relaxed);
            diagnosticAhead.store(ahead, std::memory_order_relaxed);
            diagnosticRate.store(speed, std::memory_order_relaxed);
        }
        cache->requested.store(spectral ? std::max(ahead, source) : source);
        return noErr;
    }
};
} // namespace

@implementation JarasPreparedClip {
    std::shared_ptr<PreparedClipKernel> _kernel;
    __weak JarasPreparedClipTiming *_timingOwner;
    AVAudioSourceNode *_node;
}
- (instancetype)initWithFormat:(AVAudioFormat *)format {
    return [self initWithFormat:format timing:nil];
}
- (instancetype)initWithFormat:(AVAudioFormat *)format timing:(JarasPreparedClipTiming *)timing {
    if ((self = [super init])) {
        _kernel = std::make_shared<PreparedClipKernel>(format.sampleRate, int(format.channelCount));
        if (timing) {
            _kernel->timing = [timing preparedTimingState];
            _timingOwner = timing;
            [timing addRenderSource:_kernel];
        }
        auto kernel = _kernel;
        _node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *time, AVAudioFrameCount count, AudioBufferList *buffers) {
            *silent = !kernel->playback.running();
            return kernel->render(time, count, buffers);
        }];
    }
    return self;
}
- (AVAudioSourceNode *)node { return _node; }
- (double)sourcePosition { return _kernel->position.load() / _kernel->sampleRate; }
- (BOOL)playing { return _kernel->playback.running(); }
- (uint64_t)underruns { return _kernel->misses.load(); }
- (NSDictionary<NSString *, NSNumber *> *)processingDiagnostics {
    if (!_kernel->diagnosticsEnabled) return @{};
    return @{@"runs":@(_kernel->diagnosticRuns.load()), @"hits":@(_kernel->diagnosticHits.load()),
        @"history":@(_kernel->diagnosticHistory.load()), @"ahead":@(_kernel->diagnosticAhead.load()),
        @"rate":@(_kernel->diagnosticRate.load()), @"onset":@(_kernel->startHost.load()),
        @"preparedFrame":@(_kernel->preparedFrame), @"end":@(_kernel->endFrame.load()),
        @"firstFrames":@(_kernel->diagnosticFirstFrames.load()),
        @"group":@(reinterpret_cast<uintptr_t>(_kernel->stretchGroup.get()))};
}
- (BOOL)prepareURL:(NSURL *)url sourceFrame:(double)frame endFrame:(double)end rate:(double)rate pitch:(double)pitch loopStart:(double)loopStart loopEnd:(double)loopEnd error:(NSError **)error {
    if (!std::isfinite(frame) || !std::isfinite(end) || !std::isfinite(rate) || !std::isfinite(pitch) ||
        !std::isfinite(loopStart) || !std::isfinite(loopEnd) || frame < 0 || end < frame || rate <= 0 || rate > 32) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.PreparedAudio" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Invalid source playback range or rate"}];
        return NO;
    }
    std::lock_guard<std::mutex> lock(_kernel->preparation);
    _kernel->playback.stop();
    _kernel->playback.waitStopped();
    auto &cache = _kernel->cache;
    if (_kernel->prepared && cache && [cache->url isEqual:url] && _kernel->source == frame && _kernel->preparedFrame == frame &&
        _kernel->preparedRate == rate && _kernel->preparedPitch == pitch && _kernel->endFrame.load() == end &&
        cache->loopStart.load() == loopStart && cache->loopEnd.load() == loopEnd) {
        cache->active.store(true);
        PreparedPCMWorkers::shared().requestWake();
        return YES;
    }
    _kernel->prepared = false;
    ++_kernel->timingRun;
    if (cache) cache->active.store(false);
    if (!cache || ![cache->url isEqual:url]) {
        auto reader = PreparedPCMReader::open(url, error);
        if (!reader) return NO;
        cache = std::make_shared<PreparedPCMCache>(std::move(reader));
        PreparedPCMWorkers::shared().add(cache);
    }
    _kernel->configureStretchGroup();
    {
        // Publish a coherent preparation only while the worker is excluded.
        // Leave it inactive if synchronous preparation or priming fails.
        std::lock_guard<std::mutex> decoderLock(cache->decoder);
        cache->loopStart.store(loopStart); cache->loopEnd.store(loopEnd);
        cache->requested.store(frame);
        cache->lookaheadPages.store(_kernel->prefetchPages(rate));
    }
    _kernel->endFrame.store(end); _kernel->rate.store(rate); _kernel->semitones.store(pitch);
    const double lookahead = _kernel->seekFrames * rate;
    const double pageOffset = std::fmod(cache->wrapped(frame), double(PreparedPCMCache::pageSize));
    const int initialPages = std::clamp(int(std::ceil((pageOffset + lookahead + 2) / PreparedPCMCache::pageSize)) + 1,
                                        cache->lookaheadPages.load(), PreparedPCMCache::pageCount);
    if (cache->prefetch(initialPages, error) != PreparedPCMCache::Prefetch::ready) return NO;
    if (!_kernel->prime(frame, rate, pitch)) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.PreparedAudio" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not prepare source audio"}];
        return NO;
    }
    _kernel->prepared = true;
    cache->active.store(true);
    PreparedPCMWorkers::shared().requestWake();
    return YES;
}
- (void)startAtHostTime:(uint64_t)host ramp:(BOOL)ramp {
    std::lock_guard<std::mutex> lock(_kernel->preparation);
    _kernel->playback.stop();
    _kernel->playback.waitStopped();
    if (!_kernel->prepared) return;
    _kernel->ramp = ramp; _kernel->rampFrame = 0;
    _kernel->mobileClockAnchored = false;
    _kernel->startHost.store(host);
    _kernel->dryClockHost = host;
    _kernel->dryClockFrame = _kernel->source;
    _kernel->dryNextSample = std::numeric_limits<double>::quiet_NaN();
    if (_kernel->cache) _kernel->cache->active.store(true);
    PreparedPCMWorkers::shared().requestWake();
    _kernel->playback.start();
}
- (void)setRate:(double)rate pitch:(double)pitch {
    if (!std::isfinite(rate) || rate <= 0 || rate > 32 || !std::isfinite(pitch)) return;
    if (_kernel->timing) _kernel->timing->set(_kernel->timingID, {_kernel->timingRun.load(), rate, pitch});
    else { _kernel->rate.store(rate); _kernel->semitones.store(pitch); }
}
- (void)setEndFrame:(double)end { _kernel->endFrame.store(end); }
- (void)stop {
    _kernel->playback.stop();
    if (_kernel->cache) _kernel->cache->active.store(false);
}
- (void)dealloc { [self stop]; [_timingOwner removeRenderSource:_kernel.get()]; }
@end
#endif
