#pragma once
#include "AudioEngine.h"

namespace catlive::parallelClipAudioTests {
inline void run(const File &directory) {
    const auto require=[](bool ok,const char *why){if(!ok)throw std::runtime_error(why);};
    const auto folder=directory.getChildFile("parallel-audio-"+text(uuid()));folder.createDirectory();
    auto project=Session::makeEmptyProject("Parallel PCM");auto &song=project.songs.front();
    song.tracks.clear();song.parts.clear();song.markers.reset();song.duration=6;
    project.masterVolume=1;project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
    for(int i=0;i<12;++i) {
        const int rate=i%2?44100:48000;AudioBuffer<float> pcm(2,rate*6);
        for(int c=0;c<2;++c)for(int n=0;n<pcm.getNumSamples();++n)
            pcm.setSample(c,n,.015f*std::sin(float(n)*(200+i*31+c*13)*float(MathConstants<double>::twoPi)/rate));
        const auto name="source-"+String(i)+".wav";auto stream=folder.getChildFile(name).createOutputStream();WavAudioFormat wav;
        std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),rate,2,24,{},0));
        require(bool(writer),"Cannot write parallel PCM fixture");stream.release();
        require(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Cannot write parallel PCM");writer.reset();
        jaras::Track track;track.id=uuid();track.name="Source "+std::to_string(i);track.pan=(i%3-1)*.2;
        jaras::AudioClip clip;clip.id=uuid();clip.duration=5;clip.startTime=i*.001;clip.sourceOffset=.02;
        clip.playbackRate=1.17;clip.audioFile=jaras::AudioFile{name.toStdString(),{}};track.clips={clip};song.tracks.push_back(track);
    }
    // One duplicated source must remain safe while independent sources run concurrently.
    auto duplicate=song.tracks.front();duplicate.id=uuid();duplicate.clips[0].id=uuid();duplicate.clips[0].gain=.5;
    song.tracks.push_back(duplicate);
    const auto previous=SystemStats::getEnvironmentVariable("CATLIVE_CLIP_WORKERS",{});
    struct Restore {String value;~Restore(){SetEnvironmentVariableW(L"CATLIVE_CLIP_WORKERS",value.isEmpty()?nullptr:value.toWideCharPointer());}} restore{previous};
    auto serial=std::make_unique<AudioEngine>(),parallel=std::make_unique<AudioEngine>();
    SetEnvironmentVariableW(L"CATLIVE_CLIP_WORKERS",L"0");serial->prepareOffline(48000);serial->prepareSong(song,folder,{},&project);serial->setMixer(project,song);serial->setOffline(true);
    SetEnvironmentVariableW(L"CATLIVE_CLIP_WORKERS",L"4");parallel->prepareOffline(48000);parallel->prepareSong(song,folder,{},&project);parallel->setMixer(project,song);parallel->setOffline(true);
    AudioBuffer<float> expected(2,512),actual(2,512);double maximumError=0,energy=0;
    for(int block=0;block<220;++block) {
        if(block==0 || block==40 || block==100 || block==160) {
            AudioEngine::State state;state.playing=true;state.position=block==0?0:1.3;
            if(block==40){state.loop=true;state.loopStart=1.3;state.loopEnd=1.47;}
            if(block==100){state.subPlaying=true;state.subPosition=2.4;}
            serial->transport(state);parallel->transport(state);
        }
        if(block==160) {
            const auto before=song;for(auto &track:song.tracks)for(auto &clip:track.clips)clip.playbackRate=1.31;
            serial->refreshTempo(before,song);parallel->refreshTempo(before,song);
        }
        serial->render(expected.getArrayOfWritePointers(),2,512);parallel->render(actual.getArrayOfWritePointers(),2,512);
        for(int c=0;c<2;++c)for(int n=0;n<512;++n){maximumError=std::max(maximumError,double(std::abs(actual.getSample(c,n)-expected.getSample(c,n))));energy+=std::abs(expected.getSample(c,n));}
    }
    auto report=object();put(report,"maximumPCMError",maximumError);put(report,"stream",parallel->streamDiagnostics());put(report,"serialUnderruns",(int64)serial->getUnderruns());put(report,"parallelUnderruns",(int64)parallel->getUnderruns());
    directory.getChildFile("parallel-clip-pcm.json").replaceWithText(JSON::toString(report));
    require(energy>1,"Parallel PCM comparison rendered only silence");
    require(maximumError<.0000001,"Parallel DSP changed PCM, routing, loop or secondary-head playback");
    require(num(parallel->streamDiagnostics(),"parallelClipTasks")>1000,"Comparison did not exercise parallel DSP");
    require(parallel->getUnderruns()==0 && serial->getUnderruns()==0,"Parallel PCM test lost source samples");
}
}
