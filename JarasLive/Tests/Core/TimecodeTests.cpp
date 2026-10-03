#include "../../Core/Timecode/Timecode.hpp"
#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <iostream>
using namespace jaras;
int main() {
    for (double fps : {24.,25.,29.97,30.}) for(double time : {0.,1.25,59.98,60.06,600.,3601.25,86401.}) {
        const auto fields=nativeMtcTimeFields(time,fps,fps==29.97);
        const auto bits=ltcFrame(time,fps);
        auto value=[&](int at,int count) { int result=0; for(int n=0;n<count;++n) result|=int(bits[at+n])<<n; return result; };
        assert(value(64,16)==0xbffc);
        assert(value(0,4)+10*value(8,2)==fields.frame);
        assert(value(16,4)+10*value(24,3)==fields.second);
        assert(value(32,4)+10*value(40,3)==fields.minute);
        assert(value(48,4)+10*value(56,2)==fields.hour);
        assert(bits[10]==(fps==29.97));
        int parity=0; for(bool bit:bits) parity+=bit; assert(parity%2==0);
        assert((nativeMtcQuarterFrameData(fields,7)&6)==fields.rateCode*2);
    }
    assert(nativeMtcTimeFields(60.06,29.97,true).frame==2);
    Project project; project.id="project"; project.name="Timecode";
    Song song; song.id="song"; song.name="Song"; song.duration=180; song.bpm=120;
    song.parts={{"region-a","First",30,50},{"region-b","Second",80,100}};
    project.songs.push_back(song);
    Engine engine; engine.loadProject(project);
    engine.addTrack("tc","Ignored",{"timecode"});
    auto tc=engine.project().songs[0].tracks[0];
    assert(!tc.color.has_value());
    assert(tc.name=="Timecode" && tc.clips.size()==2);
    assert(tc.clips[0].startTime==30 && tc.clips[0].duration==20);
    bool rejected=false; try { engine.addTrack("tc2","Timecode",{"timecode"}); } catch(...) { rejected=true; } assert(rejected);
    rejected=false; try { engine.moveClip(tc.clips[0].id,0); } catch(...) { rejected=true; } assert(rejected);
    engine.moveRegion("region-a",40);
    assert(engine.project().songs[0].tracks[0].clips[0].startTime==40);
    engine.resizeRegion("region-b",75,110);
    assert(engine.project().songs[0].tracks[0].clips[1].duration==35);
    TimecodeSettings settings; settings.mode="ltc"; settings.frameRate=25;
    engine.setTimecode("tc",settings);
    assert(engine.project().songs[0].tracks[0].clips[0].name=="TIMECODE");
    engine.editTrack("tc","Cannot rename",0x123456);
    assert(engine.project().songs[0].tracks[0].name=="Timecode");
    assert(engine.project().songs[0].tracks[0].color==0x123456);
    engine.addTrack("video","Cannot rename",{"video"});
    engine.addTrack("tp","Cannot rename",{"teleprompt"});
    assert(engine.project().songs[0].tracks[1].name=="Teleprompter 1");
    assert(engine.project().songs[0].tracks[2].name=="Video");
    engine.addTrack("audio","Audio",{"other"});
    assert(engine.project().songs[0].tracks.back().color==0x828282);
    AudioClip recorded; recorded.id="new-item"; recorded.name="Third"; recorded.startTime=130; recorded.duration=20;
    engine.addRecordedClip("audio",recorded);
    engine.regionFromClip("new-item","region-c");
    const auto& third=engine.project().songs[0].tracks[0].clips[2];
    assert(third.name=="TIMECODE" && third.startTime==130 && third.duration==20);
    engine.execute({CommandKind::mute,"tc"});
    assert(engine.project().songs[0].tracks[0].mute);
    rejected=false; try { engine.execute({CommandKind::solo,"tc"}); } catch(...) { rejected=true; } assert(rejected);
    rejected=false; try { engine.groupTracks({"tc","video"}); } catch(...) { rejected=true; } assert(rejected);
    // Settings change in place, retaining an unrelated large audio overview
    // and both running transport heads instead of copying/reloading the show.
    Project large; large.id="large-project"; large.name="Large";
    Song arrangement; arrangement.id="large-song"; arrangement.name="Arrangement";
    arrangement.duration=120; arrangement.parts={{"large-region","Song",30,100}};
    Track source; source.id="source-track"; source.name="Audio";
    AudioClip media; media.id="source-item"; media.name="Stem";
    media.startTime=30; media.duration=70; media.waveform.assign(200000,0.4);
    media.waveformChannels={std::vector<double>(200000,0.2),std::vector<double>(200000,0.6)};
    source.clips.push_back(std::move(media)); arrangement.tracks.push_back(std::move(source));
    large.songs.push_back(std::move(arrangement)); Engine live; live.loadProject(std::move(large));
    live.addTrack("live-tc","Timecode",{"timecode"});
    live.execute({CommandKind::editSeek,"",31}); live.execute({CommandKind::play});
    live.execute({CommandKind::subSeek,"",60}); live.execute({CommandKind::subPlay});
    const auto transport=live.transport();
    const auto* overview=live.project().songs[0].tracks[1].clips[0].waveform.data();
    const auto* channel=live.project().songs[0].tracks[1].clips[0].waveformChannels[1].data();
    for (int n=0;n<20;++n) {
        settings.mode=n%2 ? "mtc" : "ltc"; live.setTimecode("live-tc",settings);
        assert(live.project().songs[0].tracks[1].clips[0].waveform.data()==overview);
        assert(live.project().songs[0].tracks[1].clips[0].waveformChannels[1].data()==channel);
        assert(live.transport().position==transport.position && live.transport().playing==transport.playing);
        assert(live.transport().subPlay.position==transport.subPlay.position && live.transport().subPlay.playing==transport.subPlay.playing);
        assert(live.project().songs[0].tracks[0].clips[0].startTime==30);
        assert(live.project().songs[0].tracks[0].clips[0].duration==70);
    }
    const auto oldMode=live.project().songs[0].tracks[0].timecode->mode;
    settings.frameRate=99; rejected=false;
    try { live.setTimecode("live-tc",settings); } catch(...) { rejected=true; }
    assert(rejected && live.project().songs[0].tracks[0].timecode->mode==oldMode);
    assert(live.project().songs[0].tracks[1].clips[0].waveform.data()==overview);
    // Imported generator items have independent edges/settings, never replaced
    // by the normal automatic region-bound Timecode items when the core opens.
    Project imported = project;
    Track importedTrack; importedTrack.id="imported-tc"; importedTrack.name="Timecode"; importedTrack.role={"timecode"};
    importedTrack.importedTimecodeItems=true;
    AudioClip generated; generated.id="imported-generator"; generated.name="MTC";
    generated.startTime=12; generated.duration=9; generated.timecode=TimecodeSettings{};
    generated.timecode->mode="mtc"; generated.timecode->offset=3602; generated.timecode->frameRate=25;
    importedTrack.timecode=generated.timecode; importedTrack.clips={generated};
    imported.songs[0].tracks={importedTrack};
    Engine migrated; migrated.loadProject(imported);
    assert(migrated.project().songs[0].tracks[0].clips.size()==1);
    const auto& preserved=migrated.project().songs[0].tracks[0].clips[0];
    assert(preserved.id==generated.id && preserved.startTime==12 && preserved.duration==9);
    assert(preserved.timecode->offset==3602 && preserved.timecode->frameRate==25);
    auto routed=*importedTrack.timecode; routed.midiDestination=123;
    migrated.setTimecode(importedTrack.id,routed);
    assert(migrated.project().songs[0].tracks[0].clips[0].timecode->offset==3602);
    assert(migrated.project().songs[0].tracks[0].clips[0].timecode->midiDestination==123);
    imported.songs[0].tracks[0].clips.clear(); migrated.loadProject(imported);
    assert(migrated.project().songs[0].tracks[0].clips.empty());
    std::cout<<"TIMECODE_MTC_LTC_FIELDS_UNIQUE_TRACK_REGION_BINDING_INCREMENTAL_SETTINGS_OK\n";
}
