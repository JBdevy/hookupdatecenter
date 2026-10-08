#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Songs/TempoEditMap.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void expect(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
static void near(double actual,double expected,const char* message) {
    if(std::abs(actual-expected)>1e-8) throw std::runtime_error(std::string(message)+": "+std::to_string(actual)+" vs "+std::to_string(expected));
}
static TimelineMarker tempo(ID id,double position,std::optional<ID> owner,double bpm=120) {
    TimelineMarker result{std::move(id),"TEMPO",position,0x999999};
    result.tempoBPM=bpm;result.tempoBeats=4;result.tempoUnit=4;result.tempoTimebase="global";result.tempoReferenceBPM=120;result.regionOwnerID=std::move(owner);
    return result;
}
static Project fixture() {
    Project project;project.id="tempo-tail-project";project.name="Owned tails";
    Song song{"tempo-tail-song","Song",40,120,{},{}};
    song.regionOwnershipInitialized=true;song.timeSettings=ProjectTimeSettings{};song.timeSettings->timebase=ProjectTimebase::relative;
    song.parts={{"a","A",0,16},{"b","B",10,30},{"group","Unified",0,30}};
    song.parts[0].parentRegionID="group";song.parts[1].parentRegionID="group";
    Track track;track.id="audio";track.name="Audio";track.role={"other"};
    const auto add=[&](ID id,double start,double duration,std::optional<ID> owner) {
        AudioClip clip;clip.id=std::move(id);clip.name=clip.id;clip.startTime=start;clip.duration=duration;
        clip.audioFile=AudioFile{"Stems/source.wav"};clip.sourceOffset=3;clip.gain=0.5;clip.playbackRate=1.25;clip.regionOwnerID=std::move(owner);
        track.clips.push_back(std::move(clip));
    };
    add("early",2,14,"a");add("late",11,3,"a");add("beyond",31,3,"a");
    add("root",2,14,"group");add("root-late",11,3,"group");add("loose",11,3,{});add("next",10,20,"b");
    song.tracks={track};song.markers=std::vector<TimelineMarker>{tempo("a-start",0,"a"),tempo("a-middle",4,"a"),tempo("b-start",10,"b"),tempo("b-middle",12,"b")};
    project.songs={song};return project;
}
static const AudioClip& clip(const Engine& engine,const ID& id) {
    for(const auto& value:engine.currentSong()->tracks[0].clips) if(value.id==id) return value;
    throw std::runtime_error("Missing test clip");
}
static void edit(Engine& engine,const ID& id,double bpm,bool batch=false) {
    for(auto marker:*engine.currentSong()->markers) if(marker.id==id) {
        marker.tempoBPM=bpm;
        if(batch) engine.setMarkers({marker},{},true);
        else engine.setMarker(marker.id,marker.name,marker.position,marker.color,bpm,4,4,"global");
        return;
    }
    throw std::runtime_error("Missing test marker");
}
int main() {
    try {
        for(bool batch:{false,true}) {
            Engine engine;engine.loadProject(fixture());
            edit(engine,"b-start",240,batch);
            near(clip(engine,"early").duration,14,"following tempo must not resize an owned previous-song tail");
            near(clip(engine,"late").startTime,11,"following tempo must not move a late item belonging to the previous song");
            near(clip(engine,"late").duration,3,"following tempo must not resize a late previous-song item");
            near(clip(engine,"beyond").startTime,31,"persisted ownership survives a tail beyond the unified end");
            near(clip(engine,"root").duration,14,"root-owned crossing item resolves its original child from its onset");
            near(clip(engine,"root-late").startTime,10.5,"root-owned later onset resolves the next child");
            near(clip(engine,"root-late").duration,2.5,"root-owned next-child item uses that child's internal tempo changes");
            near(clip(engine,"loose").startTime,10.5,"intentionally loose audio retains global timeline behavior");
            near(clip(engine,"loose").duration,2.5,"intentionally loose audio is not assigned a region tempo owner");
            expect(!clip(engine,"loose").regionOwnerID && clip(engine,"late").regionOwnerID=="a","retiming preserves persisted ownership including nil");
            edit(engine,"b-start",120,batch);
            near(clip(engine,"late").startTime,11,"next-song reversal preserves previous-song onset");
            near(clip(engine,"next").duration,20,"next-song reversal restores its own duration");
        }
        for(bool batch:{false,true}) {
            Engine engine;engine.loadProject(fixture());edit(engine,"a-middle",240,batch);
            near(clip(engine,"early").duration,8,"last internal tempo extends through the complete outgoing tail");
            near(clip(engine,"late").startTime,7.5,"late onset follows its owner's internal musical time");
            near(clip(engine,"late").duration,1.5,"late item uses last owner tempo beyond next onset");
            near(clip(engine,"beyond").startTime,17.5,"last owner tempo also extends beyond the unified end");
            near(clip(engine,"beyond").duration,1.5,"tail beyond all regions retains owner tempo");
            near(clip(engine,"early").sourceOffset,3,"retiming preserves source trim");
            near(clip(engine,"early").playbackRate,1.25,"tempo edit map does not overwrite source rate");
            expect(clip(engine,"early").gain==0.5,"retiming preserves item gain");
            edit(engine,"a-middle",120,batch);
            near(clip(engine,"early").duration,14,"owner tempo reversal restores its full outgoing tail");
            near(clip(engine,"late").startTime,11,"owner tempo reversal restores late onset");
            near(clip(engine,"beyond").startTime,31,"owner tempo reversal restores onset beyond the group");
        }
        {
            auto project=fixture();
            project.songs[0].markers->push_back(tempo("foreign",6,"b"));
            Engine engine;engine.loadProject(project);edit(engine,"foreign",240);
            near(clip(engine,"early").duration,14,"foreign-owned tempo inside the owner's time span cannot resize its item");
            near(clip(engine,"late").startTime,11,"foreign-owned tempo cannot move its overlapping neighbor's item");
        }
        for(std::optional<ID> markerOwner:{std::optional<ID>{"a"},std::optional<ID>{"group"},std::optional<ID>{}}) {
            auto project=fixture();
            project.songs[0].parts.push_back({"unrelated","Other region",5,9});
            project.songs[0].markers->push_back(tempo("internal",7,markerOwner));
            Engine engine;engine.loadProject(project);edit(engine,"internal",240);
            near(clip(engine,"early").duration,9.5,"only a sibling boundary limits internal tempo, including parent-owned and legacy nil markers");
        }
        {
            auto before=fixture().songs[0];before.regionOwnershipInitialized=false;
            before.tracks[0].clips[0].regionOwnerID.reset();
            auto after=before;after.markers->at(2).tempoBPM=240;
            TempoEditMap map(before,after);map.apply(after);
            near(after.tracks[0].clips[0].duration,14,"uninitialized legacy data retains onset-based tempo ownership");
        }
        {
            auto project=fixture();auto& item=project.songs[0].tracks[0].clips[1];
            item.startTime=8;item.regionOwnerID="b";
            Engine engine;engine.loadProject(project);edit(engine,"a-middle",240);
            near(clip(engine,"late").startTime,5,"a leading item uses signed local time before its owner's mapped onset");
            near(clip(engine,"late").duration,3,"a leading item does not inherit the preceding song's tempo");
        }
        std::cout<<"TEMPO_OWNERSHIP_TAILS_SINGLE_BATCH_LOOSE_FOREIGN_AND_LEGACY_OK\n";
    } catch(const std::exception& error) { std::cerr<<error.what()<<'\n';return 1; }
}
