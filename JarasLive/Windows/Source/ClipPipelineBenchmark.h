#pragma once
#include "ClipAudio.h"

namespace catlive::clipPipelineBenchmark {
// Opt-in, isolated DSP benchmark. Audio is already in memory: disk/cache waits
// and UI scheduling cannot be mistaken for clip processing cost. No thresholds
// depend on the test computer; the caller persists the measured JSON report.
class MemoryReader final : public AudioFormatReader {
  public:
    MemoryReader(const AudioBuffer<float> &data, double rate)
        : AudioFormatReader(nullptr, "Resident PCM benchmark"), data(data) {
        sampleRate=rate;numChannels=(unsigned)data.getNumChannels();
        lengthInSamples=data.getNumSamples();bitsPerSample=32;usesFloatingPointData=true;
    }
    bool readSamples(int *const *dest,int channels,int target,int64 first,int count) override {
        for(int channel=0;channel<channels;++channel)if(dest[channel]) {
            auto *out=reinterpret_cast<float *>(dest[channel])+target;
            FloatVectorOperations::clear(out,count);
            const auto begin=std::max<int64>(0,first),end=std::min<int64>(lengthInSamples,first+count);
            if(end>begin && channel<(int)numChannels)
                FloatVectorOperations::copy(out+(int)(begin-first),data.getReadPointer(channel,(int)begin),(int)(end-begin));
        }
        return true;
    }
  private:
    const AudioBuffer<float> &data;
};
inline var run(int measuredBlocks=400,int voices=14,int frames=480) {
    measuredBlocks=jlimit(20,2000,measuredBlocks);voices=jlimit(1,64,voices);frames=jlimit(32,4096,frames);
    constexpr double rate=48000;
    constexpr int warmup=20;
    const int sourceFrames=(int)std::ceil(((measuredBlocks+warmup)*frames/rate+1)*rate*1.5);
    const auto measure=[&](const String &name,double sourceRate,bool mono,bool loop,double speed,int pitch) {
        AudioBuffer<float> source(mono?1:2,sourceFrames);
        for(int channel=0;channel<source.getNumChannels();++channel)
            for(int n=0;n<sourceFrames;++n)
                source.setSample(channel,n,float(.1*std::sin(n*2*MathConstants<double>::pi*(channel?311:197)/sourceRate)));
        jaras::Song song;song.id="benchmark-song";song.duration=sourceFrames/sourceRate;
        jaras::Track track;track.id="benchmark-track";track.role.id="other";
        jaras::AudioClip clip;clip.id="benchmark-clip";clip.duration=song.duration;
        clip.playbackRate=speed;clip.pitchSemitones=pitch;if(loop){clip.loopStart=0;clip.loopLength=.125;}
        track.clips={clip};song.tracks={track};
        std::vector<std::unique_ptr<ClipAudio>> processors;
        std::vector<std::unique_ptr<MemoryReader>> readers;
        for(int i=0;i<voices;++i){processors.push_back(std::make_unique<ClipAudio>(song,track,clip,rate));readers.push_back(std::make_unique<MemoryReader>(source,sourceRate));}
        AudioBuffer<float> scratch(2,131080),output(2,4096);
        std::vector<double> milliseconds;milliseconds.reserve((size_t)measuredBlocks);
        double checksum=0;bool valid=true;
        for(int block=0;block<measuredBlocks+warmup;++block) {
            const double position=block*frames/rate;
            const auto started=Time::getHighResolutionTicks();
            for(int voice=0;voice<voices;++voice)
                valid=processors[(size_t)voice]->render(*readers[(size_t)voice],scratch,output,0,position,frames)&&valid;
            const double elapsed=Time::highResolutionTicksToSeconds(Time::getHighResolutionTicks()-started)*1000;
            checksum+=output.getSample(0,frames/2)+output.getSample(1,frames/3);
            if(block>=warmup)milliseconds.push_back(elapsed);
        }
        std::sort(milliseconds.begin(),milliseconds.end());
        double sum=0;for(auto value:milliseconds)sum+=value;
        auto result=object();put(result,"case",name);put(result,"sourceRate",sourceRate);put(result,"mono",mono);
        put(result,"voices",voices);put(result,"frames",frames);put(result,"blocks",measuredBlocks);
        put(result,"meanMilliseconds",sum/milliseconds.size());put(result,"medianMilliseconds",milliseconds[milliseconds.size()/2]);
        put(result,"p95Milliseconds",milliseconds[(milliseconds.size()-1)*95/100]);put(result,"maxMilliseconds",milliseconds.back());
        put(result,"audioBlockMilliseconds",1000*frames/rate);put(result,"meanBudgetPercent",sum/milliseconds.size()/(frames/rate*10));
        put(result,"valid",valid&&std::isfinite(checksum));put(result,"checksum",checksum);return result;
    };
    Array<var> rows;
    rows.add(measure("flat stereo, no loop or pitch",48000,false,false,1,0));
    rows.add(measure("flat mono, no loop or pitch",48000,true,false,1,0));
    rows.add(measure("stereo resample 44.1k to 48k",44100,false,false,1,0));
    rows.add(measure("stereo short source loop",48000,false,true,1,0));
    rows.add(measure("stereo pitch +2 semitones",48000,false,false,1,2));
    rows.add(measure("stereo rate 1.2 with pitch preservation",48000,false,false,1.2,0));
    auto report=object();put(report,"sampleRate",rate);put(report,"measuredPipeline","ClipAudio from resident PCM; excludes mixer/FX/device/UI");
    put(report,"results",rows);return report;
}
} // namespace catlive::clipPipelineBenchmark
