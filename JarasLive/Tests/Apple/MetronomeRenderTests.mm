#import "../../Apple/Bridge/JarasTimecode.mm"
#include <cassert>
#include <iostream>

static std::vector<float> render(MetronomeSignal& signal, double rate, double seconds) {
    std::vector<float> result(size_t(rate*seconds));
    for(size_t offset=0;offset<result.size();offset+=128) {
        const auto count=unsigned(std::min(size_t(128),result.size()-offset));
        AudioTimeStamp time{}; time.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid;
        time.mSampleTime=offset; time.mHostTime=1000000+uint64_t(offset/rate*signal.ticksPerSecond);
        AudioBufferList buffers{}; buffers.mNumberBuffers=1;
        buffers.mBuffers[0]={1,UInt32(count*sizeof(float)),result.data()+offset};
        signal.render(&time,count,&buffers);
    }
    return result;
}
static std::vector<size_t> onsets(const std::vector<float>& samples) {
    std::vector<size_t> result;
    for(size_t i=0;i<samples.size();++i) if(std::abs(samples[i])>0.00001f && (i==0 || std::abs(samples[i-1])<=0.00001f)) result.push_back(i);
    return result;
}
int main() {
    for(double rate : {44100.,48000.}) for(int mode=0;mode<3;++mode) {
        MetronomeSignal signal(rate); signal.host=1000000; signal.running=true;
        auto program=std::make_unique<MetronomeProgram>();
        program->sections={{0,120,4,4},{1,60,3,4}}; program->mode=mode;
        program->a.assign(size_t(rate*0.025),0.2f); program->b.assign(size_t(rate*0.025),-0.1f);
        signal.publish(std::move(program));
        auto samples=render(signal,rate,2.5); const auto beats=onsets(samples);
        assert(beats.size()==4);
        const double positions[]={0,0.5,1,2};
        for(size_t i=0;i<beats.size();++i) {
            assert(std::abs(double(beats[i])/rate-positions[i])<2/rate);
            const bool accent=mode==1 || (mode==0 && (i==0 || i==2));
            assert(accent ? samples[beats[i]]>0 : samples[beats[i]]<0);
        }
        signal.running=false;
        auto silence=render(signal,rate,0.04);
        for(size_t i=size_t(rate*0.01);i<silence.size();++i) assert(silence[i]==0);
    }
    for(double rate : {44100.,48000.}) {
        MetronomeSignal signal(rate); signal.host=1000000; signal.running=true; signal.loopStart=0; signal.loopEnd=1;
        signal.gainA=float(std::pow(10.,6./20)); signal.gainB=0;
        auto program=std::make_unique<MetronomeProgram>(); program->sections={{0,120,2,4}};
        program->a.assign(size_t(rate*0.025),0.2f); program->b.assign(size_t(rate*0.025),-0.1f);
        signal.publish(std::move(program)); auto samples=render(signal,rate,2.25);
        const auto beats=onsets(samples); assert(beats.size()==3);
        assert(std::abs(double(beats[1])/rate-1)<2/rate && std::abs(double(beats[2])/rate-2)<2/rate);
        assert(std::abs(samples[beats[2]+size_t(rate*0.015)]-0.2f*std::pow(10.,6./20))<0.0001);
    }
    {
        MetronomeSignal signal(48000); signal.host=1000000; signal.running=true;
        auto program=std::make_unique<MetronomeProgram>(); program->sections={{0,120,4,4}};
        program->a.assign(1680,0.2f); program->b.assign(1680,0.2f);
        signal.publish(std::move(program));
        render(signal,48000,0.01);
        signal.enabled=false;
        auto disabled=render(signal,48000,1.1);
        for(size_t i=200;i<disabled.size();++i) assert(disabled[i]==0);
        signal.enabled=true;
        const auto enabled=render(signal,48000,1.1);
        assert(!onsets(enabled).empty());
    }
    for(double rate : {44100.,48000.}) {
        MetronomeSignal signal(rate); signal.host=1000000; signal.running=true;
        auto program=std::make_unique<MetronomeProgram>(); program->bounded=true; program->mode=1;
        program->sections={{0.1,120,4,4,0.72,0},{1.2,120,6,8,1.81,1.2},{2.1,60,3,4,3.01,2}};
        program->a.assign(size_t(rate*0.08),0.2f);
        signal.publish(std::move(program));
        const auto samples=render(signal,rate,3.3); const auto beats=onsets(samples);
        const double expected[]={0.5,1.2,1.45,1.7,3};
        assert(beats.size()==5);
        for(size_t i=0;i<beats.size();++i) assert(std::abs(double(beats[i])/rate-expected[i])<2/rate);
        for(size_t i=size_t(rate*3.01);i<samples.size();++i) assert(samples[i]==0); // truncate tail at item edge
        for(size_t i=size_t(rate*0.72);i<size_t(rate*1.2);++i) assert(samples[i]==0); // gap
        signal.loopStart=1.2; signal.loopEnd=1.7; signal.position=1.2; signal.generation++;
        const auto looped=render(signal,rate,1.1); const auto loopBeats=onsets(looped);
        assert(loopBeats.size()==5);
        for(size_t i=0;i<loopBeats.size();++i) assert(std::abs(double(loopBeats[i])/rate-i*0.25)<2/rate);
        signal.position=1.3; signal.loopEnd=0; signal.generation++;
        const auto seek=render(signal,rate,0.4); const auto seekBeats=onsets(seek);
        assert(seekBeats.size()==1 && std::abs(double(seekBeats[0])/rate-0.15)<2/rate);
        signal.running=false;
        const auto stopped=render(signal,rate,0.1);
        for(size_t i=0;i<stopped.size();++i) assert(stopped[i]==0);
    }
    // Off-beat song boundaries must trigger the destination downbeat even
    // when the UI never submits the post-jump position during this render.
    for(double rate : {44100.,48000.}) for(bool bounded : {false,true}) for(bool cancel : {false,true}) {
        MetronomeSignal signal(rate); signal.host=1000000; signal.position=0.7;
        signal.referenceSample=0; signal.running=true;
        auto program=std::make_unique<MetronomeProgram>(); program->bounded=bounded; program->mode=1;
        program->sections={{0,120,4,4,4,0},{4,120,4,4,6,4}};
        program->a.assign(size_t(rate*0.01),0.5f);
        signal.publish(std::move(program));
        signal.scheduleJump(4,1000000+uint64_t(1.13*signal.ticksPerSecond),1.13*rate);
        // An early UI promotion may attempt to queue the following edge before
        // this one reaches the speakers. The first edge must remain scheduled.
        signal.scheduleJump(8,1000000+uint64_t(1.63*signal.ticksPerSecond),1.63*rate);
        if(cancel) signal.cancelJump();
        const auto samples=render(signal,rate,1.9); const auto beats=onsets(samples);
        assert(beats.size()==4);
        const double expected[]={0.3,0.8,cancel?1.3:1.13,cancel?1.8:1.63};
        for(size_t i=0;i<beats.size();++i) assert(std::abs(double(beats[i])/rate-expected[i])<2/rate);
    }
    // A live preset change must not restart the beat or rewrite a sounding tail.
    for(double rate : {44100.,48000.}) for(double switchTime : {0.01,0.2,0.5,0.501}) {
        MetronomeSignal signal(rate); signal.host=1000000; signal.running=true; signal.gain=1;
        auto preset=[&](float level) {
            auto p=std::make_unique<MetronomeProgram>(); p->sections={{0,120,4,4}}; p->mode=1;
            p->a.assign(size_t(rate*0.04),level); return p;
        };
        signal.publish(preset(0.2f));
        std::vector<float> samples(size_t(rate*1.1));
        const auto change=size_t(std::round(rate*switchTime));
        bool changed=false;
        for(size_t offset=0;offset<samples.size();) {
            if(offset==change) { signal.publish(preset(-0.3f)); changed=true; }
            auto count=std::min(size_t(128),samples.size()-offset);
            if(!changed) count=std::min(count,change-offset);
            AudioTimeStamp time{}; time.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid;
            time.mSampleTime=offset; time.mHostTime=1000000+uint64_t(offset/rate*signal.ticksPerSecond);
            AudioBufferList buffers{}; buffers.mNumberBuffers=1;
            buffers.mBuffers[0]={1,UInt32(count*sizeof(float)),samples.data()+offset};
            signal.render(&time,unsigned(count),&buffers); offset+=count;
            // Repeated publications while a tail still sounds exercise lifetime
            // protection beyond the callback's single current-program hazard.
            if(changed) signal.publish(preset(-0.3f));
        }
        const auto beats=onsets(samples); assert(beats.size()==3);
        for(size_t i=0;i<beats.size();++i) {
            const auto onset=size_t(rate*0.5*i);
            assert(beats[i]==onset);
            const float expected=onset<change ? 0.2f : -0.3f;
            for(size_t j=onset;j<onset+size_t(rate*0.04);++j) assert(std::abs(samples[j]-expected)<0.00001f);
        }
        assert(signal.programs.size()==1); // finished tails are reclaimable
    }
    std::cout<<"METRONOME_PRESET_CONTINUITY_OK no extra beats, old tails preserved, reclamation 44100/48000\n";
    std::cout<<"SCHEDULED_CLICK_JUMP_PCM_OK first beat, cancellation, metronome/click 44100/48000\n";
    std::cout<<"CLICK_TRACK_PCM_OK bounded items, gaps, meter, tempo, seek, loop, stop at 44100/48000\n";
    std::cout<<"METRONOME_PCM_OK 44100/48000 tempo changes, accents, A/B modes, loop, gain +6dB, mute, stop\n";
}
