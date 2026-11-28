#pragma once
#include "TempoPlaybackRate.hpp"
#include "../Audio/PiecewiseTimeMap.hpp"
#include "../Project/Models.hpp"
#include "../Tracks/AutomationTiming.hpp"
#include <map>
#include <set>
#include <stdexcept>

namespace jaras::regionTempo {
struct Plan {
    double start, end, target;
    catlive::audio::PiecewiseTimeMap time;
    std::vector<double> edges;
    Plan(const Song& song, const Part& region, double bpm) : start(region.startTime), end(region.endTime), target(bpm) {
        if (!std::isfinite(bpm) || bpm < 60 || bpm > 300) throw std::invalid_argument("Enter a BPM between 60 and 300.");
        std::set<double> boundaries{start,end};
        bool found=false;
        if(song.markers) for(const auto& marker:*song.markers) if(marker.tempoBPM) {
            if(marker.position>=start && marker.position<end){found=true;boundaries.insert(marker.position);}
            const auto limit=tempoPlayback::markerEnd(song,marker);
            if(limit>start && limit<end)boundaries.insert(limit);
        }
        if(!found)throw std::invalid_argument("Nenhum marcador de tempo encontrado.");
        std::set<double> tempos;
        double next=start;
        for(auto it=boundaries.begin();std::next(it)!=boundaries.end();++it) {
            const auto active=tempoPlayback::active(song,*it);
            const auto value=active ? *active->tempoBPM : song.bpm;
            const double scale=value/bpm;
            tempos.insert(value);time.append(*it,next,scale);edges.push_back(*it);
            next+=(*std::next(it)-*it)*scale;
        }
        if(tempos.size()<2)throw std::invalid_argument("A região precisa ter pelo menos dois BPMs diferentes.");
        time.append(end,next,1);edges.push_back(end);
    }
    bool overlaps(const AudioClip& clip) const {return clip.startTime<end && clip.startTime+clip.duration>start && clip.duration>0;}
    // The visible tempo markers summarize a performance over several bars. Within
    // those bars, use the recorded Click as the timing reference for every stem.
    void alignToClick(std::vector<double> pulses) {
        pulses.erase(std::remove_if(pulses.begin(), pulses.end(), [&](double t) {
            return !std::isfinite(t) || t < start || t >= end;
        }), pulses.end());
        std::sort(pulses.begin(), pulses.end());
        std::vector<double> beats;
        for (double t : pulses)
            if (beats.empty() || t - beats.back() > .08) beats.push_back(t);
        if (beats.size() < 4) return;

        const double period = 60 / target;
        struct Point { double source, nominal, aligned; };
        std::vector<Point> anchors;
        // Require a run of actual quarter notes. Isolated noises, subdivisions
        // and long rests cannot independently establish the clock.
        size_t first = 0;
        while (first < beats.size()) {
            size_t last = first;
            unsigned singles = 0;
            while (last + 1 < beats.size()) {
                const double distance = (time.position(beats[last+1]) - time.position(beats[last])) / period;
                const double steps = std::round(distance);
                if (steps < 1 || steps > 8 || std::abs(distance - steps) > .22) break;
                singles += steps == 1;
                ++last;
            }
            if (last - first >= 3 && singles >= 2) {
                double nominal = time.position(beats[first]);
                double aligned = nominal;
                if (!anchors.empty()) {
                    const auto& previous = anchors.back();
                    const auto gap = (nominal - previous.nominal) / period;
                    aligned = previous.aligned + (gap >= .75 ? std::round(gap) : gap) * period;
                }
                anchors.push_back({beats[first], nominal, aligned});
                for (size_t i = first + 1; i <= last; ++i) {
                    const double next = time.position(beats[i]);
                    aligned += std::round((next - nominal) / period) * period;
                    anchors.push_back({beats[i], next, aligned});
                    nominal = next;
                }
            }
            first = last + 1;
        }
        if (anchors.empty()) return;
        // Apply phase corrections on top of the marker clock. This retains all
        // marker slopes, the lead-in and the tail, including across silent gaps.
        catlive::audio::PiecewiseTimeMap phase;
        for (size_t i = 0; i < anchors.size(); ++i) {
            const auto& a = anchors[i];
            const double scale = i + 1 == anchors.size() ? 1 :
                (anchors[i+1].aligned-a.aligned)/(anchors[i+1].nominal-a.nominal);
            phase.append(a.nominal, a.aligned, scale);
            edges.push_back(a.source);
        }
        std::sort(edges.begin(), edges.end());
        edges.erase(std::unique(edges.begin(), edges.end()), edges.end());
        time = time.followedBy(phase);
    }
    template<class NewID> void apply(Project& project, Song& song, const Part& region, NewID newID) const {
        const auto selectedID=region.id;
        auto restored=tempoPlayback::active(song,end);
        TimelineMarker resume=restored?*restored:TimelineMarker{};
        resume.tempoBPM=restored?*restored->tempoBPM:song.bpm;
        resume.tempoPlaybackRate=restored?tempoPlayback::rate(song,*restored):1.;
        if(!restored){resume.name="TEMPO";resume.color=0x999999;resume.tempoBeats=song.beatsPerBar;resume.tempoUnit=song.beatUnit;}
        std::map<ID,double> starts;
        for(const auto& part:song.parts)starts.emplace(part.id,part.startTime);
        auto map=[&](double at){return time.position(at);};
        for(auto& track:song.tracks) {
            automationTiming::map(track.automationJSON,map);
            for(auto& marker:track.programChanges)marker.position=map(marker.position);
            for(auto& chord:track.chordMarkers)if(auto it=starts.find(chord.regionID);it!=starts.end())
                chord.offset=map(it->second+chord.offset)-map(it->second);
            for(auto& clip:track.clips) {
                const auto was=clip.startTime;clip.startTime=map(was);clip.duration=map(was+clip.duration)-clip.startTime;
            }
        }
        if(project.songs.size()==1 || (project.savedCursor && project.savedCursor->songID==song.id))
            automationTiming::map(project.masterAutomationJSON,map);
        if(project.savedCursor && project.savedCursor->songID==song.id)project.savedCursor->position=map(project.savedCursor->position);
        for(auto& part:song.parts){
            if(part.subplayInitSeconds)part.subplayInitSeconds=map(part.startTime+*part.subplayInitSeconds)-map(part.startTime);
            part.startTime=map(part.startTime);part.endTime=map(part.endTime);
        }
        for(auto& track:song.tracks)if(track.role.id=="timecode" && !track.importedTimecodeItems)
            for(auto& clip:track.clips)if(!clip.audioFile)for(const auto& part:song.parts) {
                auto item=part.id;
                if(item.size()==36){const auto digit=std::stoi(item.substr(0,1),nullptr,16)^8;item[0]="0123456789ABCDEF"[digit];}
                else item+="-timecode";
                if(item==clip.id){clip.timecodeStartOffset=clip.startTime-part.startTime;clip.timecodeEndOffset=clip.startTime+clip.duration-part.endTime;break;}
            }
        bool atStart=false;
        for(auto& marker:*song.markers) {
            const auto was=marker.position;
            if(marker.tempoBPM && was>=start && was<end) {
                atStart|=was==start;marker.tempoBPM=target;marker.tempoPlaybackRate=1.;marker.tempoReferenceBPM=target;
                marker.regionOwnerID=selectedID;
            }
            marker.position=map(was);
        }
        if(!atStart) {
            TimelineMarker first;first.id=newID();first.name="TEMPO";first.position=start;first.color=0xffb347;
            first.tempoBPM=target;first.tempoReferenceBPM=target;first.tempoPlaybackRate=1.;first.regionOwnerID=selectedID;
            first.tempoBeats=song.beatsPerBar;first.tempoUnit=song.beatUnit;
            song.markers->push_back(std::move(first));
        }
        const auto after=tempoPlayback::active(song,map(end));
        if((after?*after->tempoBPM:song.bpm)!=*resume.tempoBPM ||
           std::abs((after?tempoPlayback::rate(song,*after):1.)-*resume.tempoPlaybackRate)>1e-9){
            resume.id=newID();resume.position=map(end);resume.regionTempoAnchor.reset();resume.sourceRegionID.reset();
            song.markers->push_back(std::move(resume));
        }
        song.duration=map(song.duration);
    }
};
}
