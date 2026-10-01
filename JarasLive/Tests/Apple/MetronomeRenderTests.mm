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
    std::cout<<"METRONOME_PCM_OK 44100/48000 tempo changes, accents, A/B modes, loop, gain +6dB, mute, stop\n";
}
