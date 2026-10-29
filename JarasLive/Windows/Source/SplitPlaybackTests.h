#pragma once
#include "Session.h"
#include "ProjectCodec.h"
#include "ClipEditing.h"
#include "ClipAudio.h"
#include "FloatingControlTests.h"
namespace catlive::splitPlaybackTests {
inline void require(bool value,const char* why) {if(!value)throw std::runtime_error(why);}
inline void splitAtRelativeTempo() {
    for(bool printed:{false,true})for(bool looped:{false,true}) {
        jaras::Song song;song.id="relative-split";song.name="Song";song.duration=10;
        song.bpm=120;song.timeSettings=jaras::ProjectTimeSettings{};song.timeSettings->timebase=jaras::ProjectTimebase::relative;
        song.regionOwnershipInitialized=true;song.regionOwnershipVersion=3;song.parts={{"region","Music",0,10}};
        jaras::TimelineMarker initial{"tempo-0","TEMPO",0,0x999999};initial.tempoBPM=120;initial.tempoReferenceBPM=120;initial.regionOwnerID="region";
        auto faster=initial;faster.id="tempo-2";faster.position=2;faster.tempoBPM=240;
        auto slower=initial;slower.id="tempo-4";slower.position=4;slower.tempoBPM=60;
        song.markers=std::vector<jaras::TimelineMarker>{initial,faster,slower};
        std::vector<jaras::AudioClip> originals;
        std::set<ID> ids;
        for(int index=0;index<2;++index) {
            jaras::Track track;track.id="track-"+std::to_string(index);track.name="Audio";
            jaras::AudioClip clip;clip.id="item-"+std::to_string(index);clip.name="Original";clip.startTime=index;clip.duration=8-index;clip.sourceOffset=3+index;clip.playbackRate=index?.75:1.25;clip.audioFile=jaras::AudioFile{"signal.wav",{}};clip.regionOwnerID="region";
            clip.fadeIn=.05;clip.fadeOut=.07;if(printed)clip.renderedTempo=true;
            if(looped){clip.loopStart=1;clip.loopLength=4;}
            originals.push_back(clip);ids.insert(clip.id);track.clips={clip};song.tracks.push_back(track);
        }
        const auto before=song;std::map<ID,ID> sources;clipEditing::splitSelected(song,ids,3,&sources);
        require(sources.size()==2,"Relative split lost selected items");
        for(size_t index=0;index<song.tracks.size();++index) {
            const auto& track=song.tracks[index];require(track.clips.size()==2,"Relative split did not create both halves");
            const auto& left=track.clips[0];const auto& right=track.clips[1];
            require(left.fadeIn==.05&&left.fadeOut==0&&right.fadeIn==0&&right.fadeOut==.07,"Relative split lost outer fades or added a seam fade");
            require(sources.at(right.id)==left.id,"Relative split lost cached-source correspondence");
            ClipAudio originalClock(before,before.tracks[index],originals[index],48000,false);
            ClipAudio rightClock(song,track,right,48000,false);
            const auto distance=[&](double a,double b) {const auto delta=std::abs(a-b);return looped?std::min(delta,std::abs(delta-4)):delta;};
            for(double time:{3.,3.125,3.999,4.,4.125,5.,7.999})
                require(distance(rightClock.sourcePosition(time-right.startTime),originalClock.sourcePosition(time-originals[index].startTime))<1e-8,
                        "Right half restarted at the wrong source position after a relative-tempo cut");
        }
    }
}
inline void glueUndoRealtime(const File& directory) {
    const auto folder=directory.getChildFile("split-glue-streaming");require(folder.createDirectory().wasOk(),"Cannot create streaming split fixture");
    const auto source=folder.getChildFile("signal.wav");source.deleteFile();
    {auto stream=source.createOutputStream();WavAudioFormat wav;std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
     require(writer!=nullptr,"Cannot open streaming split fixture");AudioBuffer<float> signal(2,48000*4);for(int c=0;c<2;++c)FloatVectorOperations::fill(signal.getWritePointer(c),.1f,signal.getNumSamples());require(writer->writeFromAudioSampleBuffer(signal,0,signal.getNumSamples()),"Cannot write streaming split fixture");}
    jaras::Project project;project.id=uuid();project.name="Streaming Undo";project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
    jaras::Song song;song.id=uuid();song.name="Song";song.duration=4;
    jaras::Track track;track.id=uuid();track.name="Audio";jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=4;clip.audioFile=jaras::AudioFile{"signal.wav",{}};track.clips={clip};song.tracks={track};project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
    Session session;session.inspection=true;session.mediaDirectory=folder;session.document=folder.getChildFile("project.jl");session.restoreSnapshot(ProjectCodec::encode(project));
    session.splitClips({clip.id},1.5);std::set<ID> halves;for(const auto& item:session.song()->tracks[0].clips)halves.insert(item.id);
    session.renderItems(halves,true);const auto deadline=Time::getMillisecondCounterHiRes()+20000;
    while(session.busy&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
    require(!session.busy&&session.song()->tracks[0].clips.size()==1,"Streaming glue did not finish");
    session.undo();require(session.song()->tracks[0].clips.size()==2,"Streaming glue Undo lost a half");
    AudioEngine::State state;state.position=0;state.playing=true;session.audio.transportAsync(state);
    const auto prepared=Time::getMillisecondCounterHiRes()+5000;
    while(session.audio.preparingTransport()&&Time::getMillisecondCounterHiRes()<prepared)floatingControlTests::pump();
    require(!session.audio.preparingTransport(),"Streaming split transport did not prepare");
    require(num(session.audio.streamDiagnostics(),"primedSources")==1,"Future half overwrote the active half's reserved PCM");
    AudioBuffer<float> output(2,480);
    for(int block=0;block<320;++block) {
        session.audio.render(output.getArrayOfWritePointers(),2,480);
        // The explicit Play has a short onset ramp; all subsequent PCM,
        // including both sides of the split, must remain uninterrupted.
        for(int n=block==0?240:0;n<480;++n)require(std::abs(output.getSample(0,n)-.1f)<.004f,"Streaming split/glue Undo left a hole in one half");
        Thread::sleep(10);
    }
    state.playing=false;session.audio.transportAsync(state);
    // A different trim from the same file needs its own future prefetch.
    auto discontinuous=*session.song();
    discontinuous.tracks[0].clips[1].sourceOffset=2.75;
    discontinuous.tracks[0].clips[1].duration=1.25;
    AudioEngine independent;
    independent.prepareSong(discontinuous,folder,{},&project);
    independent.setMixer(project,discontinuous);
    state.position=0;state.playing=true;independent.transportAsync(state);
    const auto secondDeadline=Time::getMillisecondCounterHiRes()+5000;
    while(independent.preparingTransport()&&Time::getMillisecondCounterHiRes()<secondDeadline)floatingControlTests::pump();
    require(!independent.preparingTransport(),"Discontinuous source transport did not prepare");
    require(num(independent.streamDiagnostics(),"primedSources")==2,"Different source trim incorrectly skipped future prefetch");
    state.playing=false;independent.transportAsync(state);
}
inline void continuousCutsRealtime(const File &directory) {
    const auto folder=directory.getNonexistentChildFile("continuous-cut","");folder.createDirectory();
    const auto file=folder.getChildFile("signal.wav");
    {auto stream=file.createOutputStream();WavAudioFormat wav;std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
     require(writer!=nullptr,"Cannot create cut fixture");AudioBuffer<float> pcm(2,48000*9);for(int c=0;c<2;++c)for(int n=0;n<pcm.getNumSamples();++n)pcm.setSample(c,n,.1f*std::sin(float(2*MathConstants<double>::pi*800*n/48000)));writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples());}
    for(int scenario=0;scenario<3;++scenario) {
        const double speed=scenario==1?.8:1.;
        jaras::Song song;song.id=uuid();song.duration=8;
        jaras::Track track;track.id=uuid();track.name="Cut source";
        jaras::AudioClip clip;clip.id=uuid();clip.duration=8;clip.playbackRate=speed;clip.audioFile=jaras::AudioFile{"signal.wav",{}};track.clips={clip};song.tracks={track};
        std::set<ID> ids{clip.id};clipEditing::splitSelected(song,ids,2.00321);
        const auto right=song.tracks[0].clips[1].id;clipEditing::splitSelected(song,{right},4.01234);
        if(scenario==2)for(size_t i=1;i<song.tracks[0].clips.size();++i)song.tracks[0].clips[i].sourceOffset+=3;
        AudioEngine engine(44100);engine.prepareSong(song,folder);
        AudioEngine::State state;state.playing=true;engine.transportAsync(state);
        const auto deadline=Time::getMillisecondCounterHiRes()+10000;
        while(engine.preparingTransport()&&Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(!engine.preparingTransport(),"Cut test Play never became ready");
        AudioBuffer<float> pcm(2,512);float minimum=1;double worstAt=0;
        for(int block=0;block<440;++block) {
            engine.render(pcm.getArrayOfWritePointers(),2,512);
            for(int n=0;n<512;n+=128){double at=(block*512+n)/44100.;const float rms=pcm.getRMSLevel(0,n,128);if(at>.5&&at<5&&rms<minimum){minimum=rms;worstAt=at;}}
            Thread::sleep(12);
        }
        state.playing=false;engine.transportAsync(state);
        if(minimum<.04f)throw std::runtime_error("Cut gap at "+std::to_string(worstAt)+" scenario="+std::to_string(scenario)+" speed="+std::to_string(speed)+" minimum="+std::to_string(minimum)+" underruns="+std::to_string(engine.getUnderruns()));
    }
}

}
