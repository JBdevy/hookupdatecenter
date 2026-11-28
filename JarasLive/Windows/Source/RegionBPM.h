#pragma once
#include "ItemRender.h"
#include "ClickTempo.h"
#include "MIDIPlayback.h"
#include "MediaSource.h"
#include "ProjectionSelection.h"
#include "../../Core/Songs/RegionTempoAdjustment.hpp"
#include "../../Core/Audio/RegionTempoRender.hpp"

namespace catlive::regionBPM {
inline const jaras::Part& region(const jaras::Song& song,const ID& id) {
    auto it=std::find_if(song.parts.begin(),song.parts.end(),[&](const auto& part){return part.id==id;});
    if(it==song.parts.end())throw std::invalid_argument("Region not found.");
    return *it;
}
inline bool hasAudio(const jaras::Track& track,const jaras::AudioClip& clip) {
    const auto& file=clip.audioFile?clip.audioFile:track.audioFile;
    return file && !clip.text && (!clip.midi || clip.frozenMIDI.value_or(false)) &&
        !File(text(file->path)).hasFileExtension("png;jpg;jpeg;gif;webp;heic;heif;tif;tiff;bmp;avif");
}
inline std::vector<double> edges(const jaras::regionTempo::Plan& plan,const jaras::AudioClip& clip) {
    std::vector<double> result{clip.startTime};
    for(auto edge:plan.edges)if(edge>clip.startTime && edge<clip.startTime+clip.duration)result.push_back(edge);
    result.push_back(clip.startTime+clip.duration);
    return result;
}
inline jaras::AdjustedVideoSource visualSource(const jaras::AudioClip& clip,const jaras::regionTempo::Plan& plan,std::vector<double> breaks) {
    jaras::AdjustedVideoSource visual;
    if(clip.adjustedVideo){
        visual=*clip.adjustedVideo;visual.points.clear();
        for(const auto& point:clip.adjustedVideo->points)
            if(point.time>0 && point.time<clip.duration)breaks.push_back(clip.startTime+point.time);
    }else{visual.path=clip.audioFile->path;visual.loopStart=clip.loopStart;visual.loopLength=clip.loopLength;}
    std::sort(breaks.begin(),breaks.end());breaks.erase(std::unique(breaks.begin(),breaks.end()),breaks.end());
    for(double at:breaks){
        auto clock=projectionClock(clip,at);
        visual.points.push_back({plan.time.position(at)-plan.time.position(clip.startTime),clock.first});
    }
    return visual;
}

struct Rendered {
    std::vector<File> files;
    jaras::Song song;
    catlive::audio::PiecewiseTimeMap time;
    void discard() const {for(const auto& file:files)file.deleteFile();}
};
inline Rendered render(const jaras::Project& source,const jaras::Song& song,const ID& id,jaras::regionTempo::Plan plan,
                       const File& directory,std::atomic<bool>& cancel,const std::function<std::vector<double>(AudioFormatReader&)>& peaks,
                       const std::function<void(double,String)>& progress) {
    Rendered result;
    const auto stems=directory.getChildFile("Stems");
    if(stems.createDirectory().failed())throw std::runtime_error("Could not create Stems.");
    size_t total=0,completed=0,clickCount=0;
    const auto recordedClick=[](const jaras::Track& track) {
        return track.role.id=="click" || track.role.id=="generatedClick" || text(track.name).trim().equalsIgnoreCase("Click");
    };
    for(const auto& track:song.tracks)for(const auto& clip:track.clips)if(plan.overlaps(clip)&&hasAudio(track,clip)) {
        ++total;
        if(recordedClick(track))++clickCount;
    }
    total+=clickCount;
    auto printItem=[&](const jaras::Track& track,const jaras::AudioClip& original,const std::function<void(double)>& update) {
        auto isolated=song;
        auto one=track;one.role.id="other";one.clips={original};
        if(!one.clips[0].audioFile)one.clips[0].audioFile=track.audioFile;
        isolated.tracks={std::move(one)};
        return itemRender::render(source,isolated,directory,{original.id},false,0,cancel,update).at(0);
    };
    struct ClickPrints {
        std::map<ID,itemRender::Replacement> items;
        ~ClickPrints(){for (const auto& entry:items)entry.second.generated.deleteFile();}
    } clickPrints;
    std::vector<double> beats;
    for(const auto& track:song.tracks)if(recordedClick(track)) {
        for(const auto& clip:track.clips)if(plan.overlaps(clip)&&hasAudio(track,clip)) {
            if(cancel.load())throw std::runtime_error("Operation cancelled.");
            auto printed=printItem(track,clip,[&](double fraction){progress((completed+.85*fraction)/total,text(clip.name));});
            const auto file=printed.generated;
            clickPrints.items.emplace(clip.id,std::move(printed));
            for(const auto& pulse:clickTempo::primaryTransients(clickTempo::transients(file,&cancel,false)))
                beats.push_back(clip.startTime+pulse.position);
            progress(double(++completed)/total,text(clip.name));
        }
    }
    if(cancel.load())throw std::runtime_error("Operation cancelled.");
    plan.alignToClick(std::move(beats));
    auto crop=source;crop.songs={song};
    auto& mapped=crop.songs.front();
    plan.apply(crop,mapped,region(mapped,id),[]{return uuid();});
    AudioFormatManager formats;registerAudioFormats(formats);
    try {
        for(size_t row=0;row<song.tracks.size();++row){
            const auto& track=song.tracks[row];
            for(size_t index=0;index<track.clips.size();++index){
                if(cancel.load())throw std::runtime_error("Operation cancelled.");
                const auto& original=track.clips[index];auto& adjusted=mapped.tracks[row].clips[index];
                if(!plan.overlaps(original))continue;
                if(!hasAudio(track,original)){
                    if(original.midi){
                        auto& midi=*adjusted.midi;
                        const double beats=midi.sourceBPM/60.;
                        midi.notes.clear();
                        std::set<ID> used;
                        forEachTimedNote(original,&song,nullptr,[&](jaras::MIDINote note,double on,double off){
                            if(!used.insert(note.id).second)note.id=uuid();
                            note.start=(plan.time.position(on)-adjusted.startTime)*beats;
                            note.length=(plan.time.position(off)-plan.time.position(on))*beats;
                            midi.notes.push_back(std::move(note));
                            if(midi.notes.size()>1000000)throw std::runtime_error("Too many MIDI playback notes.");
                        });
                        adjusted.sourceOffset=0;adjusted.playbackRate=1;adjusted.renderedTempo.reset();
                        adjusted.tempoBasePlaybackRate.reset();adjusted.loopStart.reset();adjusted.loopLength.reset();
                        adjusted.tempoRateReferences.clear();adjusted.elasticPoints.clear();adjusted.elasticSourceScale=1;
                        for(const auto& marker:*mapped.markers)if(marker.tempoBPM)
                            adjusted.tempoRateReferences.push_back({marker.id,jaras::tempoPlayback::rate(mapped,marker)});
                    }
                    continue;
                }
                const auto times=edges(plan,original);
                if(projectionMedia(original)){
                    const auto path=ProjectCodec::mediaInput(directory,original.audioFile->path);
                    if(!inspectMediaSource(path).audio) {
                        adjusted.adjustedVideo=visualSource(original,plan,times);
                        ++completed;progress(double(completed)/std::max<size_t>(1,total),text(original.name));
                        continue;
                    }
                }
                std::vector<catlive::regionTempo::Anchor> anchors;
                for(double at:times)anchors.push_back({at-original.startTime,plan.time.position(at)-adjusted.startTime});
                double last=-1;
                auto update=[&](double x){
                    const auto value=(completed+x)/std::max<size_t>(1,total);
                    if(value>=last+.001 || x==1){last=value;progress(value,text(original.name));}
                };
                const auto cached=clickPrints.items.find(original.id);
                const auto printed=cached==clickPrints.items.end()
                    ? printItem(track,original,[&](double x){update(.45*x);}) : cached->second;
                struct Scratch { File file; bool owned; ~Scratch(){if(owned)file.deleteFile();} }
                    scratch{printed.generated,cached==clickPrints.items.end()};
                auto finalFile=stems.getNonexistentChildFile(File::createLegalFileName(text(original.name))+"-BPM",".wav");
                catlive::regionTempo::render(std::filesystem::u8path(utf8(scratch.file.getFullPathName())),
                    std::filesystem::u8path(utf8(finalFile.getFullPathName())),anchors,[&](double x){update(.45+.53*x);return !cancel.load();});
                result.files.push_back(finalFile);
                auto replacement=printed.clip;replacement.name=original.name;
                replacement.startTime=adjusted.startTime;replacement.duration=adjusted.duration;
                replacement.audioFile=jaras::AudioFile{utf8("Stems/"+finalFile.getFileName()),{}};
                if(projectionMedia(original))replacement.adjustedVideo=visualSource(original,plan,times);
                std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(finalFile));
                if(!reader)throw std::runtime_error("Could not read adjusted waveform.");
                replacement.waveform=peaks(*reader);adjusted=std::move(replacement);
                update(1);++completed;
            }
        }
        if(cancel.load())throw std::runtime_error("Operation cancelled.");
        result.song=std::move(mapped);result.time=std::move(plan.time);return result;
    }catch(...){result.discard();throw;}
}
}
