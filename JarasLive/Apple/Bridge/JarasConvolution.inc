#define AUDIOFFT_APPLE_ACCELERATE
#include "ThirdParty/FFTConvolver/AudioFFT.inc"
#include "ThirdParty/FFTConvolver/Utilities.inc"
#include "ThirdParty/FFTConvolver/FFTConvolver.inc"
#include "ThirdParty/FFTConvolver/TwoStageFFTConvolver.inc"
#undef AUDIOFFT_APPLE_ACCELERATE

namespace {
struct ConvolutionResponse {
    fftconvolver::TwoStageFFTConvolver channels[2];
    double duration = 0;
};

std::unique_ptr<ConvolutionResponse> prepareConvolution(NSURL *url, double rate) {
    if (!url || !std::isfinite(rate) || rate < 8000 || rate > 384000) return {};
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url
            commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
        const double sourceRate = file.processingFormat.sampleRate;
        const auto count = file.length;
        const auto channels = file.processingFormat.channelCount;
        if (!file || channels < 1 || channels > 2 || !std::isfinite(sourceRate) ||
            sourceRate < 8000 || sourceRate > 384000 || count < 1 || count > sourceRate * 10) return {};
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
            frameCapacity:static_cast<AVAudioFrameCount>(count)];
        if (!pcm || ![file readIntoBuffer:pcm error:nil] || !pcm.floatChannelData || !pcm.frameLength) return {};

        const auto length = static_cast<size_t>(std::ceil(pcm.frameLength * rate / sourceRate));
        std::vector<float> samples[2];
        double largestEnergy = 0;
        for (size_t channel = 0; channel < channels; ++channel) {
            const float *input = pcm.floatChannelData[channel];
            samples[channel].resize(length);
            double energy = 0;
            for (size_t frame = 0; frame < length; ++frame) {
                const double offset = std::min<double>(pcm.frameLength - 1, frame * sourceRate / rate);
                const auto index = static_cast<size_t>(offset);
                const float fraction = static_cast<float>(offset - index);
                const float sample = input[index] * (1 - fraction) + input[std::min<size_t>(index + 1, pcm.frameLength - 1)] * fraction;
                if (!std::isfinite(sample)) return {};
                samples[channel][frame] = sample;
                energy += static_cast<double>(sample) * sample;
            }
            largestEnergy = std::max(largestEnergy, energy);
        }
        if (largestEnergy <= 1e-12) return {};
        const auto gain = static_cast<float>(0.70 / std::sqrt(largestEnergy));
        for (auto& channel : samples)
            for (auto& sample : channel) sample *= gain;

        auto response = std::make_unique<ConvolutionResponse>();
        for (size_t channel = 0; channel < 2; ++channel) {
            const auto& impulse = samples[std::min<size_t>(channel, channels - 1)];
            if (!response->channels[channel].init(128, 4096, impulse.data(), impulse.size())) return {};
        }
        response->duration = length / rate;
        return response;
    }
}

struct ConvolutionKernel {
    std::atomic<bool> enabled{false}, resetRequested{false};
    std::atomic<float> mix{0.2f};
    std::atomic<double> tail{0};
    // The control side owns all responses. The render thread never allocates,
    // destroys a response, or waits for the loader.
    std::atomic<ConvolutionResponse*> published{nullptr}, acquiring{nullptr}, playing{nullptr};
    std::unique_ptr<ConvolutionResponse> response;
    std::vector<std::unique_ptr<ConvolutionResponse>> retired;
    ConvolutionResponse *active = nullptr;
    std::array<float, 256> wet{};
    float currentMix = 0, smoothing = 1;
    bool needsReset = true;

    void publish(std::unique_ptr<ConvolutionResponse> next) {
        if (response) retired.reserve(retired.size() + 1);
        auto previous = std::move(response);
        response = std::move(next);
        tail.store(response ? response->duration : 0, std::memory_order_relaxed);
        published.store(response.get());
        if (previous) retired.push_back(std::move(previous));
        // Read acquiring before playing. The render thread promotes in the
        // opposite order and keeps the response pinned between blocks.
        retired.erase(std::remove_if(retired.begin(), retired.end(), [&](const auto& candidate) {
            return candidate.get() != acquiring.load() && candidate.get() != playing.load();
        }), retired.end());
    }

    void process(AudioBufferList *buffers, size_t frames) {
        const bool reset = resetRequested.exchange(false, std::memory_order_relaxed);
        const float target = enabled.load(std::memory_order_relaxed) ? mix.load(std::memory_order_relaxed) : 0;
        auto *candidate = published.load();
        acquiring.store(candidate);
        if (candidate == published.load() && candidate != active) {
            active = candidate;
            playing.store(active);
            needsReset = true;
        }
        acquiring.store(nullptr);
        if (!active) return;
        if (reset) needsReset = true;
        if (target == 0 && (currentMix < 0.0001f || reset)) {
            currentMix = 0;
            needsReset = true;
            return;
        }
        if (needsReset) {
            for (auto& channel : active->channels) channel.clearHistory();
            currentMix = target;
            needsReset = false;
        }
        const auto channels = std::min<UInt32>(buffers->mNumberBuffers, 2);
        float finalMix = currentMix;
        for (UInt32 channel = 0; channel < channels; ++channel) {
            auto *signal = static_cast<float*>(buffers->mBuffers[channel].mData);
            if (!signal || buffers->mBuffers[channel].mNumberChannels != 1) continue;
            float wetMix = currentMix;
            for (size_t offset = 0; offset < frames; offset += wet.size()) {
                const auto count = std::min(wet.size(), frames - offset);
                active->channels[channel].process(signal + offset, wet.data(), count);
                for (size_t i = 0; i < count; ++i) {
                    wetMix += (target - wetMix) * smoothing;
                    signal[offset + i] += (wet[i] - signal[offset + i]) * wetMix;
                }
            }
            finalMix = wetMix;
        }
        currentMix = finalMix;
    }
};

dispatch_queue_t convolutionLoader() {
    static dispatch_queue_t queue = dispatch_queue_create("CatLive.convolution", DISPATCH_QUEUE_SERIAL);
    return queue;
}
} // namespace

@interface JarasConvolutionUnit : AUAudioUnit {
@public ConvolutionKernel kernel;
    AUAudioUnitBus *_input, *_output;
    AUAudioUnitBusArray *_inputs, *_outputs;
    NSURL *_responseURL;
    double _responseRate;
    uint64_t _loadGeneration;
}
- (void)configureEnabled:(BOOL)enabled mix:(float)mix response:(NSURL *)url;
@end

@implementation JarasConvolutionUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                       options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    if ((self = [super initWithComponentDescription:description options:options error:error])) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        _input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        _output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        if (!_input || !_output) return nil;
        _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];
        _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
    }
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (NSTimeInterval)tailTime {
    return kernel.enabled.load(std::memory_order_relaxed) ? kernel.tail.load(std::memory_order_relaxed) : 0;
}
- (void)reset { [super reset]; kernel.resetRequested.store(true, std::memory_order_relaxed); }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    @synchronized (self) {
        ++_loadGeneration;
        _responseRate = _output.format.sampleRate;
        kernel.smoothing = 1 - std::exp(-1.0 / (0.02 * _responseRate));
        kernel.needsReset = true;
        try { kernel.publish(prepareConvolution(_responseURL, _responseRate)); }
        catch (...) { return NO; }
    }
    return YES;
}
- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    @synchronized (self) { ++_loadGeneration; _responseRate = 0; }
}
- (void)configureEnabled:(BOOL)enabled mix:(float)mix response:(NSURL *)url {
    kernel.enabled.store(enabled, std::memory_order_relaxed);
    kernel.mix.store(std::isfinite(mix) ? std::clamp(mix, 0.0f, 1.0f) : 0, std::memory_order_relaxed);
    @synchronized (self) {
        if (_responseURL == url || [_responseURL isEqual:url]) return;
        _responseURL = [url copy];
        const auto rate = _responseRate;
        const auto generation = ++_loadGeneration;
        if (!rate) return;
        __weak JarasConvolutionUnit *weakSelf = self;
        dispatch_async(convolutionLoader(), ^{
            JarasConvolutionUnit *unit = weakSelf;
            if (!unit) return;
            @synchronized (unit) { if (generation != unit->_loadGeneration) return; }
            try {
                auto next = prepareConvolution(url, rate);
                @synchronized (unit) {
                    if (generation == unit->_loadGeneration) unit->kernel.publish(std::move(next));
                }
            } catch (...) { /* Keep the current response if preparation runs out of memory. */ }
        });
    }
}
- (AUInternalRenderBlock)internalRenderBlock {
    auto *state = &kernel;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
        AVAudioFrameCount frames, NSInteger bus, AudioBufferList *output, const AURenderEvent *events,
        AURenderPullInputBlock pull) {
        ScopedAudioDenormals denormals;
        if (!pull) return kAudioUnitErr_NoConnection;
        const auto result = pull(flags, time, frames, 0, output);
        if (result == noErr) {
            state->process(output, frames);
            updateEffectSilenceFlag(flags, output, frames);
        }
        return result;
    };
}
@end

@implementation JarasConvolution
+ (AVAudioUnitEffect *)makeNode {
    AudioComponentDescription description = {kAudioUnitType_Effect, 'JLCV', 'Jras', 0, 0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:JarasConvolutionUnit.class asComponentDescription:description
            name:@"CatLive Reverb-Convolution" version:1];
    });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description];
}
+ (void)configure:(AVAudioUnitEffect *)node enabled:(BOOL)enabled mix:(float)mix response:(NSURL *)url {
    [(JarasConvolutionUnit *)node.AUAudioUnit configureEnabled:enabled mix:mix response:url];
}
@end
