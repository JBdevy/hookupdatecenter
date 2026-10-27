// Included by JarasEffects.mm. Only file playback uses this source; live inputs
// and plug-in routing stay on AVAudioEngine's existing graph.
#if TARGET_OS_OSX
#include "../../Windows/ThirdParty/Signalsmith/signalsmith-stretch.h"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>

namespace {
struct PreparedPCMPage {
    int64_t first = 0;
    int count = 0;
    std::array<std::vector<float>, 2> samples;
};

struct PreparedPCMCache {
    // Slots are cheap until populated. Ordinary playback keeps six pages;
    // very high source rates/speeds need a larger initial FFT lookahead.
    static constexpr int pageSize = 32768, pageCount = 64;
    AVAudioFile *__strong file;
    NSURL *__strong url;
    int64_t length;
    double sampleRate;
    std::mutex decoder;
    std::array<std::shared_ptr<PreparedPCMPage>, pageCount> pages;
    // Keep retired pages alive until no render callback references them. Their
    // storage is reclaimed on the decoder/control thread, never on audio.
    std::deque<std::shared_ptr<PreparedPCMPage>> retired;
    std::atomic<double> requested{0}, loopStart{0}, loopEnd{0};
    std::atomic<bool> active{false};

    PreparedPCMCache(AVAudioFile *f) : file(f), url(f.url), length(f.length), sampleRate(f.processingFormat.sampleRate) {}
    double wrapped(double frame) const {
        const double start = loopStart.load(), end = loopEnd.load();
        if (end > start && frame >= start) return start + std::fmod(frame - start, end - start);
        return frame;
    }
    std::shared_ptr<PreparedPCMPage> pageAt(int64_t first) const {
        for (const auto &slot : pages) {
            auto page = std::atomic_load(&slot);
            if (page && page->first == first) return page;
        }
        return {};
    }
    bool prefetch(int count, NSError **error = nullptr) {
        // Physical pages on opposite sides of a loop can have the same ring
        // index. Keep the whole lookahead set resident instead of letting one
        // side evict the other (also handles loops not aligned to page edges).
        std::lock_guard<std::mutex> lock(decoder);
        std::vector<int64_t> wanted;
        double frame = wrapped(requested.load());
        const double start = loopStart.load(), end = loopEnd.load();
        for (int i = 0; i < count; ++i) {
            const int64_t first = int64_t(std::max(0., frame)) / pageSize * pageSize;
            if (first >= length || std::find(wanted.begin(), wanted.end(), first) != wanted.end()) break;
            wanted.push_back(first);
            const double next = double(first + pageSize);
            frame = end > start && next >= end ? start : next;
        }
        for (const auto first : wanted) {
            if (pageAt(first)) continue;
            size_t slot = 0;
            for (; slot < pages.size(); ++slot) {
                auto page = std::atomic_load(&pages[slot]);
                if (!page || std::find(wanted.begin(), wanted.end(), page->first) == wanted.end()) break;
            }
            if (slot == pages.size()) return false;
            auto page = std::make_shared<PreparedPCMPage>();
            page->first = first;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:pageSize];
            file.framePosition = first;
            if (![file readIntoBuffer:buffer frameCount:pageSize error:error]) return false;
            page->count = int(buffer.frameLength);
            for (int channel = 0; channel < 2; ++channel) {
                const float *data = buffer.floatChannelData[std::min(channel, int(buffer.format.channelCount) - 1)];
                page->samples[channel].resize(page->count);
                for (int n = 0; n < page->count; ++n) page->samples[channel][n] = data[n * buffer.stride];
            }
            if (auto old = std::atomic_exchange(&pages[slot], page)) retired.push_back(std::move(old));
        }
        for (auto it = retired.begin(); it != retired.end();) {
            if (it->use_count() == 1) it = retired.erase(it); else ++it;
        }
        return true;
    }
};

class PreparedPCMWorkers {
    std::mutex mutex;
    std::condition_variable wake;
    bool closing = false;
    std::vector<std::weak_ptr<PreparedPCMCache>> caches;
    std::thread thread;
    PreparedPCMWorkers() : thread([this] {
        std::unique_lock<std::mutex> lock(mutex);
        while (!closing) {
            std::vector<std::shared_ptr<PreparedPCMCache>> work;
            for (auto it = caches.begin(); it != caches.end();) {
                if (auto cache = it->lock()) { if (cache->active.load()) work.push_back(cache); ++it; }
                else it = caches.erase(it);
            }
            lock.unlock();
            @autoreleasepool { for (auto &cache : work) cache->prefetch(6); }
            lock.lock();
            wake.wait_for(lock, std::chrono::milliseconds(10), [this] { return closing; });
        }
    }) {}
public:
    static PreparedPCMWorkers &shared() { static PreparedPCMWorkers workers; return workers; }
    void add(const std::shared_ptr<PreparedPCMCache> &cache) { std::lock_guard<std::mutex> lock(mutex); caches.push_back(cache); wake.notify_one(); }
    ~PreparedPCMWorkers() { { std::lock_guard<std::mutex> lock(mutex); closing = true; } wake.notify_one(); thread.join(); }
};

struct PreparedClipKernel {
    const double sampleRate;
    const int channels;
    std::shared_ptr<PreparedPCMCache> cache;
    std::mutex preparation;
    signalsmith::stretch::SignalsmithStretch<float> pitch{0};
    std::array<std::vector<float>, 2> input, output;
    std::atomic<bool> running{false};
    std::atomic<uint64_t> startHost{0}, misses{0};
    std::atomic<double> rate{1}, semitones{0}, endFrame{0}, position{0};
    double source = 0, ahead = 0, preparedFrame = -1, preparedRate = 1, preparedPitch = 0;
    bool spectral = false, ramp = false;
    int rampFrame = 0;
    PreparedClipKernel(double sr, int ch) : sampleRate(sr), channels(ch) {
        pitch.presetDefault(2, float(sr));
        const int capacity = std::max(8192, pitch.outputSeekLength(1.f));
        for (auto &buffer : input) buffer.resize(capacity);
        for (auto &buffer : output) buffer.resize(512);
    }
    bool read(double first, double step, int frames, float *left, float *right) {
        if (!cache) return false;
        std::array<std::shared_ptr<PreparedPCMPage>, PreparedPCMCache::pageCount> leases;
        bool ok = true;
        auto value = [&](int64_t frame, int channel) -> float {
            if (frame < 0 || frame >= cache->length) return 0;
            const int64_t pageFirst = frame / PreparedPCMCache::pageSize * PreparedPCMCache::pageSize;
            const int slot = int(frame / PreparedPCMCache::pageSize % PreparedPCMCache::pageCount);
            auto &page = leases[slot];
            if (!page || page->first != pageFirst) page = cache->pageAt(pageFirst);
            if (!page || page->first != pageFirst) { ok = false; return 0; }
            const auto index = frame - pageFirst;
            return index < page->count ? page->samples[channel][size_t(index)] : 0;
        };
        const double end = endFrame.load();
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
    bool prime(double frame, double speed, double tuning) {
        source = ahead = frame;
        spectral = std::abs(tuning - 12 * std::log2(speed)) >= 1e-8;
        pitch.reset();
        // Keep a zero-shift spectral history ready even while emitting exact
        // dry PCM. Priming 24 FFT histories together on the first live BPM edit
        // would otherwise exceed one hardware callback and create a dropout.
        pitch.setTransposeSemitones(float(tuning - 12 * std::log2(speed)));
        const int count = pitch.outputSeekLength(1.f);
        if (!read(frame, speed, count, input[0].data(), input[1].data())) return false;
        const float *pointers[]{input[0].data(), input[1].data()};
        pitch.outputSeek(pointers, count);
        ahead += count * speed;
        preparedFrame = frame; preparedRate = speed; preparedPitch = tuning;
        position.store(frame); rampFrame = 0;
        return true;
    }
    OSStatus render(const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *buffers) {
        for (UInt32 ch = 0; ch < buffers->mNumberBuffers; ++ch)
            if (buffers->mBuffers[ch].mData) memset(buffers->mBuffers[ch].mData, 0, buffers->mBuffers[ch].mDataByteSize);
        if (!running.load(std::memory_order_acquire)) return noErr;
        std::unique_lock<std::mutex> lock(preparation, std::try_to_lock);
        if (!lock.owns_lock() || !running.load() || !cache) return noErr;
        const uint64_t start = startHost.load();
        int offset = 0;
        if (time->mFlags & kAudioTimeStampHostTimeValid) {
            if (start > time->mHostTime) {
                const double wait = double(start - time->mHostTime) * [AVAudioTime secondsForHostTime:1] * sampleRate;
                if (wait >= frames) return noErr;
                offset = int(std::ceil(wait));
            }
        }
        const double speed = rate.load(), tuning = semitones.load();
        if (speed != preparedRate || tuning != preparedPitch) {
            const double shift = tuning - 12 * std::log2(speed);
            pitch.setTransposeSemitones(float(shift));
            // Like Windows adoptTiming, retain the already-read input cursor.
            // Rescaling this lookahead would reread/skip PCM on every BPM edit.

            spectral = spectral || std::abs(shift) >= 1e-8;
            preparedRate = speed; preparedPitch = tuning;
        }
        for (int done = offset; done < int(frames);) {
            const int count = std::min(512, int(frames) - done);
            bool ok = read(ahead, speed, count, input[0].data(), input[1].data());
            const float *inputs[]{input[0].data(), input[1].data()};
            float *outputs[]{output[0].data(), output[1].data()};
            pitch.process(inputs, count, outputs, count);
            ahead += count * speed;
            if (!spectral) ok = read(source, speed, count, output[0].data(), output[1].data()) && ok;
            if (!ok) ++misses;
            const int rampLength = std::max(1, int(std::ceil(sampleRate * .003)));
            for (int n = 0; n < count; ++n) {
                float gain = source + n * speed >= endFrame.load() ? 0.f : 1.f;
                if (ramp && rampFrame < rampLength) gain *= float(rampFrame++) / float(std::max(1, rampLength - 1));
                for (int ch = 0; ch < channels && ch < int(buffers->mNumberBuffers); ++ch) {
                    auto *data = static_cast<float *>(buffers->mBuffers[ch].mData);
                    if (data) data[done + n] = output[std::min(ch, 1)][n] * gain;
                }
            }
            source += count * speed;
            done += count;
        }
        position.store(source);
        cache->requested.store(spectral ? std::max(ahead, source) : source);
        return noErr;
    }
};
} // namespace

@implementation JarasPreparedClip {
    std::shared_ptr<PreparedClipKernel> _kernel;
    AVAudioSourceNode *_node;
}
- (instancetype)initWithFormat:(AVAudioFormat *)format {
    if ((self = [super init])) {
        _kernel = std::make_shared<PreparedClipKernel>(format.sampleRate, int(format.channelCount));
        auto kernel = _kernel;
        _node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *time, AVAudioFrameCount count, AudioBufferList *buffers) {
            *silent = !kernel->running.load();
            return kernel->render(time, count, buffers);
        }];
    }
    return self;
}
- (AVAudioSourceNode *)node { return _node; }
- (double)sourcePosition { return _kernel->position.load() / _kernel->sampleRate; }
- (BOOL)playing { return _kernel->running.load(); }
- (uint64_t)underruns { return _kernel->misses.load(); }
- (BOOL)prepareURL:(NSURL *)url sourceFrame:(double)frame endFrame:(double)end rate:(double)rate pitch:(double)pitch loopStart:(double)loopStart loopEnd:(double)loopEnd error:(NSError **)error {
    if (!std::isfinite(frame) || !std::isfinite(end) || !std::isfinite(rate) || !std::isfinite(pitch) ||
        !std::isfinite(loopStart) || !std::isfinite(loopEnd) || frame < 0 || end < frame || rate <= 0 || rate > 32) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.PreparedAudio" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Invalid source playback range or rate"}];
        return NO;
    }
    _kernel->running.store(false);
    std::lock_guard<std::mutex> lock(_kernel->preparation);
    auto &cache = _kernel->cache;
    if (cache && [cache->url isEqual:url] && _kernel->source == frame && _kernel->preparedFrame == frame &&
        _kernel->preparedRate == rate && _kernel->preparedPitch == pitch && _kernel->endFrame.load() == end &&
        cache->loopStart.load() == loopStart && cache->loopEnd.load() == loopEnd) {
        cache->active.store(true);
        return YES;
    }
    if (!cache || ![cache->url isEqual:url]) {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
        if (!file) return NO;
        cache = std::make_shared<PreparedPCMCache>(file);
        PreparedPCMWorkers::shared().add(cache);
    }
    cache->loopStart.store(loopStart); cache->loopEnd.store(loopEnd);
    cache->requested.store(frame); cache->active.store(true);
    _kernel->endFrame.store(end); _kernel->rate.store(rate); _kernel->semitones.store(pitch);
    const double lookahead = _kernel->pitch.outputSeekLength(1.f) * rate;
    const double pageOffset = std::fmod(cache->wrapped(frame), double(PreparedPCMCache::pageSize));
    const int initialPages = std::clamp(int(std::ceil((pageOffset + lookahead + 2) / PreparedPCMCache::pageSize)) + 1,
                                        6, PreparedPCMCache::pageCount);
    if (!cache->prefetch(initialPages, error)) return NO;
    if (!_kernel->prime(frame, rate, pitch)) {
        if (error) *error = [NSError errorWithDomain:@"CatLive.PreparedAudio" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not prepare source audio"}];
        return NO;
    }
    return YES;
}
- (void)startAtHostTime:(uint64_t)host ramp:(BOOL)ramp {
    std::lock_guard<std::mutex> lock(_kernel->preparation);
    _kernel->ramp = ramp; _kernel->rampFrame = 0;
    _kernel->startHost.store(host);
    if (_kernel->cache) _kernel->cache->active.store(true);
    _kernel->running.store(true, std::memory_order_release);
}
- (void)setRate:(double)rate pitch:(double)pitch {
    if (!std::isfinite(rate) || rate <= 0 || rate > 32 || !std::isfinite(pitch)) return;
    _kernel->rate.store(rate); _kernel->semitones.store(pitch);
}
- (void)setEndFrame:(double)end { _kernel->endFrame.store(end); }
- (void)stop {
    _kernel->running.store(false, std::memory_order_release);
    if (_kernel->cache) _kernel->cache->active.store(false);
}
- (void)dealloc { [self stop]; }
@end
#endif
