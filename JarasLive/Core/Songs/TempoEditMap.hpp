#pragma once
#include "Song.hpp"
#include <algorithm>
#include <cmath>
#include <unordered_map>
namespace jaras {
// Keep in step with TimelineTempo.swift. Detection batches intentionally bypass
// this edit map: inserting a measured tempo must not move the source material.
class TempoEditMap {
    struct Span { double start, end, output, scale; };
    std::vector<Span> spans;
    std::unordered_map<ID,double> clipStarts,clipDurations,regionDurations;
    static bool folder(const Song& song,const Part& part) {
        return std::any_of(song.parts.begin(),song.parts.end(),[&](const auto& child){return child.parentRegionID==part.id;});
    }
    static double ownershipEnd(const Song& song,const Part& part) {
        if(part.parentRegionID) for(const auto& group:song.parts) if(group.id==*part.parentRegionID) return group.endTime;
        return part.endTime;
    }
    static const Part* owner(const Song& song,double time) {
        const Part* result=nullptr;
        for(const auto& part:song.parts) if(!folder(song,part) && part.startTime<=time && time<ownershipEnd(song,part) &&
            (!result || part.startTime>result->startTime || (part.startTime==result->startTime && part.id>result->id))) result=&part;
        return result;
    }
    static const Part* owner(const Song& song,const AudioClip& clip) {
        if(clip.regionOwnerID) {
            const auto found=std::find_if(song.parts.begin(),song.parts.end(),[&](const auto& part){return part.id==*clip.regionOwnerID;});
            if(found==song.parts.end()) return nullptr;
            if(!folder(song,*found)) return &*found;
            // Importers may assign a crossing item to its unified parent.
            // Resolve its child once from the onset, never from the tail.
            const Part* result=nullptr;
            for(const auto& child:song.parts) if(child.parentRegionID==found->id && child.startTime<=clip.startTime &&
                (!result || child.startTime>result->startTime || (child.startTime==result->startTime && child.id>result->id))) result=&child;
            return result?result:&*found;
        }
        return song.regionOwnershipInitialized?nullptr:owner(song,clip.startTime);
    }
    static double ownerLimit(const Song& song,const Part& part) {
        double end=ownershipEnd(song,part);
        for(const auto& next:song.parts) if(!folder(song,next) && next.startTime>part.startTime &&
            (!part.parentRegionID || next.parentRegionID==part.parentRegionID)) end=std::min(end,next.startTime);
        return end;
    }
    static double rate(const Song& song, double time, const Part* part=nullptr) {
        const double limit=part?ownerLimit(song,*part):0;
        const TimelineMarker* active=nullptr;
        if(song.markers) for(const auto& marker:*song.markers)
            if(marker.tempoBPM && (!part || (marker.position>=part->startTime && marker.position<limit &&
                (!marker.regionOwnerID || marker.regionOwnerID==part->id || marker.regionOwnerID==part->parentRegionID))) &&
                marker.position<=time && (!active || marker.position>active->position || (marker.position==active->position && marker.id>active->id))) active=&marker;
        if(!active) return 1;
        const auto mode=active->tempoTimebase.value_or("global");
        const bool relative=mode=="relative" || (mode=="global" && song.timeSettings.value_or(ProjectTimeSettings{}).timebase==ProjectTimebase::relative);
        if(!relative || !std::isfinite(*active->tempoBPM) || *active->tempoBPM<=0) return 1;
        return *active->tempoBPM / active->tempoReferenceBPM.value_or(song.bpm);
    }
public:
    TempoEditMap(const Song& before,const Song& after) {
        std::vector<std::pair<double,double>> occupied;
        for(const auto& part:before.parts) if(!folder(before,part)) occupied.emplace_back(part.startTime,part.endTime);
        for(const auto& track:before.tracks) if(fixedTrackName(track.role).empty())
            for(const auto& clip:track.clips) if((clip.audioFile || track.audioFile) && !owner(before,clip)) occupied.emplace_back(clip.startTime,clip.startTime+clip.duration);
        std::sort(occupied.begin(),occupied.end());
        std::vector<std::pair<double,double>> merged;
        for(const auto& interval:occupied) if(interval.second>interval.first) {
            if(!merged.empty() && merged.back().second>=interval.first) merged.back().second=std::max(merged.back().second,interval.second);
            else merged.push_back(interval);
        }
        occupied=std::move(merged);
        std::vector<double> points{0,before.duration,after.duration};
        for(const auto& interval:occupied) {points.push_back(interval.first);points.push_back(interval.second);}
        for(const Song* song:{&before,&after}) if(song->markers) for(const auto& marker:*song->markers) if(marker.tempoBPM) points.push_back(marker.position);
        points.erase(std::remove_if(points.begin(),points.end(),[](double p){return !std::isfinite(p)||p<0;}),points.end());
        std::sort(points.begin(),points.end()); points.erase(std::unique(points.begin(),points.end()),points.end());
        double output=0;
        for(size_t i=1;i<points.size();++i) {
            const double start=points[i-1],end=points[i],middle=start+(end-start)/2;
            const bool filled=std::any_of(occupied.begin(),occupied.end(),[&](const auto& interval){return interval.first<=middle && middle<interval.second;});
            const double scale=filled ? rate(before,middle)/rate(after,middle) : 1;
            spans.push_back({start,end,output,scale}); output+=(end-start)*scale;
        }
        auto resizedDuration=[&](double start,double end,const Part& part) {
            const bool reversed=end<start;
            if(reversed) std::swap(start,end);
            const auto found=std::find_if(after.parts.begin(),after.parts.end(),[&](const auto& value){return value.id==part.id;});
            const Part* next=found==after.parts.end()?&part:&*found;
            std::vector<double> edges{start,end};
            for(const Song* song:{&before,&after}) if(song->markers) for(const auto& marker:*song->markers)
                if(marker.tempoBPM && marker.position>start && marker.position<end) edges.push_back(marker.position);
            std::sort(edges.begin(),edges.end());edges.erase(std::unique(edges.begin(),edges.end()),edges.end());
            double duration=0;
            for(size_t i=1;i<edges.size();++i) {
                const double middle=edges[i-1]+(edges[i]-edges[i-1])/2;
                duration+=(edges[i]-edges[i-1])*rate(before,middle,&part)/rate(after,middle,next);
            }
            return reversed?-duration:duration;
        };
        for(const auto& part:before.parts) if(!folder(before,part)) regionDurations[part.id]=resizedDuration(part.startTime,part.endTime,part);
        for(const auto& track:before.tracks) if(fixedTrackName(track.role).empty()) for(const auto& clip:track.clips)
            if(const auto* part=owner(before,clip)) {
                clipStarts[clip.id]=position(part->startTime)+resizedDuration(part->startTime,clip.startTime,*part);
                clipDurations[clip.id]=resizedDuration(clip.startTime,clip.startTime+clip.duration,*part);
            }
    }
    bool changesTime() const {return std::any_of(spans.begin(),spans.end(),[](const auto& span){return std::abs(span.scale-1)>1e-12;});}
    double position(double time) const {
        if(spans.empty() || !std::isfinite(time) || time<0) return time;
        auto span=std::upper_bound(spans.begin(),spans.end(),time,[](double time,const Span& span){return time<span.end;});
        if(span==spans.end()) {const auto& last=spans.back();return last.output+(last.end-last.start)*last.scale+time-last.end;}
        return span->output+(time-span->start)*span->scale;
    }
    void apply(Song& song) const {
        if(!changesTime()) return;
        for(auto& track:song.tracks) for(auto& clip:track.clips) {
            const double start=position(clip.startTime),end=position(clip.startTime+clip.duration);
            const auto onset=clipStarts.find(clip.id);clip.startTime=onset==clipStarts.end()?start:onset->second;
            const auto duration=clipDurations.find(clip.id);clip.duration=duration==clipDurations.end()?end-start:duration->second;
        }
        for(auto& part:song.parts) {
            part.startTime=position(part.startTime);const auto duration=regionDurations.find(part.id);
            part.endTime=duration==regionDurations.end()?position(part.endTime):part.startTime+duration->second;
        }
        for(auto& part:song.parts) if(folder(song,part)) {
            double end=part.startTime;
            for(const auto& child:song.parts) if(child.parentRegionID==part.id) end=std::max(end,child.endTime);
            part.endTime=end;
        }
        if(song.markers) for(auto& marker:*song.markers) marker.position=position(marker.position);
        song.duration=position(song.duration);
        for(const auto& track:song.tracks) for(const auto& clip:track.clips) song.duration=std::max(song.duration,clip.startTime+clip.duration);
        for(const auto& part:song.parts) song.duration=std::max(song.duration,part.endTime);
    }
};
}
