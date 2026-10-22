#import "JarasSoundFont.h"
#include "CatMIDISequenceBridge.h"
#include <atomic>
#include <array>
#include <memory>
#include <cmath>
#include <algorithm>
#define TSF_IMPLEMENTATION
#include "../../Core/ThirdParty/TinySoundFont/tsf.h"

namespace {
struct MIDIMessage { uint8_t status, a, b; };
struct InstrumentRenderer {
    CatMIDISequence sequence;
    tsf *font = nullptr;
    std::array<MIDIMessage,2048> messages{};
    std::atomic<unsigned> written{0}, read{0};
    std::atomic<bool> silenceRequested{false};
    std::atomic<float> gain{1}, pan{0}, attack{0}, hold{10}, decay{10}, sustain{1}, release{.3};
    std::atomic<bool> monophonic{false}, drums{false};
    std::atomic<int> velocityCurve{1};
    std::atomic<bool> modulationEnabled{false}, pitchVibratoEnabled{false};
    std::array<float,16> modulationValues{{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}}, bendValues{};
    std::array<int,16> appliedPitch{{8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192}};
    double vibratoPhase=0;
    std::atomic<float> cutoff{20000}, velocityMinimum{20000}, filterAttack{0}, filterHold{0}, filterDecay{.3}, filterSustain{1}, filterRelease{.3}, filterDepth{0};
    struct FilterVoice { double age=0, releaseAge=0; float level=0, releaseLevel=0, frequency=-1; bool released=false; };
    std::array<FilterVoice,128> filters{};
    std::array<unsigned long long,2048> held{};
    std::array<uint8_t,2048> heldVelocity{};
    std::array<bool,2048> pressed{};
    std::array<bool,16> pedal{};
    unsigned long long order=0;
    int monoKey=-1;
    bool previousMono=false;
    float smoothGain=0, smoothPan=0;
    std::array<float,5> lastEnvelope{{-1,-1,-1,-1,-1}};
    ~InstrumentRenderer() { if (font) tsf_close(font); }
    void enqueue(MIDIMessage message) {
        const unsigned w=written.load(std::memory_order_relaxed), r=read.load(std::memory_order_acquire);
        if (w-r >= messages.size()) { silenceRequested.store(true); return; }
        messages[w % messages.size()]=message;
        written.store(w+1,std::memory_order_release);
    }
    void envelope() {
        const std::array<float,5> values{{attack.load(),hold.load(),decay.load(),sustain.load(),release.load()}};
        if (values==lastEnvelope) return;
        lastEnvelope=values;
        auto& preset=font->presets[0];
        for(int i=0;i<preset.regionNum;++i) {
            auto& env=preset.regions[i].ampenv;
            env.delay=0; env.attack=values[0]; env.hold=values[1]; env.decay=values[2]; env.sustain=values[3]; env.release=values[4]; env.keynumToHold=0; env.keynumToDecay=0;
        }
    }
    static bool hiHat(int key) { return key==42 || key==44 || key==46; }
    void startNote(int channel, int key, uint8_t velocity) {
        if (drums.load() && hiHat(key)) {
            for(int i=0;i<font->voiceNum;++i) if(font->voices[i].playingPreset>=0 && hiHat(font->voices[i].playingKey)) tsf_voice_endquick(font,&font->voices[i]);
        }
        if(monophonic.load()) {
            for(int i=0;i<font->voiceNum;++i) if(font->voices[i].playingPreset>=0) tsf_voice_endquick(font,&font->voices[i]);
            monoKey=channel*128+key;
        }
        const int curve=velocityCurve.load();
        const float mapped=std::pow(velocity/127.f,curve==0?.65f:curve==2?1.6f:1.f);
        const auto generation=font->voicePlayIndex;
        tsf_channel_note_on(font,channel,key,std::max(1.f/127.f,mapped));
        for(int i=0;i<font->voiceNum && i<int(filters.size());++i) {
            auto& voice=font->voices[i];
            if(voice.playingPreset<0 || voice.playIndex!=generation) continue;
            voice.hookFilterVelocity=uint8_t(std::clamp(int(std::round(mapped*127)),1,127));
            filters[i]={};
        }
    }
    void noteOn(int channel,int key,uint8_t velocity) {
        const int index=channel*128+key;
        held[index]=++order; heldVelocity[index]=velocity; pressed[index]=true;
        startNote(channel,key,velocity);
    }
    void noteOff(int channel,int key) {
        const int index=channel*128+key;
        pressed[index]=false;
        if(!pedal[channel]) held[index]=0;
        tsf_channel_note_off(font,channel,key);
        if(monophonic.load() && index==monoKey && !held[index]) {
            int newest=-1; unsigned long long serial=0;
            for(int i=0;i<int(held.size());++i) if(held[i]>serial) { serial=held[i]; newest=i; }
            monoKey=-1;
            if(newest>=0) startNote(newest/128,newest%128,heldVelocity[newest]);
        }
    }
    void controllersForBlock(unsigned frames) {
        const bool enabled=pitchVibratoEnabled.load();
        const double wave=std::sin(vibratoPhase);
        vibratoPhase=std::fmod(vibratoPhase+2*3.14159265358979323846*6.85*frames/font->outSampleRate,2*3.14159265358979323846);
        for(int channel=0;channel<16;++channel) {
            // Full wheel travel gives 50 cents of vibrato; centered wheel is neutral.
            const int pitch=8192+(enabled?int(wave*std::abs(bendValues[channel])*2048):0);
            if(appliedPitch[channel]!=pitch) { tsf_channel_set_pitchwheel(font,channel,pitch); appliedPitch[channel]=pitch; }
        }
    }
    void filtersForBlock(unsigned frames) {
        const float ceiling=cutoff.load(), minimum=velocityMinimum.load(), depth=filterDepth.load();
        const float a=filterAttack.load(), h=filterHold.load(), d=filterDecay.load(), sustainLevel=filterSustain.load(), releaseTime=filterRelease.load();
        const double step=frames/double(font->outSampleRate);
        for(int i=0;i<font->voiceNum && i<int(filters.size());++i) {
            auto& voice=font->voices[i]; if(voice.playingPreset<0) continue;
            auto& state=filters[i];
            if(voice.ampenv.segment>=TSF_SEGMENT_RELEASE) {
                if(!state.released) { state.released=true; state.releaseLevel=state.level; }
                state.releaseAge+=step;
                state.level=state.releaseLevel*std::max(0.0,1-state.releaseAge/releaseTime);
            } else {
                state.age+=step;
                if(state.age<a && a>0) state.level=state.age/a;
                else if(state.age<a+h) state.level=1;
                else state.level=sustainLevel+(1-sustainLevel)*std::max(0.0,1-(state.age-a-h)/d);
            }
            const float velocityHz=minimum>=19999?20000:minimum*std::pow(20000/minimum,voice.hookFilterVelocity/127.f);
            const float controllerCeiling=modulationEnabled.load()?20*std::pow(ceiling/20,modulationValues[voice.playingChannel]):ceiling;
            const float base=std::min(controllerCeiling,velocityHz);
            const float desired=std::clamp(depth>0?base*std::pow(2.f,depth*(state.level-1)):base,20.f,20000.f);
            if(state.frequency==desired) continue;
            const float frequency=state.frequency<0?desired:state.frequency+(desired-state.frequency)*float(1-std::exp(-step/.004));
            if(state.frequency>=0 && std::abs(frequency-state.frequency)<.001f) continue;
            state.frequency=frequency;
            auto& filter=voice.hookCutoff;
            const bool active=frequency<19999;
            if(active!=bool(filter.active)) filter.z1=filter.z2=0;
            filter.active=active; filter.QInv=1.4142135623730951;
            if(active) tsf_voice_lowpass_setup(&filter,std::min(frequency/font->outSampleRate,.45f));
        }
    }
    void render(AudioBufferList *output, unsigned frames, const AudioTimeStamp* time = nullptr) {
        if(time) sequence.render(catMIDIClock(time,font->outSampleRate),font->outSampleRate,frames);
        else sequence.count=0;
        const bool mono=monophonic.load();
        if(mono!=previousMono) {
            previousMono=mono; held.fill(0); pressed.fill(false); monoKey=-1;
            for(int i=0;i<font->voiceNum;++i) if(font->voices[i].playingPreset>=0) tsf_voice_endquick(font,&font->voices[i]);
        }
        if (silenceRequested.exchange(false)) {
            held.fill(0); pressed.fill(false); pedal.fill(false); monoKey=-1;
            // Keep channels and voice storage allocated on the audio thread.
            for(int i=0;i<font->voiceNum;++i) font->voices[i].playingPreset=-1;
            for(int channel=0;channel<16;++channel) tsf_channel_midi_control(font,channel,64,0);
            read.store(written.load(std::memory_order_acquire),std::memory_order_release);
        }
        envelope();
        auto r=read.load(std::memory_order_relaxed), w=written.load(std::memory_order_acquire);
        while(r!=w) {
            const auto message=messages[r++ % messages.size()];
            const int channel=message.status & 15;
            switch(message.status & 0xf0) {
                case 0x90: if(message.b) noteOn(channel,message.a,message.b); else noteOff(channel,message.a); break;
                case 0x80: noteOff(channel,message.a); break;
                case 0xb0:
                    if(message.a==1) { modulationValues[channel]=message.b/127.f; break; }
                    tsf_channel_midi_control(font,channel,message.a,message.b);
                    if(message.a==64) {
                        pedal[channel]=message.b>=64;
                        if(!pedal[channel]) {
                            for(int key=0;key<128;++key) if(!pressed[channel*128+key]) held[channel*128+key]=0;
                            if(monoKey>=0 && monoKey/128==channel && !held[monoKey]) noteOff(channel,monoKey%128);
                        }
                    } else if(message.a==120 || message.a==123) {
                        for(int key=0;key<128;++key) { held[channel*128+key]=0; pressed[channel*128+key]=false; }
                        if(monoKey/128==channel) monoKey=-1;
                    }
                    break;
                case 0xe0: bendValues[channel]=std::clamp((message.a+(message.b<<7)-8192)/8192.f,-1.f,1.f); break;
                default: break;
            }
        }
        read.store(r,std::memory_order_release);
        float buffer[256];
        const float targetGain=gain.load(), targetPan=pan.load();
        unsigned midiIndex=0;
        for(unsigned offset=0;offset<frames;) {
            while(midiIndex<sequence.count && sequence.events[midiIndex].offset<=offset) {
                const auto& e=sequence.events[midiIndex++];
                if((e.status&0xf0)==0x90) noteOn(e.status&15,e.pitch,e.velocity);else noteOff(e.status&15,e.pitch);
            }
            unsigned count=std::min(64u,frames-offset);
            if(midiIndex<sequence.count) count=std::min(count,sequence.events[midiIndex].offset-offset);
            controllersForBlock(count);
            filtersForBlock(count);
            tsf_render_float(font,buffer,int(count),0);
            for(unsigned i=0;i<count;++i) {
                smoothGain+=(targetGain-smoothGain)*.005f; smoothPan+=(targetPan-smoothPan)*.005f;
                const float left=buffer[i*2]*smoothGain*(smoothPan>0?1-smoothPan:1);
                const float right=buffer[i*2+1]*smoothGain*(smoothPan<0?1+smoothPan:1);
                if(output->mNumberBuffers>=2) {
                    ((float*)output->mBuffers[0].mData)[offset+i]=left;
                    ((float*)output->mBuffers[1].mData)[offset+i]=right;
                } else if(output->mNumberBuffers==1 && output->mBuffers[0].mNumberChannels==2) {
                    ((float*)output->mBuffers[0].mData)[(offset+i)*2]=left;
                    ((float*)output->mBuffers[0].mData)[(offset+i)*2+1]=right;
                }
            }
            offset+=count;
        }
    }
};
}
@implementation JarasSoundFont {
    std::shared_ptr<InstrumentRenderer> _renderer;
    AVAudioSourceNode *_node;
}
- (instancetype)initWithURL:(NSURL*)url sampleRate:(double)sampleRate error:(NSError**)error {
    if ((self=[super init])) {
        auto renderer=std::make_shared<InstrumentRenderer>();
        renderer->font=tsf_load_filename(url.fileSystemRepresentation);
        if(!renderer->font || tsf_get_presetcount(renderer->font)==0 || !tsf_set_max_voices(renderer->font,128)) {
            if(error) *error=[NSError errorWithDomain:@"JarasSoundFont" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not load the SF2 instrument."}];
            return nil;
        }
        tsf_set_output(renderer->font,TSF_STEREO_INTERLEAVED,int(sampleRate),0);
        for(int channel=0;channel<16;++channel) if(!tsf_channel_set_presetindex(renderer->font,channel,0)) {
            if(error) *error=[NSError errorWithDomain:@"JarasSoundFont" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Could not allocate MIDI channels for the instrument."}];
            return nil;
        }
        _renderer=renderer;
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
        _node=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL* silent,const AudioTimeStamp* time,AVAudioFrameCount frames,AudioBufferList* output) {
            renderer->render(output,frames,time); *silent=NO; return noErr;
        }];
    }
    return self;
}
- (AVAudioSourceNode*)node { return _node; }
- (void)setSequenceNotes:(NSArray<NSDictionary *> *)notes { _renderer->sequence.setNotes(catMIDINotes(notes)); }
- (void)sequenceHead:(int)head position:(double)position clock:(double)clock running:(BOOL)running loopStart:(double)start loopEnd:(double)end { _renderer->sequence.configure(head,position,clock,running,start,end); }
- (void)sendStatus:(uint8_t)status data1:(uint8_t)a data2:(uint8_t)b { _renderer->enqueue({status,uint8_t(a&127),uint8_t(b&127)}); }
- (void)setGain:(double)decibels pan:(double)pan {
    _renderer->gain.store(decibels<=-90?0:powf(10,float(std::clamp(decibels,-90.0,24.0))/20));
    _renderer->pan.store(float(std::clamp(pan,-1.0,1.0)));
}
- (void)setEnvelopeAttack:(double)attack hold:(double)hold decay:(double)decay sustain:(double)sustain release:(double)releaseTime {
    _renderer->attack.store(float(std::clamp(attack,0.0,10.0))); _renderer->hold.store(float(std::clamp(hold,0.0,10.0))); _renderer->decay.store(float(std::clamp(decay,.001,10.0)));
    _renderer->sustain.store(float(std::clamp(sustain,0.0,1.0))); _renderer->release.store(float(std::clamp(releaseTime,.001,20.0)));
}
- (void)setPerformanceMonophonic:(BOOL)mono drums:(BOOL)drums velocityCurve:(int)curve {
    _renderer->monophonic.store(mono); _renderer->drums.store(drums); _renderer->velocityCurve.store(std::clamp(curve,0,2));
}
- (void)setFilterCutoff:(double)cutoff velocityMinimum:(double)minimum attack:(double)attack hold:(double)hold decay:(double)decay sustain:(double)sustain release:(double)releaseTime depth:(double)depth {
    _renderer->cutoff.store(float(std::clamp(cutoff,20.0,20000.0))); _renderer->velocityMinimum.store(float(std::clamp(minimum,20.0,20000.0)));
    _renderer->filterAttack.store(float(std::clamp(attack,0.0,10.0))); _renderer->filterHold.store(float(std::clamp(hold,0.0,10.0)));
    _renderer->filterDecay.store(float(std::clamp(decay,.001,10.0))); _renderer->filterSustain.store(float(std::clamp(sustain,0.0,1.0)));
    _renderer->filterRelease.store(float(std::clamp(releaseTime,.001,20.0))); _renderer->filterDepth.store(float(std::clamp(depth,0.0,10.0)));
}
- (void)setControllersModulation:(BOOL)modulation pitchBend:(BOOL)pitchBend {
    _renderer->modulationEnabled.store(modulation); _renderer->pitchVibratoEnabled.store(pitchBend);
}
- (void)silence { _renderer->silenceRequested.store(true); }
@end
