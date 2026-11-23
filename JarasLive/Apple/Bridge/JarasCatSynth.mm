#import "JarasCatSynth.h"
#include "CatMIDISequenceBridge.h"
#include "../../Core/Audio/CatSynth.hpp"

namespace {
struct SynthRenderer {
    jaras::audio::CatSynth synth;
    CatMIDISequence sequence;
    double rate;
    explicit SynthRenderer(double sampleRate) : synth(sampleRate), rate(sampleRate) {}
    void process(const AudioTimeStamp *time, unsigned frames, float *left, float *right) {
        std::fill_n(left, frames, 0.f);
        std::fill_n(right, frames, 0.f);
        synth.beginBlock();
        catRenderMIDISequence(sequence, time, rate, frames);
        unsigned cursor = 0;
        for (unsigned i = 0; i < sequence.count; ++i) {
            const auto &event = sequence.events[i];
            const auto next = std::clamp(event.offset, cursor, frames);
            if (next > cursor) synth.render(left + cursor, right + cursor, next - cursor);
            cursor = next;
            synth.midi(event.status, event.pitch, event.velocity, true);
        }
        if (frames > cursor) synth.render(left + cursor, right + cursor, frames - cursor);
        synth.publishScreenVoiceActivity();
    }
};
}

@implementation JarasCatSynth {
    std::shared_ptr<SynthRenderer> _renderer;
}
- (instancetype)initWithSampleRate:(double)rate {
    if ((self = [super init])) {
        auto renderer = std::make_shared<SynthRenderer>(rate);
        _renderer = renderer;
        _mix = [[AVAudioMixerNode alloc] init];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
        _node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent,
                const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *out) {
            if (out->mNumberBuffers != 2 || !out->mBuffers[0].mData || !out->mBuffers[1].mData)
                return kAudio_ParamError;
            renderer->process(time, frames, (float *)out->mBuffers[0].mData, (float *)out->mBuffers[1].mData);
            *silent = NO;
            return noErr;
        }];
    }
    return self;
}
+ (NSArray<NSNumber *> *)factoryPatch:(NSUInteger)index {
    const auto values = jaras::audio::CatSynth::factory(unsigned(index));
    auto patch = [NSMutableArray arrayWithCapacity:values.size()];
    for (auto value : values) [patch addObject:@(value)];
    return patch;
}
- (void)configurePatch:(NSArray<NSNumber *> *)values enabled:(BOOL)enabled {
    auto patch = jaras::audio::CatSynth::factory(0);
    if (values.count == patch.size()) {
        for (unsigned i = 0; i < patch.size(); ++i) patch[i] = values[i].floatValue;
    }
    _renderer->synth.configure(patch);
    _renderer->synth.setEnabled(enabled);
}
- (void)receiveStatus:(uint8_t)status key:(uint8_t)key value:(uint8_t)value { _renderer->synth.send(status, key, value); }
- (void)screenKey:(NSUInteger)key velocity:(NSUInteger)velocity { _renderer->synth.screenKey(unsigned(key), unsigned(velocity)); }
- (BOOL)keyIsActive:(NSUInteger)key { return _renderer->synth.keyIsActive(unsigned(key)); }
- (BOOL)screenVoiceIsActive { return _renderer->synth.screenVoiceIsActive(); }
- (void)silence { _renderer->synth.silence(); }
- (void)setSequenceNotes:(NSArray<NSDictionary *> *)notes { _renderer->sequence.setNotes(catMIDINotes(notes)); }
- (void)sequenceHead:(int)head position:(double)p clock:(double)c running:(BOOL)run loopStart:(double)a loopEnd:(double)b {
    _renderer->sequence.configure(head,p,c,run,a,b);
}
@end
