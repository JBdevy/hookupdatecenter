#pragma once
#include "AudioExport.h"
#include "TrackTree.h"
#include "MediaCleanup.h"
namespace catlive::projectReduction {
struct Group { ID id=uuid(); String name; std::set<ID> sources; };
struct Span { double start=0,end=0; };
struct Progress { double fraction=0; String message; };
inline bool audioItem(const jaras::AudioClip &clip,const jaras::Track &track) {
    const auto file=clip.audioFile?clip.audioFile:track.audioFile;
    if(file&&File(text(file->path)).hasFileExtension("mp4;mov;m4v;avi;mkv;webm;mpg;mpeg;wmv;mts;m2ts"))return false;
    return !clip.timecode&&!clip.text&&!(clip.audioFile&&text(clip.audioFile->path).startsWith("Videos/"))&&(clip.midi||clip.audioFile||track.audioFile);
}
inline std::vector<Span> spans(const std::vector<jaras::Track> &tracks) {
    std::vector<Span> items,result;
    for(const auto &t:tracks)for(const auto &c:t.clips)if(audioItem(c,t)&&c.duration>0)items.push_back({c.startTime,c.startTime+c.duration});
    std::sort(items.begin(),items.end(),[](auto a,auto b){return a.start<b.start;});
    for(auto item:items)if(!result.empty()&&item.start<result.back().end-.000001)result.back().end=std::max(result.back().end,item.end);else result.push_back(item);
    return result;
}
inline std::vector<Span> spans(const std::vector<jaras::Track> &tracks,const jaras::Song &song) {
    const auto audio=spans(tracks);if(audio.empty())return {};
    std::set<ID> parents;for(const auto &r:song.parts)if(r.parentRegionID)parents.insert(*r.parentRegionID);
    std::vector<Span> regions;std::set<double> bounds{audio.front().start,audio.back().end};
    for(const auto &r:song.parts)if(!parents.count(r.id)&&r.endTime>r.startTime){regions.push_back({r.startTime,r.endTime});bounds.insert(r.startTime);bounds.insert(r.endTime);}
    if(regions.empty())return audio;
    std::vector<Span> result;for(auto it=bounds.begin();std::next(it)!=bounds.end();++it){const double start=*it,end=*std::next(it);
        bool covered=std::any_of(audio.begin(),audio.end(),[&](auto a){return a.start<end&&a.end>start;});if(!covered)continue;
        if(std::any_of(regions.begin(),regions.end(),[&](auto r){return r.start<end&&r.end>start;}))result.push_back({start,end});
        else for(auto a:audio)if(a.start<end&&a.end>start)result.push_back({std::max(start,a.start),std::min(end,a.end)});
    }return result;
}
inline std::vector<Span> sampleAligned(const std::vector<Span> &spans,double sampleRate=48000){
    std::vector<Span> result;for(auto span:spans){const auto start=std::round(span.start*sampleRate),end=std::round(span.end*sampleRate);if(std::isfinite(start)&&std::isfinite(end)&&end>start)result.push_back({start/sampleRate,end/sampleRate});}return result;
}
inline void retain(jaras::Project &project,const std::set<ID> &ids){
    for(auto &song:project.songs){
        song.tracks.erase(std::remove_if(song.tracks.begin(),song.tracks.end(),[&](const auto &t){return !ids.count(t.id);}),song.tracks.end());
        for(auto &t:song.tracks){t.parentTrackID.reset();trackTree::resetGroupOutput(t);if(t.stereoLinkPartner&&!ids.count(*t.stereoLinkPartner)){t.stereoLinkPartner.reset();t.stereoLinkJSON.reset();t.stereoLinkLeft=false;}if(t.routing){for(auto &id:t.routing->receives)if(id&&!ids.count(*id))id.reset();for(auto &id:t.routing->transmitters)if(id&&!ids.count(*id))id.reset();}}
    }
}
inline void write(const jaras::Project &original,const std::vector<Group> &groups,const File &media,const File &target,std::atomic<bool> &cancel,const std::function<void(const Progress &)> &progress) {
    auto report=[&](double fraction,const String &message){progress({fraction,message});};
    report(0,String::fromUTF8("Preparando redução…"));
    const auto folder=target.getParentDirectory();
    if(target.exists()||(folder.exists()&&(!folder.isDirectory()||folder.getNumberOfChildFiles(File::findFilesAndDirectories)>0)))throw std::runtime_error("Escolha uma pasta vazia, sem outro projeto .jl.");
    if(folder.createDirectory().failed())throw std::runtime_error("Não foi possível criar a pasta.");
    bool complete=false;struct Cleanup {File folder;bool &complete;~Cleanup(){if(!complete)folder.deleteRecursively();}}cleanup{folder,complete};
    auto result=original;result.id=uuid();result.projectSyncID=uuid();result.name=utf8(target.getFileNameWithoutExtension());
    std::set<std::string> names;for(const auto &path:mediaCleanup::references(original))names.insert(utf8(text(path).toLowerCase()));std::set<ID> used,retained;std::vector<std::vector<jaras::Track>> destinations(original.songs.size());
    if(groups.empty())throw std::runtime_error("Crie pelo menos uma pista.");
    for(size_t index=0;index<groups.size();++index){
        if(cancel)throw std::runtime_error("Redução cancelada.");
        const auto &group=groups[index];if(group.sources.empty()||group.name.trim().isEmpty())throw std::runtime_error("Escolha as pistas de origem e o nome.");
        for(const auto &id:group.sources)if(!used.insert(id).second)throw std::runtime_error("Uma pista de origem só pode pertencer a uma combinação.");
        size_t si=0;for(;si<original.songs.size();++si)if(std::any_of(original.songs[si].tracks.begin(),original.songs[si].tracks.end(),[&](const auto &t){return group.sources.count(t.id);}))break;
        if(si==original.songs.size())throw std::runtime_error("Pista de origem não encontrada.");
        const auto &sourceSong=original.songs[si];std::vector<jaras::Track> sources;
        for(const auto &t:sourceSong.tracks)if(group.sources.count(t.id))sources.push_back(t);
        if(sources.size()!=group.sources.size())throw std::runtime_error("Escolha pistas do mesmo arranjo.");
        const auto trackLabel="Pista "+String((int)index+1)+"/"+String((int)groups.size())+": "+group.name;
        report(.9*index/groups.size(),"Preparando "+trackLabel);
        const auto ranges=sampleAligned(spans(sources,sourceSong));
        if(sources.size()==1&&(!sources[0].parentTrackID||ranges.empty())){auto copy=sources[0];copy.name=jaras::fixedTrackName(copy.role).empty()?utf8(group.name):jaras::fixedTrackName(copy.role);destinations[si].push_back(copy);retained.insert(copy.id);report(.9*double(index+1)/groups.size(),"Mantendo "+trackLabel);continue;}
        if(ranges.empty())throw std::runtime_error("A combinação não contém áudio ou MIDI para renderizar.");
        auto needed=group.sources;
        for(const auto &source:sources){auto cursor=source.parentTrackID;while(cursor&&needed.insert(*cursor).second){auto it=std::find_if(sourceSong.tracks.begin(),sourceSong.tracks.end(),[&](const auto &t){return t.id==*cursor;});if(it==sourceSong.tracks.end())break;cursor=it->parentTrackID;}}
        auto song=sourceSong;song.tracks.clear();
        for(auto track:sourceSong.tracks)if(needed.count(track.id)){
            const auto before=track;track.mute=trackTree::silenced(sourceSong,before);track.solo=false;
            track.clips.erase(std::remove_if(track.clips.begin(),track.clips.end(),[&](const auto &c){return !group.sources.count(track.id)||!audioItem(c,before);}),track.clips.end());
            if(!group.sources.count(track.id))track.audioFile.reset();
            track.outputs=std::vector<jaras::OutputPatch>{{track.parentTrackID?-2:0,2}};track.patch.reset();track.secondaryPatch.reset();track.routing.reset();track.stereoLinkPartner.reset();track.stereoLinkJSON.reset();track.stereoLinkLeft=false;song.tracks.push_back(track);
        }
        auto renderProject=original;renderProject.masterFXJSON.reset();renderProject.masterAutomationJSON.reset();renderProject.masterVolume=1;renderProject.masterPan=0;renderProject.masterMute=false;renderProject.masterSolo=false;renderProject.masterMono=false;renderProject.masterPhaseInverted=false;
        ExportRequest request;request.directory=folder.getChildFile("Stems");request.encodings[0].bits=32;request.encodings[0].floatingPoint=true;
        for(size_t n=0;n<ranges.size();++n){int suffix=int(n)+1;String name;do{name=File::createLegalFileName(group.name).substring(0,80)+" - "+String(suffix++)+".wav";}while(!names.insert(utf8(("Stems/"+name).toLowerCase())).second);ExportJob job;job.name=name;job.start=ranges[n].start;job.end=ranges[n].end;request.jobs.push_back(job);}
        audioExport::render(renderProject,song,media,request,cancel,[&](double value){
            const auto n=std::min(request.jobs.size()-1,(size_t)(std::clamp(value,0.0,1.0)*request.jobs.size()));
            const auto &job=request.jobs[n];const jaras::Part *region=nullptr;
            for(const auto &part:sourceSong.parts)if(part.startTime<job.end&&part.endTime>job.start&&(!region||part.endTime-part.startTime<region->endTime-region->startTime))region=&part;
            report(.9*(index+value)/groups.size(),"Renderizando "+trackLabel+String::fromUTF8("\nMúsica/região ")+String((int)n+1)+"/"+String((int)request.jobs.size())+": "+(region?text(region->name):String::fromUTF8("Fora de região"))+" - "+job.name);
        });
        jaras::Track output;output.id=group.id;output.name=utf8(group.name);output.role.id="other";output.color=sources[0].color;
        for(const auto &job:request.jobs){jaras::AudioClip clip;clip.id=uuid();clip.name=utf8(group.name);clip.startTime=job.start;clip.duration=job.end-job.start;clip.audioFile=jaras::AudioFile{utf8("Stems/"+job.name)};clip.renderedTiming=true;output.clips.push_back(clip);}
        for(const auto &source:sources)for(auto clip:source.clips)if(!audioItem(clip,source)){if(!clip.audioFile)clip.audioFile=source.audioFile;output.clips.push_back(clip);}
        destinations[si].push_back(output);retained.insert(output.id);
    }
    for(size_t si=0;si<result.songs.size();++si)result.songs[si].tracks=std::move(destinations[si]);
    retain(result,retained);jaras::validate(result);
    const auto paths=mediaCleanup::references(result);size_t fileIndex=0;
    for(const auto &path:paths){
        report(.9+.09*double(fileIndex)/std::max(size_t(1),paths.size()),String::fromUTF8("Copiando mídia ")+String((int)fileIndex+1)+"/"+String((int)paths.size())+": "+File(text(path)).getFileName());
        ++fileIndex;
        if(cancel)throw std::runtime_error("Redução cancelada.");
        const auto destination=folder.getChildFile(text(path));if(!destination.isAChildOf(folder))throw std::runtime_error("Invalid project media path.");if(destination.exists())continue;
        const auto source=ProjectCodec::resolveMedia(media,path);if(!source.existsAsFile())continue;
        if(destination.getParentDirectory().createDirectory().failed()||!source.copyFileTo(destination))throw std::runtime_error("Falha ao copiar uma mídia do projeto.");
    }
    report(.99,String::fromUTF8("Salvando projeto reduzido…"));
    jaras::validate(result);ProjectCodec::write(target,ProjectCodec::encode(result));complete=true;report(1,"Projeto reduzido salvo.");
}
}
