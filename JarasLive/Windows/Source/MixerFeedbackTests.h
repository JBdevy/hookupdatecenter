#pragma once
#include "Session.h"
#include "TrackTree.h"
namespace catlive::mixerFeedbackTests {
inline void require(bool okay,const char* why) {if(!okay)throw std::runtime_error(why);}
inline void controlsWithoutArrangementRebuild() {
    Session session;session.inspection=true;
    jaras::Project project;project.id=uuid();project.name="Mixer feedback";
    jaras::Song song;song.id=uuid();song.name="Song";song.duration=10;
    for(int i=0;i<5;++i) {
        jaras::Track track;track.id=uuid();track.name="Track "+std::to_string(i);track.volume=i==0?.8:.4;track.pan=i==0?-.25:.25;
        jaras::AudioClip clip;clip.id=uuid();clip.name="Waveform";clip.duration=10;clip.waveform.assign(300000,.1);track.clips={std::move(clip)};
        song.tracks.push_back(std::move(track));
    }
    song.tracks[2].parentTrackID=song.tracks[1].id;
    song.tracks[3].parentTrackID=song.tracks[2].id;
    song.tracks[4].parentTrackID=song.tracks[1].id;
    const ID first=song.tracks[0].id,second=song.tracks[1].id;
    const ID nested=song.tracks[2].id,child=song.tracks[3].id;
    project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
    session.restoreSnapshot(ProjectCodec::encode(project));
    const auto* peaks=session.song()->tracks[0].clips[0].waveform.data();
    const auto* graph=session.audio.preparationDiagnostics.getDynamicObject();
    int mixer=0,general=0;
    session.changed=[&]{++general;};session.mixerChanged=[&]{++mixer;};
    const auto revision=session.revision;
    session.mixerCommand(jaras::CommandKind::mute,first,{first,second});
    require(mixer==1&&general==0&&session.revision==revision+1,"Mute used full arrangement notification or failed to publish state");
    require(session.song()->tracks[0].mute&&session.song()->tracks[1].mute,"Selected Mute state did not change synchronously");
    session.mixerCommand(jaras::CommandKind::mute,first,{first,second});
    require(!session.song()->tracks[0].mute&&!session.song()->tracks[1].mute,"Selected Unmute did not change synchronously");
    session.mixerCommand(jaras::CommandKind::solo,second,{second});
    require(trackTree::silenced(*session.song(),session.song()->tracks[0])&&!trackTree::silenced(*session.song(),session.song()->tracks[2]),"Group Solo did not immediately preserve child presentation and dim other tracks");
    require(!trackTree::silenced(*session.song(),session.song()->tracks[3])&&!trackTree::silenced(*session.song(),session.song()->tracks[4]),"Outer-group Solo did not preserve all nested descendants");
    session.mixerCommand(jaras::CommandKind::solo,second,{second});
    auto checkSoloRefresh=[&](const ID& target) {
        const auto beforeMixer=mixer,beforeGeneral=general;const auto beforeRevision=session.revision;
        session.mixerCommand(jaras::CommandKind::solo,target,{target});
        require(mixer==beforeMixer+1&&general==beforeGeneral&&session.revision==beforeRevision+1,"Solo failed to synchronously refresh all mixer surfaces and publish state");
    };
    checkSoloRefresh(nested);
    require(!trackTree::silenced(*session.song(),session.song()->tracks[1])&&!trackTree::silenced(*session.song(),session.song()->tracks[2])&&!trackTree::silenced(*session.song(),session.song()->tracks[3]),"Nested-group Solo dimmed its ancestors or child");
    require(trackTree::silenced(*session.song(),session.song()->tracks[0])&&trackTree::silenced(*session.song(),session.song()->tracks[4]),"Nested-group Solo left unrelated tracks coloured");
    checkSoloRefresh(nested);
    checkSoloRefresh(child);
    require(!trackTree::silenced(*session.song(),session.song()->tracks[1])&&!trackTree::silenced(*session.song(),session.song()->tracks[2])&&!trackTree::silenced(*session.song(),session.song()->tracks[3])&&trackTree::silenced(*session.song(),session.song()->tracks[4]),"Child Solo did not keep both ancestor groups visible while dimming its sibling");
    checkSoloRefresh(child);
    for(const auto& track:session.song()->tracks)require(!trackTree::silenced(*session.song(),track),"Turning Solo off did not immediately restore track colours");
    session.beginMixerGesture(jaras::CommandKind::volume,first);
    session.mixerCommand(jaras::CommandKind::volume,first,{first,second},.4);
    session.mixerCommand(jaras::CommandKind::volume,first,{first,second},.2);
    session.endMixerGesture();
    require(std::abs(session.song()->tracks[0].volume-.2)<1e-9&&std::abs(session.song()->tracks[1].volume-.1)<1e-9,"Lightweight gesture lost relative selected-track volume");
    session.mixerCommand(jaras::CommandKind::volume,first,{first,second},.4);
    require(std::abs(session.song()->tracks[1].volume-.2)<1e-9,"Immediate volume command read its already-modified source baseline");
    session.mixerCommand(jaras::CommandKind::pan,first,{first,second},0);
    require(std::abs(session.song()->tracks[1].pan-.5)<1e-9,"Immediate pan command read its already-modified source baseline");
    const auto beforeMaster=mixer;session.command(jaras::CommandKind::mute);
    require(session.project().masterMute&&mixer==beforeMaster+1&&general==0,"Master Mute used full arrangement notification");
    const auto beforeMasterSolo=mixer;session.command(jaras::CommandKind::solo);
    require(session.project().masterSolo&&mixer==beforeMasterSolo+1&&general==0,"Master Solo failed to refresh its buttons immediately");
    session.command(jaras::CommandKind::solo);
    require(!session.project().masterSolo&&mixer==beforeMasterSolo+2&&general==0,"Master Solo off failed to refresh its buttons immediately");
    require(session.song()->tracks[0].clips[0].waveform.data()==peaks,"Mixer replaced waveform arrays");
    require(session.audio.preparationDiagnostics.getDynamicObject()==graph&&!session.preparingLiveAudio(),"Mixer rebuilt the audio graph");
    session.mixerChanged={};session.command(jaras::CommandKind::mute);
    require(general==1&&!session.project().masterMute,"Non-workspace mixer notification fallback failed");
}
}
