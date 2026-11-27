#include "../../Core/Transport/Engine.hpp"
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static Project project(int count) {
    Project p; p.id="project"; p.name="Capacity";
    Song song; song.id="song"; song.name="Test"; song.duration=30;
    song.parts={{"region","Song",0,30}};
    TimelineMarker marker{"part","Part",10,0};marker.section=true;
    song.markers=std::vector<TimelineMarker>{marker};
    for(int i=0;i<count;++i) {
        Track track;track.id="track"+std::to_string(i);track.name=track.id;track.mute=true;
        AudioClip clip;clip.id="clip"+std::to_string(i);clip.duration=30;clip.audioFile=AudioFile{"same.wav",{}};clip.muted=true;
        track.clips={clip};song.tracks.push_back(track);
    }
    p.songs={song};return p;
}
template<class F> static void blocked(F operation) {
    try {operation();throw std::runtime_error("Unsafe operation was accepted");}
    catch(const std::invalid_argument& e){check(std::string(e.what())==playbackCapacity::notice,"Unexpected capacity error");}
}
int main(){try {
    auto p=project(251);check(playbackCapacity::peak(p)==251,"Opening peak must count muted copies independently");
    auto sequence=p;
    for(int i=0;i<251;++i){sequence.songs[0].tracks[i].clips[0].startTime=i*30.;}
    check(playbackCapacity::peak(sequence)==1,"Adjacent or sequential files do not overlap");
    auto second=p.songs[0];second.id="second";p.songs.push_back(second);
    check(playbackCapacity::peak(p)==251,"Separate arrangements are not simultaneous");
    for(int count:{250,251}) {
        Engine engine;engine.loadProject(project(count));engine.execute({CommandKind::play});
        check(engine.activeAudioFileCount()==std::size_t(count),"Mute/solo must not reduce the safety count");
        if(count==250){engine.execute({CommandKind::tempo,{},121});engine.execute({CommandKind::queueSection,"part"});engine.execute({CommandKind::toggleLoop});}
        else {
            const auto before=engine.transport();
            blocked([&]{engine.execute({CommandKind::tempo,{},121});});
            blocked([&]{engine.execute({CommandKind::queueSection,"part"});});
            blocked([&]{engine.execute({CommandKind::toggleLoop});});
            check(engine.currentSong()->bpm==120 && !engine.transport().loop.enabled && !engine.transport().queuedSectionMarkerId,"Refusal mutated the transport");
            auto marker=engine.currentSong()->markers->front();marker.tempoBPM=130;
            blocked([&]{engine.setMarkers({marker},{},true);});
        }
        engine.execute({CommandKind::stopAll});engine.execute({CommandKind::tempo,{},140});
        check(engine.currentSong()->bpm==140,"Stopped tempo edits must remain available");
    }
    auto clockOnly = project(320);
    auto& clockSong = clockOnly.songs.front();
    clockSong.parts.clear();
    clockSong.markers.reset();
    for (auto& track : clockSong.tracks) { track.mute = false; track.clips.front().muted = false; }
    clockSong.markers = std::vector<TimelineMarker>{{"cue", "Cue", 1, 0}};
    check(playbackCapacity::tempoChangesClockOnly(clockSong), "An ordinary cue should permit free BPM");
    clockSong.markers->front().tempoBPM = 125;
    check(!playbackCapacity::tempoChangesClockOnly(clockSong), "A tempo map needs the live guard");
    clockSong.markers.reset();
    clockSong.tracks.front().clips.front().midi.emplace();
    check(!playbackCapacity::tempoChangesClockOnly(clockSong), "A MIDI source still depends on tempo");
    clockSong.tracks.front().clips.front().midi.reset();
    Engine clock;clock.loadProject(clockOnly);clock.execute({CommandKind::play});
    check(clock.activeAudioFileCount()==320,"Expected 320 active files");
    clock.execute({CommandKind::tempo,{},137});
    check(clock.currentSong()->bpm==137 && clock.transport().playing,"Free BPM was blocked during playback");
    for (const auto& track : clock.currentSong()->tracks)
        check(track.clips.front().duration==30 && track.clips.front().playbackRate==1,"Free BPM altered an audio item");
    ProjectTimeSettings relative;relative.timebase=ProjectTimebase::relative;
    blocked([&]{ clock.setProjectTiming(138,4,4,relative); });
    Engine both;both.loadProject(project(126));both.execute({CommandKind::play});both.execute({CommandKind::subPlay});
    check(both.activeAudioFileCount()==252,"Total diagnostics count both playback heads");
    check(!both.liveCapacityExceeded(),"Play and Subplay each have their own250-voice allowance");
    both.execute({CommandKind::tempo,{},125});
    both.execute({CommandKind::subStop});both.execute({CommandKind::tempo,{},125});
    Engine full;full.loadProject(project(250));full.execute({CommandKind::play});full.execute({CommandKind::subPlay});
    check(full.activeAudioFileCount()==500 && !full.liveCapacityExceeded(),"250+250 must remain permitted");
    full.execute({CommandKind::tempo,{},121});
    // A saved Repeat cannot sneak past the guard just because it was armed
    // while stopped, nor may a long clock tick skip over a dense passage.
    Engine prearmed;prearmed.loadProject(project(250));
    prearmed.execute({CommandKind::loopStart,{},0});prearmed.execute({CommandKind::loopEnd,{},10});
    prearmed.execute({CommandKind::toggleLoop});
    check(prearmed.transport().loop.enabled,"Stopped Repeat should be configurable");
    prearmed.applyProjectEdit(project(251));
    prearmed.execute({CommandKind::play});
    check(!prearmed.transport().loop.enabled,"Prearmed Repeat survived Play above250");
    Engine stoppedDense;stoppedDense.loadProject(project(251));
    blocked([&]{stoppedDense.execute({CommandKind::toggleLoop});});
    auto density=project(250);
    Track extra;extra.id="later";extra.name="Later";
    AudioClip later;later.id="later-clip";later.startTime=5;later.duration=2;later.audioFile=AudioFile{"later.wav",{}};
    extra.clips={later};density.songs[0].tracks.push_back(extra);
    check(playbackCapacity::peak(density)==251,"Dense interval fixture");
    Engine crossing;crossing.loadProject(density);
    crossing.execute({CommandKind::loopStart,{},0});crossing.execute({CommandKind::loopEnd,{},10});
    crossing.execute({CommandKind::toggleLoop});crossing.execute({CommandKind::play});
    crossing.advance(11);
    check(!crossing.transport().loop.enabled && crossing.transport().position>10,"Prearmed Repeat wrapped across a dense interval");
    auto laterOutside=project(250);
    laterOutside.songs[0].tracks.push_back(extra);
    laterOutside.songs[0].tracks.back().clips[0].startTime=12;
    Engine sparseLoop;sparseLoop.loadProject(laterOutside);
    sparseLoop.execute({CommandKind::loopStart,{},0});sparseLoop.execute({CommandKind::loopEnd,{},10});
    sparseLoop.execute({CommandKind::toggleLoop});sparseLoop.execute({CommandKind::play});sparseLoop.advance(11);
    check(sparseLoop.transport().loop.enabled && sparseLoop.transport().position<2,"Dense audio outside the loop must not block a sparse Repeat");
    auto secondaryDensity=project(250);
    secondaryDensity.songs[0].tracks.push_back(extra);
    secondaryDensity.songs[0].tracks.back().clips[0].startTime=15;
    Engine secondary;secondary.loadProject(secondaryDensity);secondary.execute({CommandKind::play});
    secondary.execute({CommandKind::subSeek,{},14});secondary.execute({CommandKind::subPlay});
    secondary.execute({CommandKind::loopStart,{},0});secondary.execute({CommandKind::loopEnd,{},10});
    secondary.execute({CommandKind::toggleLoop});secondary.advance(4);
    check(!secondary.transport().loop.enabled,"SubPlay crossed 250 without disabling Repeat");
    Engine queued;queued.loadProject(density);queued.execute({CommandKind::play});
    queued.execute({CommandKind::queueSection,"part"});
    queued.advance(11);
    check(!queued.transport().queuedSectionMarkerId && queued.transport().sectionJumpSerial==0,"Queued Part jumped across a dense interval");
    auto denseDestination=project(250);
    denseDestination.songs[0].tracks.push_back(extra);
    denseDestination.songs[0].tracks.back().clips[0].startTime=9;
    Engine destination;destination.loadProject(denseDestination);destination.execute({CommandKind::play});
    blocked([&]{destination.execute({CommandKind::queueSection,"part"});});
    auto total=project(251);total.songs[0].parts[0].totalLoop=true;
    Engine savedTotal;savedTotal.loadProject(total);savedTotal.execute({CommandKind::play});
    savedTotal.advance(31);
    check(!savedTotal.transport().loop.enabled && !savedTotal.transport().multiLoop,"Saved Total Loop activated above250");
    auto multi=density;
    TimelineMarker first{"first","First",1,0};first.section=true;
    auto secondMarker=multi.songs[0].markers->front();secondMarker.loopSection=true;
    multi.songs[0].markers=std::vector<TimelineMarker>{first,secondMarker};
    MultiLoop saved;saved.id="saved-loop";saved.name="Saved";saved.marker1="first";saved.marker2="part";saved.fadeSeconds=1;
    multi.songs[0].parts[0].multiLoops={saved};
    Engine savedMulti;savedMulti.loadProject(multi);savedMulti.execute({CommandKind::play});
    savedMulti.advance(11);
    check(!savedMulti.transport().loop.enabled && savedMulti.transport().position>10,"Saved multiloop wrapped across a dense interval");
    std::cout<<"PLAYBACK_CAPACITY_250_251_MUTED_SHARED_FILES_PEAK_BOUNDARIES_HEADS_PREARMED_LOOPS_PARTS_STOPPED_AND_ATOMIC_REJECTION_OK\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
