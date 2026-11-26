// Included by JarasEffects.mm. The source is connected once, before playback.
// Each slot has one control-thread producer and one audio-thread consumer.
namespace {
struct PadSourceState {
    static constexpr size_t capacity = 128;
    struct Voice {
        std::atomic<bool> playing{false}, cancelled{false}, releasing{false};
        std::atomic<float> gain{1};
        // The producer only changes these after acquiring playing == false.
        // The consumer publishes false after its last access to PCM/state.
        const float *left = nullptr, *right = nullptr;
        uint32_t frames = 0;
        double position = 0, step = 1;
        jaras::PadGateRelease envelope;
    };
    std::array<Voice, capacity> voices;
    // Ownership and tokens are control-thread only. No ARC in render().
    std::array<AVAudioPCMBuffer *__strong, capacity> owners{};
    std::array<uint64_t, capacity> tokens{};
    uint64_t nextToken = 0;
    double rate;
    explicit PadSourceState(double sampleRate) : rate(sampleRate) {}
    Voice *find(uint64_t token) {
        if (token) for (size_t i = 0; i < capacity; ++i)
            if (tokens[i] == token) return &voices[i];
        return nullptr;
    }
    uint64_t play(AVAudioPCMBuffer *buffer, float gain) {
        if (!buffer.frameLength || !buffer.floatChannelData || buffer.format.isInterleaved ||
            buffer.format.sampleRate <= 0 || !std::isfinite(gain)) return 0;
        for (size_t i = 0; i < capacity; ++i) {
            auto &v = voices[i];
            if (v.playing.load(std::memory_order_acquire)) continue;
            owners[i] = buffer;
            v.left = buffer.floatChannelData[0];
            v.right = buffer.floatChannelData[buffer.format.channelCount > 1 ? 1 : 0];
            v.frames = buffer.frameLength; v.position = 0;
            v.step = buffer.format.sampleRate / rate; v.envelope = {};
            v.cancelled.store(false); v.releasing.store(false); v.gain.store(gain);
            tokens[i] = ++nextToken;
            v.playing.store(true, std::memory_order_release);
            return tokens[i];
        }
        return 0; // Never steal or truncate a sounding pad.
    }
    bool render(uint32_t frames, float *left, float *right) {
        bool silent = true;
        for (auto &v : voices) {
            if (!v.playing.load(std::memory_order_acquire)) continue;
            if (v.cancelled.load()) { v.playing.store(false, std::memory_order_release); continue; }
            if (v.releasing.load()) v.envelope.begin(rate);
            const auto gain = v.gain.load();
            silent = false;
            for (uint32_t f = 0; f < frames && v.position < v.frames && !v.envelope.finished(); ++f) {
                const auto a = uint32_t(v.position), b = std::min(a + 1, v.frames - 1);
                const auto fraction = float(v.position - a), level = gain * v.envelope.next();
                left[f] += (v.left[a] + (v.left[b] - v.left[a]) * fraction) * level;
                right[f] += (v.right[a] + (v.right[b] - v.right[a]) * fraction) * level;
                v.position += v.step;
            }
            if (v.position >= v.frames || v.envelope.finished())
                v.playing.store(false, std::memory_order_release);
        }
        return silent;
    }
};
}

@implementation JarasPadSource {
    std::shared_ptr<PadSourceState> _state;
    AVAudioSourceNode *_node;
}
- (instancetype)initWithFormat:(AVAudioFormat *)format {
    if ((self = [super init])) {
        _state = std::make_shared<PadSourceState>(format.sampleRate);
        auto state = _state;
        _node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
            ^OSStatus(BOOL *silent, const AudioTimeStamp *, AVAudioFrameCount frames, AudioBufferList *buffers) {
                for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
                    if (buffers->mBuffers[i].mData)
                        memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
                if (buffers->mNumberBuffers != 2 || !buffers->mBuffers[0].mData || !buffers->mBuffers[1].mData)
                    return kAudio_ParamError;
                *silent = state->render(frames, (float *)buffers->mBuffers[0].mData, (float *)buffers->mBuffers[1].mData);
                return noErr;
            }];
    }
    return self;
}
- (AVAudioSourceNode *)node { return _node; }
- (uint64_t)playBuffer:(AVAudioPCMBuffer *)buffer gain:(float)gain { return _state->play(buffer, gain); }
- (BOOL)isPlaying:(uint64_t)token { auto *v = _state->find(token); return v && v->playing.load(std::memory_order_acquire); }
- (void)reclaimFinishedBuffers {
    for (size_t i = 0; i < PadSourceState::capacity; ++i)
        if (!_state->voices[i].playing.load(std::memory_order_acquire)) _state->owners[i] = nil;
}
- (void)stopVoice:(uint64_t)token { if (auto *v = _state->find(token)) v->cancelled.store(true); }
- (void)releaseVoice:(uint64_t)token { if (auto *v = _state->find(token)) v->releasing.store(true); }
- (void)setVoice:(uint64_t)token gain:(float)gain { if (std::isfinite(gain)) if (auto *v = _state->find(token)) v->gain.store(gain); }
@end
