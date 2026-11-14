#include "../../Core/Project/RegionArrangement.hpp"
#include "../../Core/Songs/ItemDuration.hpp"
#include <iostream>
#include <stdexcept>
using namespace jaras;
static void check(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static void near(double actual,double expected,const char* message){check(std::abs(actual-expected)<1e-8,message);}
int main(){try {
    Song song;song.id="song";song.bpm=120;song.duration=700;
    song.timeSettings=ProjectTimeSettings{};song.timeSettings->timebase=ProjectTimebase::relative;
    song.timeSettings->affectsAutomationLength=false;
    Track track;track.id="track";track.name="Audio";track.role.id="other";
    for(int i=0;i<6;++i) {
        const auto id="r"+std::to_string(i);
        song.parts.push_back({id,id,double(i*100),double(i*100+80)});
        AudioClip clip;clip.id="item"+std::to_string(i);clip.name=clip.id;
        clip.startTime=i*100+10;clip.duration=40;clip.playbackRate=.75;clip.sourceOffset=2;clip.regionOwnerID=id;
        track.clips.push_back(clip);
    }
    Part child{"child","Child",405,475};child.parentRegionID="r4";song.parts.push_back(child);
    AudioClip crossing=track.clips[2];crossing.id="crossing";crossing.startTime=270;crossing.duration=100;
    track.clips.push_back(crossing);
    track.automationJSON=R"({"envelopes":[{"custom":"preserve","points":[{"id":"a","time":15,"value":0.2},{"id":"b","time":315,"value":0.7},{"id":"c","time":515,"value":0.9}]}]})";
    song.tracks={track};
    TimelineMarker tempo{"tempo","Tempo",310,0};tempo.tempoBPM=140;tempo.tempoTimebase="relative";
    TimelineMarker family{"family","Child",405,0};family.unifiedRegionID="r4";family.sourceRegionID="child";
    song.markers=std::vector<TimelineMarker>{tempo,{"gap","Gap",290,0},family};
    const auto original=song;
    RegionSpacingPlan(original,{"r0","r2","r3","r4","child"}).apply(song);
    const double starts[]={0,130,230,360,490,590,495};
    for(size_t i=0;i<song.parts.size();++i)near(song.parts[i].startTime,starts[i],"Incorrect cumulative region displacement");
    const double items[]={10,140,240,370,500,600,330};
    for(size_t i=0;i<song.tracks[0].clips.size();++i) {
        const auto& clip=song.tracks[0].clips[i];near(clip.startTime,items[i],"Item moved twice or followed the wrong owner");
        near(clip.duration,original.tracks[0].clips[i].duration,"Spacing stretched an item");
        near(clip.sourceOffset,2,"Spacing trimmed the source");near(clip.playbackRate,.75,"Spacing changed playback rate");
    }
    near((*song.markers)[0].position,370,"Tempo marker did not follow");
    near((*song.markers)[1].position,350,"Marker in inserted interval did not follow");
    near((*song.markers)[2].position,495,"Unified family marker did not follow");
    check(song.timeSettings->timebase==ProjectTimebase::relative && *(*song.markers)[0].tempoBPM==140,"Spacing changed timebase or BPM");
    auto automation=nlohmann::json::parse(*song.tracks[0].automationJSON);
    near(automation["envelopes"][0]["points"][1]["time"],375,"Track automation did not follow");
    check(automation["envelopes"][0]["custom"]=="preserve","Unknown automation fields were discarded");
    check(!ordinaryRegion(original,original.parts[4]) && !ordinaryRegion(original,original.parts[6]),"Unified families must not offer arrangement commands");
    near(*regionEndAtLongestItem(original,"r0"),50,"Region end must follow the actual farthest item");
    check(!regionEndAtLongestItem(original,"r4"),"Unified regions cannot have their end fitted independently");
    Song timing;timing.bpm=120;timing.timeSettings=ProjectTimeSettings{};timing.timeSettings->timebase=ProjectTimebase::relative;
    TimelineMarker faster{"faster","Tempo",5,0};faster.tempoBPM=240;faster.tempoTimebase="relative";faster.tempoReferenceBPM=120;timing.markers=std::vector<TimelineMarker>{faster};
    AudioClip clip;clip.startTime=3;clip.duration=1;clip.sourceOffset=8;clip.loopLength=4;
    auto restored=restoringItemDuration(timing,clip,10);
    near(restored.duration,6,"Full source duration ignored tempo changes");near(restored.startTime,3,"Restoring duration moved the item");
    near(restored.sourceOffset,0,"Restoring duration did not reveal the source beginning");check(!restored.loopLength,"Restoring duration retained repeated source segments");
    clip.renderedTempo=true;near(restoringItemDuration(timing,clip,10).duration,10,"Printed source was stretched twice");
    std::cout<<"REGION_CUMULATIVE_SPACING_UNSELECTED_FAMILIES_FARTHEST_END_AUTOMATION_AND_ORIGINAL_SOURCE_DURATION_OK\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
