#import "JarasDrummerPad.h"
#include "CatMIDISequenceBridge.h"
#include "../../Core/Audio/DrummerPad.hpp"

namespace {
struct PadRenderer {
    jaras::audio::DrummerPad kit;
    CatMIDISequence sequence;
    double rate;
    PadRenderer(unsigned count, double rate) : kit(count, rate), rate(rate) {}
    void process(const AudioTimeStamp *time, unsigned frames, AudioBufferList *buffers) {
        float *left = static_cast<float *>(buffers->mBuffers[0].mData);
        float *right = static_cast<float *>(buffers->mBuffers[1].mData);
        std::fill_n(left, frames, 0.f); std::fill_n(right, frames, 0.f);
        catRenderMIDISequence(sequence, time, rate, frames);
        unsigned cursor = 0;
        for (unsigned i = 0; i < sequence.count; ++i) {
            const auto &e = sequence.events[i];
            const unsigned next = std::min(frames, std::max(cursor, unsigned(e.offset)));
            if (next > cursor) kit.render(left + cursor, right + cursor, next - cursor);
            cursor = next;
            if ((e.status & 0xf0) == 0x90) kit.midi(e.pitch, e.velocity);
        }
        if (frames > cursor) kit.render(left + cursor, right + cursor, frames - cursor);
    }
};
}
@implementation JarasDrummerPad {
    std::shared_ptr<PadRenderer> _renderer;
}
- (instancetype)initWithCount:(NSUInteger)count sampleRate:(double)rate {
    if ((self = [super init])) {
        auto renderer = std::make_shared<PadRenderer>(unsigned(count), rate);
        _renderer = renderer;
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
        _node = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *out) {
            renderer->process(time, frames, out); *silent = NO; return noErr;
        }];
    }
    return self;
}
- (void)sample:(AVAudioPCMBuffer *)sample pad:(NSUInteger)index {
    std::shared_ptr<jaras::audio::DrumSample> pcm;
    if (sample && sample.frameLength && sample.floatChannelData) {
        pcm = std::make_shared<jaras::audio::DrumSample>();
        pcm->rate = sample.format.sampleRate;
        pcm->left.assign(sample.floatChannelData[0], sample.floatChannelData[0] + sample.frameLength);
        if (sample.format.channelCount > 1) pcm->right.assign(sample.floatChannelData[1], sample.floatChannelData[1] + sample.frameLength);
    }
    _renderer->kit.setSample(unsigned(index), std::move(pcm));
}
- (void)pad:(NSUInteger)i note:(NSInteger)note gain:(float)gain { _renderer->kit.controls(unsigned(i), int(note), gain); }
- (void)masterGain:(float)gain { _renderer->kit.setMaster(gain); }
- (void)hit:(NSUInteger)i { _renderer->kit.hit(unsigned(i), 127); }
- (void)midiNote:(NSUInteger)note velocity:(NSUInteger)velocity { _renderer->kit.midi(unsigned(note), unsigned(velocity)); }
- (void)silence { _renderer->kit.silence(); }
- (uint64_t)flashes { return _renderer->kit.flashes(); }
- (void)setSequenceNotes:(NSArray<NSDictionary *> *)notes { _renderer->sequence.setNotes(catMIDINotes(notes)); }
- (void)sequenceHead:(int)head position:(double)p clock:(double)c running:(BOOL)run loopStart:(double)a loopEnd:(double)b {
    _renderer->sequence.configure(head,p,c,run,a,b);
}
@end
