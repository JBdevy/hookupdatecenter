#pragma once
#include "Project/Models.hpp"
#include <algorithm>
#include <cmath>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace catlive {
using jaras::ID;

// Same interval partitioning as Swift RegionLanes. Lane numbers are derived
// from geometry, never persisted in the document or assigned by drag direction.
struct RegionLanes {
    int count = 1;

    explicit RegionLanes(const std::vector<jaras::Part> &parts) {
        std::vector<const jaras::Part *> ordered;
        ordered.reserve(parts.size());
        for (const auto &part : parts)
            if (!part.parentRegionID)
                ordered.push_back(&part);
        std::sort(ordered.begin(), ordered.end(), [](const auto *a, const auto *b) {
            if (a->startTime != b->startTime) return a->startTime < b->startTime;
            if (a->endTime != b->endTime) return a->endTime > b->endTime;
            return a->id < b->id;
        });
        std::vector<double> ends;
        for (const auto *part : ordered) {
            const auto available = std::find_if(ends.begin(), ends.end(),
                                                [&](double end) { return end <= part->startTime; });
            const int index = (int)std::distance(ends.begin(), available);
            if (available == ends.end()) ends.push_back(part->endTime);
            else *available = part->endTime;
            lanes.emplace(part->id, index);
        }
        count = std::max(1, (int)ends.size());
    }

    int lane(const ID &id) const {
        const auto found = lanes.find(id);
        return found == lanes.end() ? 0 : found->second;
    }

  private:
    std::unordered_map<ID, int> lanes;
};

namespace regionEditDetail {
inline ID timecodeItemID(ID region) {
    // Core synchronizeTimecode uses this stable namespace for generated items.
    if (region.size() == 36) {
        const char first = region[0];
        const int digit = first >= '0' && first <= '9' ? first - '0'
                        : first >= 'a' && first <= 'f' ? first - 'a' + 10
                        : first >= 'A' && first <= 'F' ? first - 'A' + 10 : -1;
        if (digit >= 0) {
            region[0] = "0123456789ABCDEF"[digit ^ 8];
            return region;
        }
    }
    return region + "-timecode";
}
} // namespace regionEditDetail

// Prepared once per gesture, matching the Mac's zoom-aware marker repulsion.
struct RegionMarkerRepulsion {
    double originalStart = 0, minimumStart = 0;
    std::vector<std::pair<double,double>> intervals;
    RegionMarkerRepulsion(const jaras::Song &song, const jaras::Part &region, double minimumGap) : originalStart(region.startTime) {
        const double gap=std::isfinite(minimumGap)?std::max(.01,minimumGap):.01;
        std::vector<double> offsets, stationary;
        if(song.markers) for(const auto &marker:*song.markers) {
            const auto owner=song.regionOwnershipInitialized?marker.regionOwnerID:
                marker.sourceRegionID?marker.sourceRegionID:jaras::regionOwnerAt(song,marker.position);
            if(marker.unifiedRegionID==region.id || jaras::regionOwns(song,region.id,owner)) offsets.push_back(marker.position-region.startTime);
            else stationary.push_back(marker.position);
        }
        for(double offset:offsets)minimumStart=std::max(minimumStart,-offset);
        std::vector<std::pair<double,double>> ranges;
        for(double offset:offsets)for(double point:stationary) {
            const double center=point-offset;
            if(center+gap>minimumStart)ranges.emplace_back(center-gap,center+gap);
        }
        std::sort(ranges.begin(),ranges.end());
        for(const auto &range:ranges) {
            if(!intervals.empty() && range.first<intervals.back().second)intervals.back().second=std::max(intervals.back().second,range.second);
            else intervals.push_back(range);
        }
    }
    double resolve(double proposed) const {
        if(!std::isfinite(proposed))return originalStart;
        const double start=std::max(minimumStart,proposed);
        const auto it=std::lower_bound(intervals.begin(),intervals.end(),start+1e-9,
            [](const auto &range,double value){return range.second<=value;});
        if(it==intervals.end() || start<=it->first+1e-9 || start>=it->second-1e-9)return start;
        if(it->first<minimumStart)return it->second;
        const double left=start-it->first,right=it->second-start;
        if(std::abs(left-right)<=1e-9)return proposed>=originalStart?it->second:it->first;
        return left<right?it->first:it->second;
    }
};

// Pure visual preview of a move/resize. The caller resolves snapping and marker
// repulsion before passing start. Moves preserve duration (end is only used for
// resize); a rejected preview leaves the committed song untouched.
inline std::optional<jaras::Song> previewRegionEdit(const jaras::Song &song, const ID &id,
                                                  double start, double end, bool resize) {
    if (!std::isfinite(start) || start < 0) return std::nullopt;
    const auto original = std::find_if(song.parts.begin(), song.parts.end(),
                                       [&](const auto &part) { return part.id == id; });
    if (original == song.parts.end() || original->parentRegionID) return std::nullopt;
    const bool hasChildren = std::any_of(song.parts.begin(), song.parts.end(),
                                        [&](const auto &part) { return part.parentRegionID == id; });
    if (resize && (hasChildren || !std::isfinite(end) || end <= start)) return std::nullopt;
    const double delta = start - original->startTime;
    const double newEnd = resize ? end : original->endTime + delta;
    if (!std::isfinite(newEnd) || newEnd <= start) return std::nullopt;

    // Reject a third simultaneous root before copying any waveform/MIDI data.
    auto parts = song.parts;
    for (auto &part : parts) {
        if (part.id == id) { part.startTime = start; part.endTime = newEnd; }
        else if (!resize && part.parentRegionID == id) {
            part.startTime += delta; part.endTime += delta;
        }
    }
    if (RegionLanes(parts).count > 2) return std::nullopt;

    jaras::Song result = song;
    result.parts = std::move(parts);
    result.duration = std::max(result.duration, newEnd);
    if (resize) return result; // Region bounds do not drag their contents.

    std::unordered_set<ID> ownedRegions{id};
    for (const auto &part : song.parts)
        if (part.parentRegionID == id) ownedRegions.insert(part.id);
    const auto owns = [&](const std::optional<ID> &owner) {
        return owner && ownedRegions.count(*owner) != 0;
    };
    const auto timecodeID = regionEditDetail::timecodeItemID(id);
    for (auto &track : result.tracks) {
        const bool nativeTimecode = track.role.id == "timecode" && !track.importedTimecodeItems;
        for (auto &clip : track.clips) {
            if (nativeTimecode && !clip.audioFile) {
                if (clip.id != timecodeID) continue;
                clip.startTime = std::max(0.0, start + clip.timecodeStartOffset.value_or(0));
                const double finish = std::max(clip.startTime + 0.01,
                                                newEnd + clip.timecodeEndOffset.value_or(0));
                clip.duration = finish - clip.startTime;
                result.duration = std::max(result.duration, finish);
            } else if (owns(song.regionOwnershipInitialized ? clip.regionOwnerID
                                                            : jaras::regionOwnerAt(song, clip.startTime))) {
                clip.startTime = std::max(0.0, clip.startTime + delta);
                result.duration = std::max(result.duration, clip.startTime + clip.duration);
            }
        }
    }
    if (result.markers)
        for (auto &marker : *result.markers) {
            const auto owner = song.regionOwnershipInitialized ? marker.regionOwnerID
                             : marker.sourceRegionID ? marker.sourceRegionID
                                                     : jaras::regionOwnerAt(song, marker.position);
            if (marker.unifiedRegionID == id || owns(owner)) {
                marker.position = std::max(0.0, marker.position + delta);
                result.duration = std::max(result.duration, marker.position);
            }
        }
    return result;
}
} // namespace catlive
