#pragma once
#include "Session.h"

namespace catlive::multiLoopPlaybackTests {
inline void require(bool okay, const char *why) { if (!okay) throw std::runtime_error(why); }
inline void playback(const File &directory) {
    const auto folder=directory.getChildFile("multiloop-audio-"+text(uuid()));
    folder.createDirectory();
    AudioBuffer<float> signal(2,48000*8);
    for(int ch=0;ch<2;++ch)FloatVectorOperations::fill(signal.getWritePointer(ch),.01f,signal.getNumSamples());
    auto stream=folder.getChildFile("signal.wav").createOutputStream();
    require(bool(stream),"Could not create multiloop fixture");
    WavAudioFormat wav;
    std::unique_ptr<AudioFormatWriter> writer(wav.createWriterFor(stream.get(),48000,2,24,{},0));
    require(bool(writer),"Could not create fixture writer"); stream.release();
    require(writer->writeFromAudioSampleBuffer(signal,0,signal.getNumSamples()),"Could not write fixture");writer.reset();
    Session session;session.inspection=true;session.mediaDirectory=folder;
    auto project=Session::makeEmptyProject("Multiloop audio");
    project.masterVolume=1;project.masterOutputs=std::vector<jaras::OutputPatch>{{1,2}};
    auto &song=project.songs.front();song.tracks.clear();song.parts.clear();song.duration=8;
    jaras::Track group,child,normal;group.id=uuid();group.name="Group";
    child.id=uuid();child.name="Member";child.parentTrackID=group.id;
    normal.id=uuid();normal.name="Normal";
    jaras::AudioClip clip;clip.id=uuid();clip.name="Signal";clip.duration=8;clip.audioFile=jaras::AudioFile{"signal.wav",{}};
    child.clips={clip};clip.id=uuid();normal.clips={clip};song.tracks={group,child,normal};
    jaras::TimelineMarker first{uuid(),"Start",2,0},last{uuid(),"End",4,0};
    first.section=true;first.loopSection=true;last.section=true;last.loopSection=true;
    song.markers=std::vector<jaras::TimelineMarker>{first,last};
    jaras::Part region{uuid(),"Song",0,8};
    jaras::MultiLoop loop;loop.id=uuid();loop.name="Passage";loop.marker1=first.id;loop.marker2=last.id;loop.fadeSeconds=1;
    loop.mixerEnabled=false; // The removed global switch cannot suppress saved per-track rules.
    loop.tracks={{group.id,.25,true,false,false},{normal.id,.5,true,false,false}};
    region.multiLoops={loop};song.parts={region};
    AudioBuffer<float> output(2,480);
    const auto load=[&](double at) {
        session.command(jaras::CommandKind::stopAll);
        project.savedCursor=jaras::SavedProjectCursor{song.id,at};
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        session.command(jaras::CommandKind::seek,{},at);session.command(jaras::CommandKind::play);
    };
    const auto render=[&] {session.audio.render(output.getArrayOfWritePointers(),2,480);};
    load(3);render();
    require(std::abs(output.getSample(0,240)-.0075f)<.00002f,"Group/normal Auto Fader did not reach the audio output");
    require(std::abs(session.trackDisplayVolume(group.id,1)-.25)<.00001 && std::abs(session.trackDisplayVolume(normal.id,1)-.5)<.00001,"Visible faders do not follow Auto Fader");
    require(session.song()->tracks[0].volume==1 && session.song()->tracks[2].volume==1,"Loop changed saved manual volume");
    session.command(jaras::CommandKind::toggleMultiLoopBypass);render();
    require(std::abs(output.getSample(0,240)-.02f)<.00002f,"Bypass did not restore the ordinary mix");
    require(session.trackDisplayVolume(group.id,1)==1,"Bypass left the display fader changed");
    session.command(jaras::CommandKind::toggleMultiLoopBypass);
    session.command(jaras::CommandKind::stopAll);render();
    require(output.getMagnitude(0,480)==0 && session.trackDisplayVolume(group.id,1)==1,"Stop retained loop audio or controls");
    load(1.5);render();
    // Two independent fades: at 1.505s the group is .62125 and normal .7475.
    require(std::abs(output.getSample(0,240)-.0136875f)<.00002f,"Pre-loop Auto Fader is not driven by the audio clock");
    load(3);
    auto released=*session.transport().multiLoop;released.released=true;released.releasePosition=3;
    session.audio.setLoopMixer(released);
    AudioEngine::State state;state.playing=true;state.position=3.5;session.audio.transport(state);render();
    require(std::abs(output.getSample(0,240)-.0138125f)<.00002f,"Released loop did not fade back to manual levels");
    state.position=4.1;session.audio.transport(state);render();
    require(std::abs(output.getSample(0,240)-.02f)<.00002f,"Loop gain persisted after its end");
    auto &rules=song.parts[0].multiLoops[0].tracks;
    rules[0].autoFader=false;rules[1].autoFader=false;rules[0].mute=true;
    load(3);render();
    require(std::abs(output.getSample(0,240)-.01f)<.00002f,"Loop group mute failed to gate its member");
    require(session.trackDisplayMute(group.id,false) && !session.song()->tracks[0].mute,"Mute feedback or saved manual state is incorrect");
    rules[0].mute=false;rules[0].solo=true;
    load(3);render();
    require(std::abs(output.getSample(0,240)-.01f)<.00002f,"Loop group solo did not retain its member and silence other tracks");
    require(session.trackDisplaySolo(group.id,false) && !session.song()->tracks[0].solo,"Solo feedback or saved manual state is incorrect");
    rules[0].solo=false;rules.push_back({"00000000-0000-0000-0000-000000000000",.5,true,false,false});
    load(3);render();
    require(std::abs(output.getSample(0,240)-.01f)<.00002f,"Loop Master Auto Fader failed");
    require(std::abs(session.trackDisplayVolume({},1)-.5)<.00001,"Master fader did not follow the loop");
    session.command(jaras::CommandKind::stopAll);
}
}
