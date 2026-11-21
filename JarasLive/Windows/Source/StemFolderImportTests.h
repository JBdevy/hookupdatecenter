#pragma once
#include "StemFolderImport.h"
#include "MediaImportTests.h"
namespace catlive::stemImportTests {
template<class Test> void registerTests(const File& directory,Test test) {
 test("Stem append prefers custom destination names over taxonomy and keeps numbered destinations separate",[&]{
    using mediaImportTests::require;
    auto root=directory.getNonexistentChildFile("custom-stem-names","");root.createDirectory();
    auto folder=root.getChildFile("Song");
    for(auto name:{"Baixo Moog.wav","Baixo Analogico.wav","Tuba Hits.wav","Click.wav","Click 2.wav","Click alternate.wav"})mediaImportTests::source(folder,name,4800);
    auto base=Session::makeEmptyProject("Custom");
    for(auto name:{"Baixo","Baixo Moog","Baixo Analogico","Tuba Hits","Click","Click 2","Click 3"}){
        jaras::Track t;t.id=uuid();t.name=name;t.role.id="other";t.volume=.42;t.pan=-.25;base.songs[0].tracks.push_back(t);
    }
    StringArray warnings;auto scan=stemImport::scan({folder});
    auto appended=stemImport::build(*scan,"",base,root.getChildFile("Project/Show.jl"),false,{},warnings);
    require(appended.songs[0].tracks.size()==base.songs[0].tracks.size(),"Exact custom destination was replaced by taxonomy or Out");
    for(size_t i=0;i<base.songs[0].tracks.size();++i){const auto& old=base.songs[0].tracks[i];const auto& added=appended.songs[0].tracks[i];
        require(added.id==old.id&&added.name==old.name&&added.volume==old.volume&&added.pan==old.pan,"Destination identity or controls changed");
        require(added.clips.size()==(i==0?0:1),"Stem went to another same-family track or overlapped a numbered destination");
    }
    require(appended.songs[0].tracks[4].clips[0].name=="Click.wav"&&appended.songs[0].tracks[5].clips[0].name=="Click 2.wav"&&appended.songs[0].tracks[6].clips[0].name=="Click alternate.wav","Exact filenames must reserve their destination before taxonomy aliases");
 });

 test("Stem append reuses imported REAPER Click Guia and numbered tracks before creating any channel",[&]{
    using mediaImportTests::require;
    auto root=directory.getNonexistentChildFile("existing-stems","");root.createDirectory();
    auto folder=root.getChildFile("Song");
    for(auto name:{"Click.wav","Click alternate.wav","Guia.wav","Guitarra.wav","Guitarra 2.wav"})mediaImportTests::source(folder,name,4800);
    auto scan=stemImport::scan({folder});StringArray warnings;
    auto target=root.getChildFile("Project/Project.jl");
    auto base=stemImport::build(*scan,"",Session::makeEmptyProject("Project"),target,false,{},warnings);
    for(auto& track:base.songs[0].tracks){track.role.id="other";track.volume=.42;track.pan=-.25;}
    auto appended=stemImport::build(*scan,"",base,target,false,{},warnings);
    require(appended.songs[0].tracks.size()==base.songs[0].tracks.size(),"Existing REAPER tracks were duplicated");
    for(size_t i=0;i<base.songs[0].tracks.size();++i){const auto& old=base.songs[0].tracks[i];const auto& added=appended.songs[0].tracks[i];
        require(added.id==old.id&&added.parentTrackID==old.parentTrackID&&added.volume==old.volume&&added.pan==old.pan,"Append changed existing identity, routing or controls");
        require(added.clips.size()==old.clips.size()*2,"New stem was not added to its existing matching track");
    }
 });
 test("Stem append reuses first numbered aliases and preserves guitar wah",[&]{
    using mediaImportTests::require;
    auto root=directory.getNonexistentChildFile("first-numbered-stems","");
    auto folder=root.getChildFile("New Song");
    const StringArray fixtures{"Backing Vocals 1.wav","Baixo 1.wav","Metais 1.wav","Baixo 2.wav","GTR WAH 1 - Another Song.wav"};
    for(const auto &file:fixtures) mediaImportTests::source(folder,file,4800);
    auto base=Session::makeEmptyProject("Existing");
    for(const auto *name:{"Back Vocais","Bass","Metais","Bass 2","Guitarra Wah","Guitarra 1"}) {
        jaras::Track track;track.id=uuid();track.name=name;track.volume=.45;track.pan=-.2;
        base.songs[0].tracks.push_back(track);
    }
    StringArray warnings;
    const auto added=stemImport::build(*stemImport::scan({folder}),"",base,root.getChildFile("Project/Show.jl"),false,{},warnings);
    const auto &tracks=added.songs[0].tracks;
    require(tracks.size()==base.songs[0].tracks.size(),"Add Stems created duplicate tracks for first-channel aliases");
    for(size_t i=0;i<tracks.size();++i) {
        const auto &old=base.songs[0].tracks[i], &track=tracks[i];
        require(track.id==old.id&&track.name==old.name&&track.volume==old.volume&&track.pan==old.pan,
                "Add Stems changed the destination track");
        if(i < size_t(fixtures.size()))
            require(track.clips.size()==1&&text(track.clips.front().name)==fixtures[(int)i],"Stem reached the wrong existing track");
        else require(track.clips.empty(),"The plain guitar track captured a wah stem");
    }
 });
 test("Rendered stems restore transport tuner only on matching tracks",[&]{
    using mediaImportTests::require;
    auto root=directory.getNonexistentChildFile("stem-tuner-targets","");
    auto folder=root.getChildFile("Mix");
    mediaImportTests::source(folder,"Guitar.wav",48000);
    mediaImportTests::source(folder,"Bass.wav",48000);

    auto source=Session::makeEmptyProject("Source");
    auto& song=source.songs.front();
    jaras::Track guitar,bass;
    guitar.id=uuid();guitar.name="Guitar";guitar.role.id="other";
    bass.id=uuid();bass.name="Bass";bass.role.id="other";
    song.tracks={guitar,bass};
    jaras::Part region;
    region.id=uuid();region.name="Mix";region.endTime=1;region.pitchSemitones=3;
    region.pitchTrackIDs=std::vector<ID>{guitar.id};
    region.pitchGroupIDs=std::vector<ID>{};
    song.parts={region};
    jaras::TimelineMarker tempo,cue;
    tempo.id=uuid();tempo.name="Tempo";tempo.tempoBPM=140;
    cue.id=uuid();cue.name="Cue";cue.position=.5;
    song.markers=std::vector<jaras::TimelineMarker>{tempo,cue};

    const std::vector<multitrackData::RenderedStem> stems{
        {"Guitar.wav",guitar.id,{{0,1,1.1,-3}}},
        {"Bass.wav",bass.id,{{0,1,1,std::nullopt}}}
    };
    const auto encoded=multitrackData::encode(song,region,song.tracks,stems,{},true,false);
    const auto manifest=multitrackData::decode(encoded);
    require(!manifest.stems[0].items[0].pitchSemitones,"Item pitch was saved after rendering");
    require(manifest.arrangement().markers&&manifest.arrangement().markers->size()==1&&
            manifest.arrangement().markers->front().name=="Cue","Printed rate included tempo markers");
    multitrackData::write(folder.getChildFile(".jldata-Mix"),encoded);

    auto base=Session::makeEmptyProject("Destination");
    guitar.id=uuid();guitar.name="Guitarra";bass.id=uuid();
    base.songs.front().tracks={guitar,bass};
    StringArray warnings;
    const auto added=stemImport::build(*stemImport::scan({folder}),"",base,root.getChildFile("Project/Show.jl"),false,{},warnings);
    const auto& imported=added.songs.front();
    require(imported.tracks.size()==2&&imported.tracks.front().id==guitar.id&&imported.tracks.back().id==bass.id,
            "Rendered stems did not reuse the matching tracks");
    const auto& restored=imported.parts.front();
    require(restored.pitchSemitones==3&&regionPitch::selected(imported,imported.tracks[0],restored)&&
            !regionPitch::selected(imported,imported.tracks[1],restored),"Transport tuner was applied to the wrong tracks");
    const auto& clips=imported.tracks.front().clips;
    require(clips.size()==1&&!clips.front().pitchSemitones,"Item pitch was applied again");
    require(imported.markers&&imported.markers->size()==1&&imported.markers->front().name=="Cue",
            "Add Stems restored tempo markers for a printed rate");
 });
 test("Stem import preserves scalar rule results before matching existing tracks",[&]{
    using mediaImportTests::require;stemImport::Rules rules;
    for(const auto& entry:std::vector<std::pair<String,String>>{{"CLICK","click"},{"Click 2","click 2"},{"Guia","guia"},{"Guitarra 2","guitarra 2"}})
        require(rules.call("canonicalExistingTrackKey",{entry.first}).toString()==entry.second,"Existing track key was lost or collapsed");
    require(rules.call("groupKeyFromFolderName",{"Interno"}).toString()=="interno","Existing group key was lost");
 });
 test("Stem folders use shared Mac classification, ordered songs, copied media and append routing",[&]{
    using mediaImportTests::require;auto root=directory.getNonexistentChildFile("stem-folders","");root.createDirectory();
    auto first=root.getChildFile("Song 01"),second=root.getChildFile("Song 02"),empty=root.getChildFile("Empty");empty.createDirectory();
    mediaImportTests::source(first,"Click.wav",48000);mediaImportTests::source(first,"Piano.wav",96000);
    mediaImportTests::source(second,"Piano.wav",48000);mediaImportTests::source(second,"Baixo.wav",48000);
    auto scan=stemImport::scan({first,second,first,empty});require(scan->folders.size()==2&&!scan->warnings.isEmpty(),"Folder deduplication/empty-folder review failed");
    require(scan->folders[0].files[0].duration==0,"Folder ordering opened audio decoders before import confirmation");
    auto target=root.getChildFile("Project/Project.jl");StringArray warnings;std::vector<double> progress;
    auto p=stemImport::build(*scan,"",Session::makeEmptyProject("Project"),target,false,[&](String,double value){progress.push_back(value);},warnings);
    require(p.songs[0].parts.size()==2&&p.songs[0].parts[0].startTime==30&&p.songs[0].parts[1].startTime==62,"Song order/gaps differ from Mac");
    int clips=0;ID piano;for(const auto& track:p.songs[0].tracks){if(track.name=="Piano"){piano=track.id;require(track.clips.size()==2,"Matching channels were not reused across songs");}
      for(const auto& clip:track.clips){++clips;require(clip.audioFile&&target.getParentDirectory().getChildFile(text(clip.audioFile->path)).existsAsFile(),"Imported audio was not copied");require(!clip.waveform.empty()&&clip.waveformChannels.size()==2,"Imported waveform missing");}
      if(track.parentTrackID)require(track.patch&&track.patch->firstChannel == -2,"Imported group routing differs from Mac");
    }
    require(clips==4&&!piano.empty()&&progress.size()==4&&progress.back()==1,"Import omitted media or progress");
    auto floatingFolder=root.getChildFile("Floating");mediaImportTests::floatingSource(floatingFolder);
    auto floatingScan=stemImport::scan({floatingFolder});
    auto floatingProject=stemImport::build(*floatingScan,"",Session::makeEmptyProject("Floating"),root.getChildFile("FloatProject/FloatProject.jl"),false,{},warnings);
    bool foundFloating=false;for(const auto& track:floatingProject.songs[0].tracks)for(const auto& clip:track.clips){foundFloating=true;for(const auto& channel:clip.waveformChannels)for(auto peak:channel)require(std::isfinite(peak)&&peak>=0&&peak<=1,"Floating audio produced invalid channel waveform");}
    require(foundFloating,"Floating audio was omitted");
    auto before=p.songs[0].tracks;auto appendScan=stemImport::scan({second});auto appended=stemImport::build(*appendScan,"",p,target,false,{},warnings);
    require(appended.songs[0].tracks.size()==before.size(),"Append created duplicate tracks despite matching existing names");
    auto existingPiano=std::find_if(appended.songs[0].tracks.begin(),appended.songs[0].tracks.end(),[&](const auto&t){return t.id==piano;});
    require(existingPiano!=appended.songs[0].tracks.end()&&existingPiano->clips.size()==3,"Append did not place the new stem on the existing Piano");
    require(appended.songs[0].parts.size()==3&&appended.songs[0].parts.back().startTime==93,"Append did not follow existing timeline");
    for(const auto& old:before){auto it=std::find_if(appended.songs[0].tracks.begin(),appended.songs[0].tracks.end(),[&](const auto&t){return t.id==old.id;});require(it!=appended.songs[0].tracks.end()&&it->parentTrackID==old.parentTrackID,"Append replaced an existing track or group");}
    ProjectCodec::write(target,ProjectCodec::encode(appended));require(ProjectCodec::decode(ProjectCodec::read(target)).songs[0].parts.size()==3,"Imported project did not round-trip");
 });
}
}
