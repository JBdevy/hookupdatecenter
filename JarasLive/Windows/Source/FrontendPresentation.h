#pragma once
#include "Common.h"

namespace catlive::frontendPresentation {
// Display data only. Never use this projection to save a project: plugin state,
// source waveform caches and non-visible songs deliberately remain in Session.
inline void value(var &out, const char *key, const std::string &v) { put(out,key,text(v)); }
inline void value(var &out, const char *key, unsigned v) { put(out,key,(int64)v); }
template<class T> inline void value(var &out,const char *key,const T &v) { put(out,key,v); }
template<class T> inline void optional(var &out,const char *key,const std::optional<T> &v) { if(v)value(out,key,*v); }
inline void file(var &out,const std::optional<jaras::AudioFile> &source) {
    if(source){auto f=object();value(f,"path",source->path);put(out,"audioFile",f);}
}
inline var clip(const jaras::AudioClip &c) {
    auto v=object();value(v,"id",c.id);value(v,"name",c.name);
    value(v,"startTime",c.startTime);value(v,"duration",c.duration);value(v,"sourceOffset",c.sourceOffset);
    value(v,"playbackRate",c.playbackRate);value(v,"muted",c.muted);file(v,c.audioFile);
    optional(v,"gain",c.gain);optional(v,"pan",c.pan);optional(v,"normalizationGain",c.normalizationGain);
    optional(v,"phaseInverted",c.phaseInverted);optional(v,"channelMode",c.channelMode);
    optional(v,"fadeIn",c.fadeIn);optional(v,"fadeOut",c.fadeOut);optional(v,"fadeInCurve",c.fadeInCurve);
    optional(v,"fadeOutCurve",c.fadeOutCurve);optional(v,"fadeInSCurve",c.fadeInSCurve);optional(v,"fadeOutSCurve",c.fadeOutSCurve);
    optional(v,"loopStart",c.loopStart);optional(v,"loopLength",c.loopLength);optional(v,"recordingLane",c.recordingLane);
    optional(v,"regionOwnerID",c.regionOwnerID);optional(v,"text",c.text);optional(v,"frozenMIDI",c.frozenMIDI);
    if(c.midi) {
        auto midi=object();Array<var> notes;value(midi,"sourceBPM",c.midi->sourceBPM);
        // Preview density is bounded; the original MIDI data stays untouched.
        const auto stride=std::max<size_t>(1,(c.midi->notes.size()+511)/512);
        for(size_t i=0;i<c.midi->notes.size();i+=stride) {
            const auto &n=c.midi->notes[i];auto note=object();value(note,"start",n.start);
            value(note,"length",n.length);value(note,"pitch",n.pitch);notes.add(note);
        }
        put(midi,"notes",notes);put(v,"midi",midi);
    }
    return v;
}
inline var song(const jaras::Song &s) {
    auto v=object();value(v,"id",s.id);value(v,"name",s.name);value(v,"duration",s.duration);
    value(v,"bpm",s.bpm);value(v,"beatsPerBar",s.beatsPerBar);value(v,"beatUnit",s.beatUnit);
    if(s.timeSettings){auto settings=object();value(settings,"divisions",s.timeSettings->divisions);put(v,"timeSettings",settings);}
    Array<var> tracks,parts,markers;
    for(const auto &t:s.tracks) {
        auto track=object();value(track,"id",t.id);value(track,"name",t.name);value(track,"role",t.role.id);
        value(track,"volume",t.volume);value(track,"pan",t.pan);value(track,"mute",t.mute);value(track,"solo",t.solo);
        optional(track,"color",t.color);optional(track,"heightScale",t.heightScale);optional(track,"parentTrackID",t.parentTrackID);
        optional(track,"phaseInverted",t.phaseInverted);file(track,t.audioFile);
        Array<var> clips,cues;for(const auto &c:t.clips)clips.add(clip(c));put(track,"clips",clips);
        for(const auto &c:t.programChanges){auto cue=object();value(cue,"id",c.id);value(cue,"name",c.name);value(cue,"position",c.position);value(cue,"program",c.program);value(cue,"channel",c.channel);optional(cue,"output",c.output);cues.add(cue);}put(track,"programChanges",cues);
        tracks.add(track);
    }
    for(const auto &p:s.parts){auto part=object();value(part,"id",p.id);value(part,"name",p.name);value(part,"startTime",p.startTime);value(part,"endTime",p.endTime);optional(part,"color",p.color);optional(part,"parentRegionID",p.parentRegionID);parts.add(part);}
    if(s.markers)for(const auto &m:*s.markers) {
        auto marker=object();value(marker,"id",m.id);value(marker,"name",m.name);value(marker,"position",m.position);value(marker,"color",m.color);
        optional(marker,"section",m.section);optional(marker,"tempoBPM",m.tempoBPM);optional(marker,"tempoBeats",m.tempoBeats);optional(marker,"tempoUnit",m.tempoUnit);
        optional(marker,"regionOwnerID",m.regionOwnerID);markers.add(marker);
    }
    put(v,"tracks",tracks);put(v,"parts",parts);put(v,"markers",markers);return v;
}
inline var project(const jaras::Project &p) {
    auto v=object();value(v,"id",p.id);value(v,"name",p.name);value(v,"masterVolume",p.masterVolume);
    value(v,"masterPan",p.masterPan);value(v,"masterMute",p.masterMute);value(v,"masterSolo",p.masterSolo);value(v,"masterMono",p.masterMono);
    optional(v,"timelineMovementLocked",p.timelineMovementLocked);
    if(p.regionSetlist) {
        const auto &s=*p.regionSetlist;auto setlist=object();optional(setlist,"selectedId",s.selectedId);
        value(setlist,"autoAdvance",s.autoAdvance);optional(setlist,"stopAtRegionEnd",s.stopAtRegionEnd);
        Array<var> playlists;
        for(const auto &p:s.playlists) {
            auto list=object();value(list,"id",p.id);value(list,"name",p.name);value(list,"songId",p.songId);
            Array<var> ids,duplicates;for(const auto &id:p.regionIds)ids.add(text(id));put(list,"regionIds",ids);
            if(p.duplicates)for(const auto &d:*p.duplicates){auto entry=object();value(entry,"id",d.id);value(entry,"regionId",d.regionId);duplicates.add(entry);}
            put(list,"duplicates",duplicates);playlists.add(list);
        }
        put(setlist,"playlists",playlists);put(v,"regionSetlist",setlist);
    }
    return v;
}
}
