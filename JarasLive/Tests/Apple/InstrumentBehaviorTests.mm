#import "../../Apple/Bridge/JarasSoundFont.mm"
#include <iostream>
#include <stdexcept>
static void expect(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main(int argc,char**argv) { @autoreleasepool {
    expect(argc==2,"SF2 fixture required");
    for(int rate : {44100,48000}) {
        InstrumentRenderer renderer;
        renderer.font=tsf_load_filename(argv[1]); expect(renderer.font,"load SF2");
        tsf_set_output(renderer.font,TSF_STEREO_INTERLEAVED,rate,0);
        expect(tsf_set_max_voices(renderer.font,128),"allocate voices");
        for(int channel=0;channel<16;++channel) tsf_channel_set_presetindex(renderer.font,channel,0);
        float left[64],right[64];
        struct { UInt32 count; AudioBuffer buffers[2]; } output{2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
        auto render=[&](int blocks=1) { for(int i=0;i<blocks;++i) renderer.render(reinterpret_cast<AudioBufferList*>(&output),64); };
        auto reset=[&] { renderer.silenceRequested.store(true); render(); };
        auto on=[&](int key,int velocity=100) { renderer.enqueue({0x90,uint8_t(key),uint8_t(velocity)}); render(); };
        auto off=[&](int key) { renderer.enqueue({0x80,uint8_t(key),0}); render(); };
        auto sounding=[&](int key) { int count=0; for(int i=0;i<renderer.font->voiceNum;++i) { const auto& v=renderer.font->voices[i]; if(v.playingPreset>=0 && v.playingKey==key && v.ampenv.segment<TSF_SEGMENT_RELEASE) ++count; } return count; };
        // Manual hardware rendering may provide only sample time to a source node.
        // The transport schedules against the device host clock.
        const auto epoch = [AVAudioTime hostTimeForSeconds:1234.0];
        renderer.sequence.setNotes({{.005,.05,36,120,0}});
        renderer.sequence.configure(0,0,1234.0,true,0,0);
        float peak = 0;
        for (int frame = 0; frame < rate/16; frame += 64) {
            jaras::realtimeClock = {epoch + [AVAudioTime hostTimeForSeconds:double(frame)/rate],
                                    double(frame), double(rate), double([AVAudioTime hostTimeForSeconds:1])};
            AudioTimeStamp time{}; time.mFlags=kAudioTimeStampSampleTimeValid; time.mSampleTime=frame;
            renderer.render(reinterpret_cast<AudioBufferList*>(&output),64,&time);
            for (float sample : left) peak = std::max(peak,std::abs(sample));
        }
        expect(peak > .00001f,"Sample-only hardware pulls must play the scheduled MIDI item");
        jaras::realtimeClock={};
        renderer.sequence.configure(0,0,1234.0,false,0,0);
        reset();
        renderer.drums.store(true); renderer.release.store(20);
        on(46); expect(sounding(46)>0,"open hi-hat sounds");
        on(42); expect(sounding(46)==0 && sounding(42)>0,"closed hi-hat chokes open even with maximum release");
        on(44); expect(sounding(42)==0 && sounding(44)>0,"pedal hi-hat chokes previous");
        reset(); renderer.drums.store(false); renderer.monophonic.store(true);
        on(60); expect(sounding(60)>0,"first mono note must not be discarded on mode change");
        on(67); expect(sounding(60)==0 && sounding(67)>0,"Lead keeps latest note");
        off(67); expect(sounding(60)>0 && sounding(67)==0,"mono returns to held note without long overlapping tail");
        off(60); expect(sounding(60)==0,"last mono note releases");
        reset(); renderer.monophonic.store(false); renderer.velocityMinimum.store(200);
        on(60,30); on(67,127);
        float low=0, high=0;
        for(int i=0;i<renderer.font->voiceNum;++i) if(renderer.font->voices[i].playingPreset>=0) {
            if(renderer.font->voices[i].playingKey==60) low=renderer.filters[i].frequency;
            if(renderer.font->voices[i].playingKey==67) high=renderer.filters[i].frequency;
        }
        expect(low>=200 && low<2000 && high>19000,"each simultaneous note keeps its own velocity cutoff");
        renderer.cutoff.store(1000); render(200);
        for(int i=0;i<renderer.font->voiceNum;++i) if(renderer.font->voices[i].playingPreset>=0) expect(renderer.filters[i].frequency<1001,"global cutoff limits each voice");
        renderer.modulationEnabled.store(true); renderer.enqueue({0xb0,1,0}); render(200);
        for(int i=0;i<renderer.font->voiceNum;++i) if(renderer.font->voices[i].playingPreset>=0) expect(renderer.filters[i].frequency<21,"modulation closes cutoff");
        renderer.modulationEnabled.store(false); render(200);
        renderer.pitchVibratoEnabled.store(true); renderer.enqueue({0xe0,127,127}); render(1);
        bool positive=false,negative=false;
        for(int block=0;block<int(rate/64);++block) { render(); positive|=renderer.appliedPitch[0]>8500; negative|=renderer.appliedPitch[0]<7900; }
        expect(positive&&negative,"pitch bend wheel creates alternating vibrato");
        renderer.pitchVibratoEnabled.store(false); render(); expect(renderer.appliedPitch[0]==8192,"disabled pitch controller returns to neutral");
        reset(); renderer.velocityCurve.store(0); on(60,64);
        int soft=0,hard=0;
        for(int i=0;i<renderer.font->voiceNum;++i) if(renderer.font->voices[i].playingPreset>=0) soft=renderer.font->voices[i].hookFilterVelocity;
        reset(); renderer.velocityCurve.store(2); on(60,64);
        for(int i=0;i<renderer.font->voiceNum;++i) if(renderer.font->voices[i].playingPreset>=0) hard=renderer.font->voices[i].hookFilterVelocity;
        expect(soft>64 && hard<64,"velocity curves affect note sensitivity");
        std::cout<<"SF2_CHOKE_MONO_PER_NOTE_FILTER_CONTROLLERS_OK rate="<<rate<<"\n";
    }
} }
