#include "../../Core/Project/Models.hpp"
#include "../../Core/Tracks/ItemResize.hpp"
#include "../../Core/Songs/ItemDuration.hpp"
#include "../../Windows/Source/MixerSlotLayout.h"
#include "../../Core/Timecode/TimecodePlayback.hpp"
#include <iostream>
using namespace jaras;
static void check(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static void near(double value,double expected,const char* message){check(std::abs(value-expected)<1e-8,message);}
int main(){try {
    AudioClip original;original.id="item";original.startTime=0;original.duration=3;original.sourceOffset=2;
    original.audioFile=AudioFile{"Stems/source.wav",{}};
    auto inside=resizedItemSource(original,0,7,10);
    near(*inside.loopLength,10,"Resizing must use the real file period instead of the trimmed length");
    near(inside.sourceOffset,2,"Resizing changed the source trim");
    const auto extended=resizedItemSource(original,0,23,10);
    near(*extended.loopLength,10,"The full source must repeat beyond EOF");
    near(extended.duration,23,"The extended bounds were not retained");
    near(*resizedItemSource(extended,0,30,80).loopLength,10,"Imported/repeated source sections must keep their own period");
    check(!resizedItemSource(original,0,23).loopLength,"Missing metadata cannot invent a period from a short item");
    auto video=original;video.audioFile=AudioFile{"Videos/source.mp4",{}};
    near(*resizedItemSource(video,0,23,10).loopLength,10,"Video extension must share source-period rules");
    ItemRateSettings settings(120);settings.stepRate(-1);near(settings.rate,.99,"Rate decrement is not .01");
    near(settings.bpmOffset(),-1.2,"Rate and signed BPM offset disagree");
    settings.reset();settings.stepRate(1);near(settings.rate,1.01,"Rate increment is not .01");
    settings.reset();settings.stepBPM(-1);near(settings.bpmOffset(),-1,"BPM decrement is not one BPM");
    settings.setBPMOffset(24);near(settings.rate,1.2,"Positive BPM offset maps to the wrong rate");
    settings.setBPMOffset(-12);near(settings.rate,.9,"Negative BPM offset maps to the wrong rate");
    settings.reset();near(settings.rate,1,"Reset must set rate to 1.00");near(settings.bpmOffset(),0,"Reset must clear BPM offset");
    settings.setBPMOffset(-120);check(!settings.valid(),"A zero playback speed must not be accepted");
    const double precise=1.1234567890123456;ItemRateSettings imported(146,precise);
    near(std::stod(imported.rateText()),precise,"Displayed rate must retain imported precision");
    check(std::stod(imported.rateText())==precise,"Rate text must round-trip the exact imported double");
    imported.stepRate(1);near(imported.rate,precise+.01,"Rate step cannot quantize the imported fraction");
    imported.stepRate(-1);check(imported.rate==precise,"Forward/backward steps must restore the imported double");
    imported.reset();check(imported.rateText()=="1.000000","Rate control must show at least six decimals like REAPER");
    for(int i=0;i<20;++i)imported.stepRate(1);
    check(imported.rateText()=="1.200000","Repeated steps must not accumulate visible binary rounding noise");
    Song song;song.bpm=120;song.duration=30;song.timeSettings=ProjectTimeSettings{};song.timeSettings->timebase=ProjectTimebase::relative;
    TimelineMarker tempo{"tempo","Faster",5,0};tempo.tempoBPM=240;tempo.tempoTimebase="relative";tempo.tempoReferenceBPM=120;
    song.markers=std::vector<TimelineMarker>{tempo};
    auto clip=original;clip.duration=10;clip.sourceOffset=3;clip.loopStart=0;clip.loopLength=8;
    near(sourceSpanForItem(song,clip),15,"Incorrect source consumption across tempo markers");
    const auto faster=itemWithRate(song,clip,2);
    near(faster.duration,6.25,"Rate change must preserve full source content across tempo markers");
    near(sourceSpanForItem(song,faster),15,"Changing rate lost source content");
    near(faster.sourceOffset,3,"Changing rate changed source trim");near(*faster.loopLength,8,"Changing rate changed the source period");
    near(itemWithRate(song,clip,.5).duration,17.5,"Slowing an item must extend its duration");
    near(itemWithRate(song,faster,1).duration,10,"Resetting rate must restore the source span");
    auto movie=clip;movie.audioFile=AudioFile{"Videos/source.mp4",{}};
    near(itemWithRate(song,movie,2).duration,5,"Video playback must preserve its constant-rate source span");
    near(restoringItemDuration(song,movie,20).duration,20,"Video source duration cannot apply audio tempo markers");
    auto midi=clip;midi.audioFile.reset();midi.midi=MIDIItem{};
    near(itemWithRate(song,midi,2).duration,6.25,"MIDI rate must preserve its source notes and span");
    Track clickTrack;clickTrack.role.id="generatedClick";
    auto click=clip;click.audioFile.reset();click.sourceOffset=0;click.loopLength.reset();
    song.markers->front().tempoTimebase="free";
    near(itemWithRate(song,click,2,&clickTrack).duration,6.25,"Generated click must preserve beat count across Free Grid tempo changes");
    for(const auto* role:{"standard","timecode","generatedClick"}) {
        Song before;before.bpm=120;before.duration=20;before.timeSettings=ProjectTimeSettings{};before.timeSettings->timebase=ProjectTimebase::relative;
        before.parts={{"region","Song",2,18}};
        Track track;track.role.id=role;track.id=std::string(role)+"-track";
        AudioClip item;item.id=std::string(role)=="timecode"?"region-timecode":"item";item.startTime=4;item.duration=12;item.regionOwnerID="region";
        if(std::string(role)=="standard")item.midi=MIDIItem{};
        if(std::string(role)=="timecode"){item.timecodeStartOffset=2;item.timecodeEndOffset=-2;}
        track.clips={item};before.tracks={track};auto after=before;
        auto marker=tempo;marker.position=2;marker.regionOwnerID="region";after.markers=std::vector<TimelineMarker>{marker};
        TempoEditMap(before,after).apply(after);
        near(after.tracks[0].clips[0].startTime,3,"Special/MIDI item onset failed to follow owned tempo");
        near(after.tracks[0].clips[0].duration,6,"Special/MIDI item duration failed to follow owned tempo");
        check(itemSupportsRate(track,item),"Special/MIDI item missing Config rate eligibility");
        if(std::string(role)=="timecode") {
            near(*after.tracks[0].clips[0].timecodeStartOffset,1,"Timecode start trim was lost during BPM edit");
            near(*after.tracks[0].clips[0].timecodeEndOffset,-1,"Timecode end trim was lost during BPM edit");
            Project synchronized;synchronized.songs={after};synchronizeTimecode(synchronized);
            near(synchronized.songs[0].tracks[0].clips[0].startTime,3,"Synchronizing timecode erased the mapped onset");
            near(synchronized.songs[0].tracks[0].clips[0].duration,6,"Synchronizing timecode erased the mapped duration");
            const TimecodeProgram program(after,after.tracks[0]);
            near(program.at(4)->speed,2,"Timecode generator must follow actual BPM speed");
            near(program.at(4)->time(4),4,"Timecode address failed to advance with the stretched source clock");
        }
    }
    song.markers->front().tempoTimebase="relative";
    Track tc;tc.role.id="timecode";auto tcItem=clip;tcItem.audioFile.reset();tcItem.sourceOffset=0;tcItem.startTime=2;tcItem.duration=10;tcItem.playbackRate=1.25;
    tcItem.timecode=TimecodeSettings{};tcItem.timecode->regionRelative=false;tc.clips={tcItem};
    const TimecodeProgram tcProgram(song,tc);
    near(tcProgram.at(4)->time(4),5,"Timecode locate must include manual rate before a marker");
    near(tcProgram.at(5)->time(5),6.25,"Timecode address must remain continuous at a tempo boundary");
    near(tcProgram.at(6)->time(6),8.75,"Timecode clock must accelerate after the tempo marker");
    for(int count:{0,1,2,8})for(int height=0;height<=500;++height) {
        const catlive::MixerSlotSections sections(height,count);
        check(sections.plugins+sections.outputs+sections.divider==height,"Slot sections lost vertical space");
        check(sections.outputs==0 || sections.plugins>=63,"Output slots must stay below three FX rows");
    }
    const catlive::MixerSlotSections tall(500,8);
    check(tall.plugins>63 && tall.outputs==40,"Plugins must grow beyond three slots and outputs must have an independent scroll viewport");
    std::cout<<"SOURCE_EOF_AUDIO_VIDEO_REPETITION_RATE_BPM_STEPS_SOURCE_SPAN_AND_MIXER_OUTPUT_SECTIONS_OK\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
