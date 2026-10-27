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

    test("Playback from Stop smooths file starts and seeks without changing exports or future attacks",[&] {
        const auto folder=directory.getNonexistentChildFile("play-onset","");folder.createDirectory();
        auto stream=folder.getChildFile("constant.wav").createOutputStream();WavAudioFormat wav;
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,2,24,{},0));
        require(writer!=nullptr,"Onset writer");stream.release();
        AudioBuffer<float> pcm(2,48000);for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(pcm.getWritePointer(ch),.25f,48000);
        require(writer->writeFromAudioSampleBuffer(pcm,0,48000),"Onset fixture");writer.reset();
        jaras::Project project;project.id=uuid();jaras::Song song;song.id=uuid();song.duration=2;
        jaras::Track track;track.id=uuid();track.role.id="other";
        jaras::AudioClip clip;clip.id=uuid();clip.duration=1;clip.audioFile=jaras::AudioFile{"constant.wav",{}};
        track.clips={clip};song.tracks={track};project.songs={song};
        for(double sr:{44100.,48000.})for(bool offline:{false,true}) {
            auto owned=std::make_unique<AudioEngine>(sr,offline);auto &engine=*owned;engine.prepareSong(song,folder,{},&project);engine.setOffline(offline);engine.setMixer(project,song);
            AudioBuffer<float> output(2,37);
            for(double start:{0.,.25,0.}) {
                AudioEngine::State state;state.position=start;engine.transport(state);engine.render(output.getArrayOfWritePointers(),2,37);
                state.playing=true;engine.transport(state);
                float previous=0,step=0,first=0,last=0;
                for(int block=0;block<12;++block){engine.render(output.getArrayOfWritePointers(),2,37);for(int n=0;n<37;++n){float value=output.getSample(0,n);if(block==0&&n==0)first=value;step=std::max(step,std::abs(value-previous));previous=value;last=value;}}
                require(std::abs(last-.25f)<.001,"Start ramp changed settled gain");
                require(offline?std::abs(first-.25f)<.001:std::abs(first)<.001,"First sample violates transport/export contract");
                if(!offline)require(step<.003,"Play produced an abrupt PCM step");
            }
        }
        song.tracks[0].clips[0].startTime=.02;
        auto owned=std::make_unique<AudioEngine>(48000,false);auto &engine=*owned;engine.prepareSong(song,folder,{},&project);engine.setOffline(false);engine.setMixer(project,song);
        AudioBuffer<float> output(2,1200);
        // Prime this future source through the production streaming path first.
        AudioEngine::State state;state.playing=true;state.position=.02;engine.transport(state);engine.render(output.getArrayOfWritePointers(),2,480);
        state.playing=false;state.position=0;engine.transport(state);engine.render(output.getArrayOfWritePointers(),2,480);
        state.playing=true;engine.transport(state);engine.render(output.getArrayOfWritePointers(),2,1200);
        require(std::abs(output.getSample(0,960)-.25f)<.001,"Future file attack was faded");
    });
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
    test("Rapid tempo remapping keeps the sounding source clock and produces every audio block", [&] {
        const double rate=48000;
        AudioBuffer<float> pcm(2,48000*12);
        for(int n=0;n<pcm.getNumSamples();++n) for(int ch=0;ch<2;++ch)
            pcm.setSample(ch,n,float(.2*std::sin(2*MathConstants<double>::pi*440*n/rate)));
        Reader reader(pcm,rate);
        jaras::Song song;song.id=uuid();song.duration=12;
        jaras::Track track;track.id=uuid();track.role.id="other";
        jaras::AudioClip clip;clip.id=uuid();clip.duration=10;clip.playbackRate=1.1;
        track.clips={clip};song.tracks={track};
        ClipAudio processor(song,track,clip,rate);
        AudioBuffer<float> scratch(2,131080),output(2,480);
        double local=0;
        for(int block=0;block<220;++block) {
            if(block>10 && block%4==0) {
                const double source=processor.sourcePosition(local);
                clip.playbackRate=(block%8==0?1.09:1.11);clip.duration=10/clip.playbackRate;
                song.tracks[0].clips[0]=clip;
                ClipAudio next(song,track,clip,rate,false);
                processor.adoptTiming(next);local=source/clip.playbackRate;
                require(std::abs(processor.sourcePosition(local)-source)<1e-8,"Tempo edit rewound source position");
            }
            require(processor.render(reader,scratch,output,0,local,480),"Tempo read failed");
            require(output.getRMSLevel(0,0,480)>.015,"Tempo edit interrupted the sounding waveform");
            local+=480/rate;
        }
    });
    test("Full engine changes BPM without seeking backwards or rebuilding source and effect graphs", [&] {
        const auto folder=directory.getNonexistentChildFile("live-bpm-continuity","");folder.createDirectory();
        auto stream=folder.getChildFile("tone.wav").createOutputStream();WavAudioFormat format;
        std::unique_ptr<AudioFormatWriter> writer(format.createWriterFor(stream.get(),48000,2,24,{},0));
        require(writer!=nullptr,"Tempo fixture writer");stream.release();
        AudioBuffer<float> pcm(2,48000*10);
        for(int n=0;n<pcm.getNumSamples();++n)for(int ch=0;ch<2;++ch)pcm.setSample(ch,n,float(.15*std::sin(n*.035)));
        require(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Tempo fixture write");writer.reset();
        jaras::Project project;project.id=uuid();jaras::Song song;song.id=uuid();song.bpm=120;song.duration=10;
        song.timeSettings=jaras::ProjectTimeSettings{};song.timeSettings->timebase=jaras::ProjectTimebase::relative;
        jaras::Track track;track.id=uuid();track.role.id="other";
        jaras::AudioClip clip;clip.id=uuid();clip.duration=10;clip.audioFile=jaras::AudioFile{"tone.wav",{}};
        track.clips={clip};song.tracks={track};project.songs={song};
        for(double sampleRate:{44100.,48000.}) {
            auto engine=std::make_unique<AudioEngine>(sampleRate,true);engine->prepareSong(song,folder,{},&project);
            engine->setMixer(project,song);engine->setOffline(true);
            AudioEngine::State state;state.playing=true;engine->transport(state);
            auto current=song;AudioBuffer<float> output(2,480);
            for(int block=0;block<240;++block) {
                if(block>12 && block%4==0) {
                    auto next=current;next.bpm=block%8==0?121:119;
                    const auto scale=current.bpm/next.bpm;
                    next.duration*=scale;next.tracks[0].clips[0].duration*=scale;
                    next.tracks[0].clips[0].playbackRate/=scale;
                    engine->takeElapsed();
                    engine->render(output.getArrayOfWritePointers(),2,480);
                    const auto before=engine->state().position;
                    engine->refreshTempo(current,next);
                    require(std::abs(engine->takeElapsed()-480/sampleRate*scale)<1.1/sampleRate,"Tempo edit reported elapsed frames from the old clock epoch");
                    require(std::abs(engine->state().position-before*scale)<1e-8,"BPM retime used a stale transport position");
                    current=next;
                }
                engine->render(output.getArrayOfWritePointers(),2,480);
                require(output.getRMSLevel(0,0,480)>.01,"BPM change interrupted audio");
            }
            require(engine->getUnderruns()==0,"BPM change caused a read underrun");
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
