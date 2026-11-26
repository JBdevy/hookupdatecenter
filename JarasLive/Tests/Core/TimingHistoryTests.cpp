#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <iostream>
using namespace jaras;
int main() {
    Project p;p.id="project";p.name="Timing";Song song;song.id="song";song.name="Song";song.duration=12;
    Track track;track.id="track";track.name="Audio";
    AudioClip clip;clip.id="item";clip.duration=10;clip.waveform={.1,.2,.3};clip.waveformChannels={{.4,.5},{.6,.7}};track.clips={clip};song.tracks={track};
    Part part;part.id="part";part.name="Part";part.endTime=10;song.parts={part};p.songs={song};
    Engine engine;engine.loadProject(p);
    auto pointer=engine.currentSong()->tracks[0].clips[0].waveform.data();
    auto snapshot=engine.timingSnapshot();
    assert(snapshot.songs[0].tracks[0].clips[0].waveform.empty());
    assert(snapshot.songs[0].tracks[0].clips[0].waveformChannels.empty());
    assert(engine.currentSong()->tracks[0].clips[0].waveform.data()==pointer);
    auto changed=snapshot;changed.songs[0].bpm=140;changed.songs[0].tracks[0].clips[0].duration=8;
    engine.restoreTimingSnapshot(changed);
    assert(engine.currentSong()->bpm==140 && engine.currentSong()->tracks[0].clips[0].duration==8);
    assert(engine.currentSong()->tracks[0].clips[0].waveform==clip.waveform);
    assert(engine.currentSong()->tracks[0].clips[0].waveformChannels==clip.waveformChannels);
    assert(engine.currentSong()->tracks[0].clips[0].waveform.data()==pointer);
    engine.restoreTimingSnapshot(snapshot);
    assert(engine.currentSong()->bpm==120 && engine.currentSong()->tracks[0].clips[0].duration==10);
    auto invalid=snapshot;invalid.songs[0].tracks[0].clips.clear();bool failed=false;
    try { engine.restoreTimingSnapshot(invalid); } catch (...) { failed=true; }
    assert(failed && engine.currentSong()->tracks[0].clips[0].waveform.data()==pointer);
    engine.setRegionPitchState("part",1,std::vector<ID>{"track"},std::vector<ID>{});
    assert(engine.currentSong()->parts[0].pitchSemitones==1);
    engine.setRegionPitchState("part",{},{},{});
    assert(!engine.currentSong()->parts[0].pitchSemitones && !engine.currentSong()->parts[0].pitchTrackIDs);
    failed=false;try { engine.setRegionPitchState("part",1,std::vector<ID>{"missing"},{}); }catch(...){failed=true;}
    assert(failed && !engine.currentSong()->parts[0].pitchSemitones);
    std::cout << "TIMING_HISTORY_PRESERVES_PEAK_STORAGE_AND_PITCH_DEFAULTS_OK\n";
}
