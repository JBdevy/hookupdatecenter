#pragma once
#include "AudioExport.h"
#include "MIDIPlayback.h"
namespace catlive::itemRender {
struct Replacement { ID track; std::set<ID> originals; jaras::AudioClip clip; File generated; };
inline std::vector<Replacement> render(const jaras::Project &project,const jaras::Song &song,
    const File &directory,const std::set<ID> &ids,bool glue,int midiChannels,
    std::atomic<bool> &cancel,const std::function<void(double)> &progress) {
    std::vector<Replacement> replacements; std::vector<File> created;
    try {
        for(const auto &track:song.tracks) {
            std::vector<jaras::AudioClip> selected;
            for(const auto &clip:track.clips)if(ids.count(clip.id))selected.push_back(clip);
            if(selected.empty())continue;
            if(!jaras::fixedTrackName(track.role).empty() && track.role.id!="video")continue;
            std::sort(selected.begin(),selected.end(),[](const auto &a,const auto &b){return a.startTime<b.startTime;});
            std::vector<std::vector<jaras::AudioClip>> groups;
            if(glue)groups.push_back(selected);else for(const auto &clip:selected)groups.push_back({clip});
            for(auto clips:groups) {
                if(cancel.load())throw std::runtime_error("Operação cancelada.");
                const bool allMIDI=std::all_of(clips.begin(),clips.end(),[](const auto &c){return c.midi.has_value();});
                const bool anyMIDI=std::any_of(clips.begin(),clips.end(),[](const auto &c){return c.midi.has_value();});
                const bool allMuted=std::all_of(clips.begin(),clips.end(),[](const auto &c){return c.muted;});
                const double start=clips.front().startTime,end=std::max_element(clips.begin(),clips.end(),[](const auto &a,const auto &b){return a.startTime+a.duration<b.startTime+b.duration;})->startTime +
                    std::max_element(clips.begin(),clips.end(),[](const auto &a,const auto &b){return a.startTime+a.duration<b.startTime+b.duration;})->duration;
                Replacement replacement;replacement.track=track.id;for(const auto &c:clips)replacement.originals.insert(c.id);
                auto result=clips.front();if(glue)result.id=uuid();
                if(glue && allMIDI) {
                    if(clips.size()>1) {
                        for(const auto &c:clips)if(c.fxJSON || c.automationJSON || c.pan.value_or(0)!=0 || c.phaseInverted.value_or(false) || c.normalizationGain.value_or(1)!=1 || c.channelMode.value_or(0)!=0 || c.fadeIn.value_or(0)!=0 || c.fadeOut.value_or(0)!=0 || c.pitchSemitones.value_or(0)!=0)
                            throw std::runtime_error("Estes itens MIDI possuem processamento individual. Converta-os em áudio antes de unificar para preservar o som.");
                        result={};result.id=uuid();result.name=clips.front().name;result.startTime=start;result.duration=end-start;result.muted=allMuted;result.recordingLane=clips.front().recordingLane;result.midi.emplace();
                        result.midi->sourceBPM=120;result.midi->division=clips.front().midi->division;result.midi->mode=clips.front().midi->mode;result.midi->swing=clips.front().midi->swing;
                        ClipTempo target(result,&song);auto sourceTrack=track;sourceTrack.clips=clips;if(allMuted)for(auto &c:sourceTrack.clips)c.muted=false;
                        auto neutral=song;for(auto &part:neutral.parts)part.pitchSemitones=0;
                        for(const auto &n:playbackNotes(sourceTrack,&neutral)){const auto begin=target.sourceAt(n.start)*2,finish=target.sourceAt(n.end)*2;if(finish>begin)result.midi->notes.push_back({uuid(),begin,finish-begin,n.pitch,n.velocity,n.channel});}
                    }
                } else {
                    auto source=song;auto sourceTrack=track;sourceTrack.role.id="other";sourceTrack.clips=clips;
                    const bool printTrackFX=anyMIDI || (glue && std::any_of(clips.begin(),clips.end(),[](const auto &c){return c.frozenMIDI.value_or(false);}) && !std::all_of(clips.begin(),clips.end(),[](const auto &c){return c.frozenMIDI.value_or(false);}));
                    if(!printTrackFX)sourceTrack.fxJSON.reset();
                    sourceTrack.automationJSON.reset();sourceTrack.parentTrackID.reset();sourceTrack.routing.reset();sourceTrack.stereoLinkPartner.reset();sourceTrack.volume=1;sourceTrack.pan=0;sourceTrack.mute=false;sourceTrack.solo=false;sourceTrack.phaseInverted=false;
                    sourceTrack.patch=jaras::OutputPatch{0,2};sourceTrack.outputs.reset();sourceTrack.secondaryPatch.reset();
                    if(!glue || allMuted)for(auto &c:sourceTrack.clips)c.muted=false;
                    source.tracks={sourceTrack};if(!glue && !anyMIDI)for(auto &part:source.parts)part.pitchSemitones=0;
                    auto folder=directory.getChildFile("Stems");if(folder.createDirectory().failed())throw std::runtime_error("Não foi possível criar a pasta Stems.");
                    auto stem=File::createLegalFileName(File(text(clips.front().name)).getFileNameWithoutExtension()).substring(0,80);if(stem.isEmpty())stem="Item";
                    auto destination=folder.getNonexistentChildFile(stem,".wav");
                    ExportRequest request;request.directory=folder;request.encodings[0].channels=midiChannels==1?1:2;
                    request.jobs.push_back({destination.getFileName(),start,end,track.id,{}});
                    auto neutralProject=project;neutralProject.masterFXJSON.reset();neutralProject.masterAutomationJSON.reset();neutralProject.masterVolume=1;neutralProject.masterPan=0;neutralProject.masterMute=false;neutralProject.masterSolo=false;neutralProject.masterMono=false;
                    audioExport::render(neutralProject,source,directory,request,cancel,progress);created.push_back(destination);
                    result={};result.id=glue?uuid():clips.front().id;result.name=utf8(destination.getFileNameWithoutExtension());result.startTime=start;result.duration=end-start;result.audioFile=jaras::AudioFile{utf8("Stems/"+destination.getFileName()),{}};result.muted=allMuted;result.recordingLane=clips.front().recordingLane;result.regionOwnerID=clips.front().regionOwnerID;result.renderedTiming=glue || anyMIDI;result.renderedTempo=true;
                    if(printTrackFX || std::all_of(clips.begin(),clips.end(),[](const auto &c){return c.frozenMIDI.value_or(false);}))result.frozenMIDI=true;
                    replacement.generated=destination;
                }
                replacement.clip=std::move(result);replacements.push_back(std::move(replacement));
            }
        }
        if(replacements.empty())throw std::runtime_error("Selecione itens de áudio ou MIDI.");
        if(cancel.load())throw std::runtime_error("Operação cancelada.");
        return replacements;
    }catch(...){for(const auto &file:created)file.deleteFile();throw;}
}
}
