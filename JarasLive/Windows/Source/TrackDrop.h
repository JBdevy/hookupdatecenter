#pragma once
#include "TrackTree.h"
namespace catlive::trackDrop {
inline var description(const jaras::Project &project,const jaras::Song &song,const ID &track){auto v=object();put(v,"track",text(track));put(v,"song",text(song.id));put(v,"project",text(project.id));return v;}
inline ID source(const var &v,const jaras::Project &p,const jaras::Song &s){return str(v,"project")==text(p.id)&&str(v,"song")==text(s.id)?utf8(str(v,"track")):ID{};}
struct Destination {
    ID source, target, before, indicator;
    std::optional<ID> parent;
    bool after=false, joins=false, adoption=false;
    std::vector<ID> adopt;
};
inline std::optional<Destination> resolve(const jaras::Song &song,const ID &source,const ID &target,bool after,bool outside) {
    const auto a=trackTree::index(song,source),b=trackTree::index(song,target),n=song.tracks.size();
    if(a==n||b==n||a==b||!jaras::fixedTrackName(song.tracks[a].role).empty()||!jaras::fixedTrackName(song.tracks[b].role).empty()||trackTree::descendant(song,b,source))return {};
    const auto last=trackTree::end(song,a);
    Destination d;d.source=source;d.target=target;d.indicator=target;d.after=after;
    const bool folder=last>a+1,targetFolder=trackTree::end(song,b)>b+1;
    if(!folder) {
        d.parent=after&&targetFolder?std::optional<ID>(target):song.tracks[b].parentTrackID;
        size_t boundary=b;
        if(outside&&d.parent) {
            const auto group=trackTree::index(song,*d.parent);if(group==n)return {};
            boundary=after?trackTree::end(song,group)-1:group;
            if(after&&song.tracks[boundary].id==source&&boundary>group)--boundary;
            d.parent=song.tracks[group].parentTrackID;d.indicator=song.tracks[boundary].id;
        }
        size_t insertion=boundary+(after?1:0);
        while(insertion<n&&song.tracks[insertion].id==source)++insertion;
        d.before=insertion<n?song.tracks[insertion].id:ID{};d.joins=!outside&&d.parent.has_value();
    } else if(song.tracks[b].parentTrackID&&!trackTree::descendant(song,a,target)) {
        if(after) {d.parent=song.tracks[b].parentTrackID;d.before=target;d.after=false;d.joins=true;}
        else {
            const ID parent=*song.tracks[b].parentTrackID;const auto group=trackTree::index(song,parent);
            if(group==n)return {};d.parent=song.tracks[group].parentTrackID;d.adoption=true;
            for(size_t i=b;i<n;++i)if(song.tracks[i].parentTrackID==parent&&song.tracks[i].id!=source) {
                if(trackTree::descendant(song,a,song.tracks[i].id))return {};
                d.adopt.push_back(song.tracks[i].id);
            }
            if(d.adopt.empty())return {};
            auto boundary=trackTree::end(song,group);d.before=boundary<n?song.tracks[boundary].id:ID{};
            d.indicator=source;d.after=true;
        }
    } else {
        size_t insertion=b+(after?1:0);
        if(insertion>=a&&insertion<last)insertion=last;
        d.before=insertion<n?song.tracks[insertion].id:ID{};
        d.parent=insertion<n?song.tracks[insertion].parentTrackID:std::optional<ID>{};
    }
    return d;
}
inline void setParent(jaras::Track &track,const std::optional<ID> &parent) {
    if(track.parentTrackID==parent)return;
    track.parentTrackID=parent;
    if(!parent){trackTree::resetGroupOutput(track);return;}
    auto patches=track.outputPatches();if(patches.empty())patches.push_back({-2,2});else patches.front()={-2,2};
    patches.erase(std::remove_if(patches.begin()+1,patches.end(),[](const auto &p){return p.firstChannel==0||p.firstChannel==-2;}),patches.end());
    track.patch=patches.front();track.secondaryPatch=patches.size()>1?std::optional<jaras::OutputPatch>(patches[1]):std::optional<jaras::OutputPatch>{};
    if(track.outputs)track.outputs=patches;
}
inline void apply(jaras::Song &song,const Destination &d) {
    const auto first=trackTree::index(song,d.source);if(first==song.tracks.size())return;
    const auto last=trackTree::end(song,first);
    std::set<ID> movingIDs,adoptedIDs;
    for(size_t i=first;i<last;++i)movingIDs.insert(song.tracks[i].id);
    for(const auto &id:d.adopt){const auto i=trackTree::index(song,id);for(size_t j=i;j<trackTree::end(song,i);++j)adoptedIDs.insert(song.tracks[j].id);}
    std::vector<jaras::Track> moving,adopted,remaining;
    for(const auto &track:song.tracks) {
        if(movingIDs.count(track.id))moving.push_back(track);
        else if(adoptedIDs.count(track.id))adopted.push_back(track);
        else remaining.push_back(track);
    }
    setParent(moving.front(),d.parent);
    for(auto &track:adopted)if(std::find(d.adopt.begin(),d.adopt.end(),track.id)!=d.adopt.end())setParent(track,d.source);
    moving.insert(moving.begin()+1,adopted.begin(),adopted.end());
    auto at=std::find_if(remaining.begin(),remaining.end(),[&](const auto &t){return t.id==d.before;});
    remaining.insert(at,moving.begin(),moving.end());song.tracks=std::move(remaining);
}
}
