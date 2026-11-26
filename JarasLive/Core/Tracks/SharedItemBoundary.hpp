#pragma once
#include "ItemResize.hpp"
#include <utility>
#include <set>
namespace jaras {
inline std::optional<std::vector<AudioClip>> teleprompterBoundary(
    const Track &track, const std::set<ID> &selected, const ID &left, const ID &right, double position) {
    if (!isTeleprompterRole(track.role) || !std::isfinite(position) || !selected.count(left) || !selected.count(right)) return {};
    auto clips=track.clips;
    std::sort(clips.begin(),clips.end(),[](const auto &a,const auto &b){return a.startTime==b.startTime?a.id<b.id:a.startTime<b.startTime;});
    const auto at=std::find_if(clips.begin(),clips.end(),[&](const auto &clip){return clip.id==left;});
    if(at==clips.end())return {};
    const size_t index=size_t(at-clips.begin());
    auto eligible=[&](size_t i){return selected.count(clips[i].id) && clips[i].text && !clips[i].audioFile && !clips[i].midi;};
    auto adjacent=[&](size_t a,size_t b){return eligible(a)&&eligible(b)&&clips[a].recordingLane.value_or(0)==clips[b].recordingLane.value_or(0)&&std::abs(clips[a].startTime+clips[a].duration-clips[b].startTime)<1e-7;};
    if(index+1>=clips.size()||clips[index+1].id!=right||!adjacent(index,index+1))return {};
    size_t first=index,last=index+1;
    while(first>0&&adjacent(first-1,first))--first;
    while(last+1<clips.size()&&adjacent(last,last+1))++last;
    std::vector<AudioClip> result(clips.begin()+first,clips.begin()+last+1);
    std::vector<double> edges;for(const auto &clip:result)edges.push_back(clip.startTime);
    edges.push_back(result.back().startTime+result.back().duration);
    const size_t boundary=index-first+1;
    auto lower=edges.front(),upper=edges.back();
    for(size_t i=0;i<boundary;++i)lower=std::nextafter(lower+.01,INFINITY);
    for(size_t i=boundary;i<result.size();++i)upper=std::nextafter(upper-.01,-INFINITY);
    if(lower>upper)return {};
    edges[boundary]=std::clamp(position,lower,upper);
    for(size_t i=boundary+1;i<result.size();++i)edges[i]=std::max(edges[i],std::nextafter(edges[i-1]+.01,INFINITY));
    for(size_t i=boundary-1;i>0;--i)edges[i]=std::min(edges[i],std::nextafter(edges[i+1]-.01,-INFINITY));
    for(size_t i=0;i<result.size();++i){result[i].startTime=edges[i];result[i].duration=edges[i+1]-edges[i];if(result[i].duration<.01)return {};}
    return result;
}
inline std::optional<std::pair<AudioClip, AudioClip>> sharedItemBoundary(
    const AudioClip &left, const AudioClip &right, double position,
    std::optional<double> leftSource = {}, std::optional<double> rightSource = {}) {
    if (!std::isfinite(position) || left.id == right.id ||
        std::abs(left.startTime + left.duration - right.startTime) >= 1e-7 ||
        left.recordingLane.value_or(0) != right.recordingLane.value_or(0)) return {};
    // Keep the 10 ms interval representable after subtracting a large timeline
    // position; rounding below .01 would make resizedItemSource reject one half.
    double lower = std::nextafter(left.startTime + .01, INFINITY);
    double upper = std::nextafter(right.startTime + right.duration - .01, -INFINITY);
    if (right.audioFile && !right.midi && !right.loopLength && !rightSource)
        lower = std::max(lower, right.startTime - right.sourceOffset / right.playbackRate);
    if (lower > upper) return {};
    const double boundary = std::clamp(position, lower, upper);
    auto a = resizedItemSource(left, left.startTime, boundary, leftSource);
    auto b = resizedItemSource(right, boundary, right.startTime + right.duration, rightSource);
    if (std::abs(a.startTime + a.duration - b.startTime) >= 1e-7) return {};
    return std::pair<AudioClip, AudioClip>{std::move(a), std::move(b)};
}
}
