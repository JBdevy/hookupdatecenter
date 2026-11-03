#pragma once
#include "StemFolderImport.h"
#include "MediaImportTests.h"
namespace catlive::stemImportTests {
template<class Test> void registerTests(const File& directory,Test test) {
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
