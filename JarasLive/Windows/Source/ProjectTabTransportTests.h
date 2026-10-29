#pragma once
#include "FloatingControlTests.h"
namespace catlive::projectTabTransportTests {
inline void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
inline jaras::Project fixture(int index, int tracks = 16) {
    auto project = floatingControlTests::fixture();
    project.name = "Tab " + std::to_string(index);
    auto &song = project.songs.front();
    song.duration = .5; song.tracks.clear();
    song.parts = {{"first", "First", 0, .25}, {"second", "Second", .25, .5}};
    for (int i=0; i<tracks; ++i) {
        jaras::Track track; track.id=uuid(); track.name="Track "+std::to_string(i);
        track.role.id="other";
        jaras::AudioClip clip; clip.id=uuid(); clip.name="Tone"; clip.duration=.25;
        clip.audioFile=jaras::AudioFile{"tone.wav",{}};
        track.clips={clip}; clip.id=uuid(); clip.startTime=.25; clip.sourceOffset=.25;
        track.clips.push_back(clip); song.tracks.push_back(track);
    }
    project.regionSetlist=jaras::RegionSetlist{};
    project.regionSetlist->autoAdvance=true;
    project.regionSetlist->stopAtRegionEnd=true;
    project.regionSetlist->playlists={{"playlist", "Playlist", song.id, {"first","second"}}};
    project.regionSetlist->selectedId="playlist";
    return project;
}
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Project tabs keep hidden controls idle while Auto advances and refresh on activation", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(fixture(0,0))); session.audio.setOffline(true);
        Auth auth; Lighting lighting(session);
        Workspace workspace(session,auth,lighting,false,directory.getNonexistentChildFile("hidden-tab", ".json"));
        workspace.setSize(1366,768);
        // Native transport buttons are not children in the JUCE component tree.
        const auto playState=[&] { return get(get(workspace.diagnostics(),"controls"),"play"); };
        workspace.deactivateProjectTab();
        const auto before=str(playState(),"text");
        session.command(jaras::CommandKind::selectRegion,"first");
        session.command(jaras::CommandKind::play);
        AudioBuffer<float> pcm(2,480);
        for(int block=0;block<30;++block) {
            session.audio.render(pcm.getArrayOfWritePointers(),2,480);
            (void)session.projectSyncFrame();
            if(session.tick)session.tick();
        }
        require(session.transport().playing && session.transport().regionId==ID("second"),
                "Hidden project stopped advancing its Auto queue");
        require(str(playState(),"text")==before && !flag(playState(),"active"),"Hidden tab refreshed transport controls every tick");
        workspace.activateProjectTab();
        require(flag(playState(),"active"),"Reactivated tab did not refresh the running transport");
        session.command(jaras::CommandKind::stop);
    });
    test("Project tabs return to idle timer cadence after an automatic region stop", [&] {
        Session session; session.inspection=true; session.audio.prepareOffline(48000);
        auto project=fixture(0,0); project.regionSetlist->autoAdvance=false;
        session.restoreSnapshot(ProjectCodec::encode(project)); session.audio.setOffline(true);
        session.command(jaras::CommandKind::selectRegion,"first");
        session.command(jaras::CommandKind::play);
        session.core.advance(.3);
        require(!session.transport().playing,"Region Stop fixture did not finish");
        int ticks=0; session.tick=[&]{++ticks;};
        const auto deadline=Time::getMillisecondCounterHiRes()+700;
        while(Time::getMillisecondCounterHiRes()<deadline)floatingControlTests::pump();
        require(ticks>0 && ticks<=10,"Automatically stopped project kept a playback-rate UI timer");
        session.tick={};
    });
    test("Project tabs repeat Stop Play and Auto across six independent audio sessions", [&] {
        const auto media=directory.getNonexistentChildFile("project-tab-transport", "");
        require(media.createDirectory().wasOk(),"Cannot create tab fixture folder");
        {WavAudioFormat wav;auto stream=media.getChildFile("tone.wav").createOutputStream();
         std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.release(),48000,2,24,{},0));
         require(bool(writer),"Cannot create tab audio fixture");AudioBuffer<float> pcm(2,48000);
         for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(pcm.getWritePointer(ch),.01f,pcm.getNumSamples());
         require(writer->writeFromAudioSampleBuffer(pcm,0,pcm.getNumSamples()),"Cannot write tab audio fixture");}
        auto host=std::make_shared<AudioDeviceManager>();
        std::vector<std::unique_ptr<Session>> sessions;
        for(int i=0;i<6;++i) {
            auto session=std::make_unique<Session>(host);session->inspection=true;
            session->mediaDirectory=media;session->audio.prepareOffline(48000);
            session->restoreSnapshot(ProjectCodec::encode(fixture(i)));session->audio.setOffline(true);
            require(session->audio.deviceHost==host,"Tab did not share the device manager");
            sessions.push_back(std::move(session));
        }
        AudioBuffer<float> pcm(2,480);double maximumCommandMs=0,maximumRenderMs=0;
        const auto command=[&](Session &s,jaras::CommandKind kind,const ID &id=ID{}) {
            const auto start=Time::getMillisecondCounterHiRes();s.command(kind,id);
            maximumCommandMs=std::max(maximumCommandMs,Time::getMillisecondCounterHiRes()-start);
        };
        for(int cycle=0;cycle<24;++cycle) {
            auto &current=*sessions[size_t(cycle)%sessions.size()];
            command(current,jaras::CommandKind::selectRegion,"first");
            command(current,jaras::CommandKind::play);
            for(int block=0;block<30;++block) {
                for(auto &session:sessions) {
                    const auto start=Time::getMillisecondCounterHiRes();
                    session->audio.render(pcm.getArrayOfWritePointers(),2,480);
                    maximumRenderMs=std::max(maximumRenderMs,Time::getMillisecondCounterHiRes()-start);
                    if(session.get()==&current && block>0)
                        require(pcm.getMagnitude(0,480)>.1f,"Auto transition lost the active project's PCM");
                    if(session.get()!=&current)
                        require(pcm.getMagnitude(0,480)<.0001f,"Stopped tab emitted audio from another project");
                    (void)session->projectSyncFrame();
                }
            }
            require(current.transport().playing && current.transport().regionId==ID("second"),"Auto did not advance in the selected project");
            command(current,jaras::CommandKind::stop);
            command(current,jaras::CommandKind::play);
            current.audio.render(pcm.getArrayOfWritePointers(),2,480);
            require(current.audio.state().playing,"Immediate Play after Stop was lost");
            command(current,jaras::CommandKind::stop);
            current.audio.render(pcm.getArrayOfWritePointers(),2,480);
        }
        auto result=object();put(result,"projects",6);put(result,"tracksPerProject",16);
        put(result,"autoTransitions",24);put(result,"stopPlayRestarts",24);
        put(result,"maximumCommandMs",maximumCommandMs);put(result,"maximumRenderMs",maximumRenderMs);
        directory.getChildFile("project-tab-transport.json").replaceWithText(JSON::toString(result,true));
        require(maximumCommandMs<500,"Transport command stalled with idle projects open");
    });
}
}
