#pragma once
#include "AudioEngine.h"
#include "ClipAudio.h"

namespace catlive::clipAudioReadTests {
inline void require(bool value,const String &message) {
    if(!value)throw std::runtime_error(utf8(message));
}
class Reader final : public AudioFormatReader {
  public:
    struct Read {int64 first;int frames;};
    const AudioBuffer<float> &data;
    std::vector<Read> reads;
    Reader(const AudioBuffer<float> &source,double rate):AudioFormatReader(nullptr,"Clip read parity"),data(source) {
        sampleRate=rate;numChannels=(unsigned)data.getNumChannels();lengthInSamples=data.getNumSamples();
        usesFloatingPointData=true;bitsPerSample=32;
    }
    bool readSamples(int *const *dest,int channels,int offset,int64 first,int count) override {
        reads.push_back({first,count});
        for(int channel=0;channel<channels;++channel)if(dest[channel]) {
            auto *out=reinterpret_cast<float *>(dest[channel])+offset;
            FloatVectorOperations::clear(out,count);
            const auto begin=std::max<int64>(0,first),end=std::min<int64>(lengthInSamples,first+count);
            if(end>begin&&channel<(int)numChannels)
                FloatVectorOperations::copy(out+(int)(begin-first),data.getReadPointer(channel,(int)begin),(int)(end-begin));
        }
        return true;
    }
};
inline AudioBuffer<float> samples(int channels,int frames) {
    AudioBuffer<float> result(channels,frames);
    for(int channel=0;channel<channels;++channel)for(int n=0;n<frames;++n)
        result.setSample(channel,n,float(((n*(channel+3))%97-48)*.011));
    return result;
}
inline float expected(const AudioBuffer<float> &source,double rate,const jaras::AudioClip &clip,double local,int channel) {
    if(local>=clip.duration)return 0;
    double time=clip.sourceOffset+local;
    if(clip.loopLength&&time>=clip.loopStart.value_or(0))
        time=clip.loopStart.value_or(0)+std::fmod(time-clip.loopStart.value_or(0),*clip.loopLength);
    const auto frame=time*rate;const auto first=(int64)std::floor(frame);
    const auto sample=[&](int64 n){return n>=0&&n<source.getNumSamples()?source.getSample(source.getNumChannels()==1?0:channel,(int)n):0.f;};
    return sample(first)+float(frame-first)*(sample(first+1)-sample(first));
}
template <typename Test> void registerTests(const File &directory,Test &test) {
    test("Long clip and source-loop boundaries never fragment a block into single-frame reads",[&] {
        auto source=samples(2,8192);
        for(double duration:{56605.733581225104,1.e15,std::numeric_limits<double>::infinity()})
            for(bool loop:{false,true}) {
                Reader reader(source,48000);
                jaras::Song song;song.id=uuid();song.duration=duration;
                jaras::Track track;track.id=uuid();track.role.id="other";
                jaras::AudioClip clip;clip.id=uuid();clip.duration=duration;
                if(loop){clip.loopStart=0;clip.loopLength=duration;}
                track.clips={clip};song.tracks={track};
                ClipAudio processor(song,track,clip,48000);
                AudioBuffer<float> scratch(2,131080),output(2,480);
                require(processor.render(reader,scratch,output,0,0,480),"Long clip read failed");
                require(reader.reads.size()==1&&reader.reads.front().frames==480,
                        "Long item/loop overflow split one audio block into "+String((int)reader.reads.size())+" reads");
                for(int ch=0;ch<2;++ch)for(int n=0;n<480;++n)
                    require(output.getSample(ch,n)==source.getSample(ch,n),"Long item/loop altered direct-read PCM");
            }
    });
    test("ClipAudio direct PCM reads preserve stereo, mono, loops, item ends and fractional resampling",[&] {
        for(bool mono:{false,true})for(int mode=0;mode<6;++mode) {
            const double rate=mode==4?44100:48000;
            auto source=samples(mono?1:2,8192);Reader reader(source,rate);
            jaras::Song song;song.id=uuid();song.duration=1;
            jaras::Track track;track.id=uuid();track.role.id="other";
            jaras::AudioClip clip;clip.id=uuid();clip.duration=.5;
            double local=0;int count=497;
            if(mode==1){clip.loopStart=.01;clip.loopLength=.025;clip.sourceOffset=.0325;}
            if(mode==2){clip.duration=217./48000;}
            if(mode==3){clip.sourceOffset=.375/48000;}
            if(mode==5){clip.sourceOffset=8190./48000;}
            track.clips={clip};song.tracks={track};
            ClipAudio processor(song,track,clip,48000);
            AudioBuffer<float> scratch(2,131080),output(2,512);
            for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(output.getWritePointer(ch),123.f,512);
            require(processor.render(reader,scratch,output,0,local,count),"ClipAudio resident read failed");
            for(int ch=0;ch<2;++ch)for(int n=0;n<count;++n)
                require(std::abs(output.getSample(ch,n)-expected(source,rate,clip,local+n/48000.,ch))<.000002,
                        "ClipAudio changed PCM at mode "+String(mode)+", sample "+String(n));
            require(output.getSample(0,count)==123.f&&output.getSample(1,count)==123.f,
                    "ClipAudio direct read wrote outside the requested output range");
            if(mode==0)require(reader.reads.size()==1&&reader.reads[0].first==0&&reader.reads[0].frames==count,
                              "Aligned unit-rate audio still requested interpolation lookahead");
            if(mode==3||mode==4)require(reader.reads[0].frames!=count,
                                     "Fractional/resampled audio incorrectly used the direct PCM path");
            if(mode==1)require(reader.reads.size()>=2&&reader.reads[0].frames<=120,
                              "Direct PCM read crossed a source-loop boundary");
        }
    });
    test("Direct loop reads retain item fades, gain, normalization, phase and pan in the full audio graph",[&] {
        const auto folder=directory.getNonexistentChildFile("clip-direct-fades","");folder.createDirectory();
        const auto file=folder.getChildFile("source.wav");auto pcm=samples(2,12000);
        auto stream=file.createOutputStream();WavAudioFormat format;
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,2,32,{},0));
        require(writer!=nullptr,"Cannot create direct-read fade fixture");stream.release();
        require(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Cannot write direct-read fade fixture");writer.reset();
        jaras::Project project;project.id=uuid();jaras::Song song;song.id=uuid();song.duration=1;
        jaras::Track track;track.id=uuid();track.role.id="other";
        jaras::AudioClip clip;clip.id=uuid();clip.startTime=.0175;clip.duration=.2;
        clip.audioFile=jaras::AudioFile{"source.wav",{}};clip.loopStart=0;clip.loopLength=.125;
        clip.sourceOffset=.001;clip.fadeIn=.03;clip.fadeOut=.04;clip.gain=.8;clip.normalizationGain=.75;
        clip.phaseInverted=true;clip.pan=-.3;track.clips={clip};song.tracks={track};project.songs={song};
        auto engine=std::make_unique<AudioEngine>(48000,true);
        engine->prepareSong(song,folder,{},&project);engine->setMixer(project,song);engine->setOffline(true);
        AudioEngine::State state;state.playing=true;engine->transport(state);
        AudioBuffer<float> output(2,480);
        for(int block=0;block<25;++block) {
            engine->render(output.getArrayOfWritePointers(),2,480);
            for(int n=0;n<480;++n)for(int ch=0;ch<2;++ch) {
                const double time=(block*480+n)/48000.,local=time-clip.startTime;
                const double gain=-.8*.75*(ch==1?.7:1)*jaras::itemFadeGain(clip,time);
                const auto value=local<0||local>=clip.duration?0:expected(pcm,48000,clip,local,ch)*gain;
                require(std::abs(output.getSample(ch,n)-value)<.000003,
                        "Direct loop PCM altered fade/gain/phase/pan at sample "+String(block*480+n));
            }
        }
    });
}
} // namespace catlive::clipAudioReadTests
