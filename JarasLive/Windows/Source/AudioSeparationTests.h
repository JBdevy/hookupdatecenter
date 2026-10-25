#pragma once
#include "AudioSeparation.h"
namespace catlive::audioSeparationTests {
template<class Test,class Fixture> void run(Test &&test,Fixture fixture) {
 test("Audio separation commits five aligned tracks and preserves folder order atomically",[&]{
    auto require=[](bool okay,const char *message){if(!okay)throw std::runtime_error(message);};
    auto p=fixture();auto &song=p.songs[0];song.tracks.clear();song.parts.clear();song.markers.reset();song.duration=60;
    jaras::Track folder;folder.id=uuid();folder.name="Folder";
    jaras::Track source;source.id=uuid();source.name="Original";source.parentTrackID=folder.id;
    jaras::AudioClip clip;clip.id=uuid();clip.name="Source";clip.startTime=23;clip.duration=8;clip.sourceOffset=4;clip.playbackRate=1.2;clip.gain=.75;clip.audioFile=jaras::AudioFile{"Stems/source.wav",{}};source.clips={clip};
    jaras::Track child;child.id=uuid();child.name="Existing child";child.parentTrackID=source.id;
    jaras::Track last;last.id=uuid();last.name="Existing sibling";last.parentTrackID=folder.id;
    song.tracks={folder,source,child,last};const auto songID=song.id;
    std::vector<jaras::Track> stems;
    for(int i=0;i<5;i++){jaras::Track t;t.id=uuid();t.name="Stem";t.parentTrackID=folder.id;auto c=clip;c.id=uuid();c.sourceOffset=0;c.playbackRate=1;c.audioFile=jaras::AudioFile{"Stems/stem"+std::to_string(i)+".wav",{}};t.clips={c};stems.push_back(t);}
    const auto original=JSON::toString(ProjectCodec::encode(p),true);
    auto failed=p;auto changed=clip;changed.duration+=1;bool rejected=false;
    try{audioSeparation::commit(failed,songID,source.id,changed,stems);}catch(...){rejected=true;}
    require(rejected&&JSON::toString(ProjectCodec::encode(failed),true)==original,"Changed source was partially modified");
    auto incomplete=stems;incomplete.pop_back();rejected=false;
    try{audioSeparation::commit(failed,songID,source.id,clip,incomplete);}catch(...){rejected=true;}
    require(rejected&&JSON::toString(ProjectCodec::encode(failed),true)==original,"Incomplete stems partially modified project");
    audioSeparation::commit(p,songID,source.id,clip,stems);const auto &tracks=p.songs[0].tracks;
    require(tracks.size()==9&&tracks[0].id==folder.id&&tracks[1].id==source.id&&tracks[2].id==child.id&&tracks[8].id==last.id,"Existing folder tracks moved");
    auto restored=tracks[1].clips[0];require(restored.muted&&restored.separatedStemTracks.size()==5,"Original was not preserved/muted");
    restored.muted=clip.muted;restored.separatedStemTracks=clip.separatedStemTracks;
    require(audioSeparation::fingerprint(restored)==audioSeparation::fingerprint(clip),"Original media or timing changed");
    for(int i=0;i<5;i++)require(tracks[size_t(i)+3].id==stems[size_t(i)].id&&tracks[size_t(i)+3].parentTrackID==folder.id,"Stem order/hierarchy differs from Mac");
    require(audioSeparation::outputName("Drum","Source.mp3")=="Drum - Source","Output label differs from Mac");
    require(audioSeparation::outputName("Vocal","Source.v2")=="Vocal - Source.v2","Non-extension name was truncated");
    require(audioSeparation::eligible(source,clip),"Ordinary audio rejected");clip.midi.emplace();require(!audioSeparation::eligible(source,clip),"MIDI accepted");clip.midi.reset();clip.audioFile->path="Videos/test.mp4";require(!audioSeparation::eligible(source,clip),"Video accepted");
 });
}
}
