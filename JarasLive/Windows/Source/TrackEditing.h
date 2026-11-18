#pragma once
#include "TrackTree.h"
#include "TrackDrop.h"
#include "ProjectCodec.h"
#include "TrackDuplication.h"
namespace catlive::trackEditing {
// The row action groups all roots below the clicked root; nested trees remain intact.
inline bool canCreateGroup(const jaras::Song &song, const ID &id) {
    const auto first = trackTree::index(song, id);
    if (first == song.tracks.size()) return false;
    const auto &parent = song.tracks[first];
    if (parent.parentTrackID || parent.stereoLinkPartner || parent.role.id == "vinhetas" || !jaras::fixedTrackName(parent.role).empty()) return false;
    return std::any_of(song.tracks.begin() + first + 1, song.tracks.end(), [](const auto &track) {
        return !track.parentTrackID && track.role.id != "vinhetas" && jaras::fixedTrackName(track.role).empty();
    });
}
inline void createGroup(jaras::Song &song, const ID &id) {
    if (!canCreateGroup(song, id)) return;
    const auto first = trackTree::index(song, id);
    for (size_t i = first + 1; i < song.tracks.size(); ++i) {
        auto &track = song.tracks[i];
        if (!track.parentTrackID && track.role.id != "vinhetas" && jaras::fixedTrackName(track.role).empty())
            trackDrop::setParent(track, id);
    }
}
inline bool canCreateGroup(const jaras::Song &song, const ID &id, const std::set<ID> &selection) {
    const auto at=trackTree::index(song,id);if(at==song.tracks.size()||!selection.count(id))return false;
    const auto &parent=song.tracks[at];
    if(!jaras::fixedTrackName(parent.role).empty()||parent.role.id=="vinhetas"||parent.stereoLinkPartner)return false;
    for(const auto &track:song.tracks)if(track.id!=id&&selection.count(track.id)&&jaras::fixedTrackName(track.role).empty()&&track.role.id!="vinhetas"&&(!track.stereoLinkPartner||selection.count(*track.stereoLinkPartner))) {
        bool ancestor=false;auto next=parent.parentTrackID;std::set<ID> seen;
        while(next&&seen.insert(*next).second){if(*next==track.id){ancestor=true;break;}auto i=trackTree::index(song,*next);if(i==song.tracks.size())break;next=song.tracks[i].parentTrackID;}
        if(!ancestor)return true;
    }
    return false;
}
inline void createGroup(jaras::Song &song, const ID &id, const std::set<ID> &selection) {
    if(!canCreateGroup(song,id,selection))return;
    std::set<ID> roots,moving;
    for(size_t i=0;i<song.tracks.size();++i){const auto &t=song.tracks[i];
        if(t.id==id||!selection.count(t.id)||!jaras::fixedTrackName(t.role).empty()||t.role.id=="vinhetas"||(t.stereoLinkPartner&&!selection.count(*t.stereoLinkPartner)))continue;
        const auto end=trackTree::end(song,i);bool containsParent=false;for(size_t n=i;n<end;++n)containsParent|=song.tracks[n].id==id;
        if(containsParent)continue;roots.insert(t.id);for(size_t n=i;n<end;++n)moving.insert(song.tracks[n].id);
    }
    std::vector<jaras::Track> members,remaining;
    for(auto track:song.tracks){if(moving.count(track.id)){if(roots.count(track.id)&&(!track.parentTrackID||!moving.count(*track.parentTrackID)))trackDrop::setParent(track,id);members.push_back(std::move(track));}else remaining.push_back(std::move(track));}
    auto parent=std::find_if(remaining.begin(),remaining.end(),[&](const auto &t){return t.id==id;});
    remaining.insert(parent+1,members.begin(),members.end());song.tracks=std::move(remaining);
}
inline bool linkable(const jaras::Song &song, const std::set<ID> &ids) {
    if(ids.size()!=2)return false;
    std::vector<size_t> selected;
    for(size_t i=0;i<song.tracks.size();++i)if(ids.count(song.tracks[i].id)) {
        const auto &track=song.tracks[i];
        if(!jaras::fixedTrackName(track.role).empty() || track.stereoLinkPartner || trackTree::end(song,i)>i+1)return false;
        selected.push_back(i);
    }
    return selected.size()==2 && selected[1]==selected[0]+1;
}
inline constexpr const char *originalKeys[]{"name","color","volume","pan","inputPatch","output","patch","secondaryPatch","outputs","routing"};
inline void link(jaras::Project &project, const ID &songID, const std::set<ID> &ids, int firstInput, unsigned colour) {
    auto song=std::find_if(project.songs.begin(),project.songs.end(),[&](const auto &s){return s.id==songID;});
    if(song==project.songs.end() || !linkable(*song,ids) || firstInput<1 || firstInput>1023)
        throw std::runtime_error("Selecione duas pistas de áudio vizinhas e sem vínculo.");
    const auto encoded=ProjectCodec::encode(project);
    std::map<ID,var> originals;
    for(auto s:list(get(encoded,"songs")))for(auto track:list(get(s,"tracks")))if(ids.count(utf8(str(track,"id")))) {
        auto original=object();for(auto key:originalKeys)if(!get(track,Identifier(key)).isVoid())put(original,Identifier(key),get(track,Identifier(key)).clone());
        originals[utf8(str(track,"id"))]=original;
    }
    std::vector<size_t> selected;
    for(size_t i=0;i<song->tracks.size();++i)if(ids.count(song->tracks[i].id))selected.push_back(i);
    const double volume=song->tracks[selected[0]].volume;
    for(int side=0;side<2;++side) {
        auto &track=song->tracks[selected[(size_t)side]];
        const ID partner=song->tracks[selected[(size_t)(1-side)]].id;
        auto data=object();put(data,"partner",text(partner));put(data,"left",side==0);put(data,"original",originals.at(track.id));
        track.stereoLinkJSON=utf8(JSON::toString(data,true));track.stereoLinkPartner=partner;track.stereoLinkLeft=side==0;
        track.name=(side==0?"L - ":"R - ")+track.name;track.color=colour;track.volume=volume;track.pan=side==0?-1:1;
        track.inputPatch=jaras::OutputPatch{firstInput+side,1};
    }
}
inline void unlink(jaras::Project &project, const ID &id) {
    std::set<ID> targets;
    for(const auto &song:project.songs)for(const auto &track:song.tracks)if(track.id==id && track.stereoLinkPartner) {
        targets.insert(id);
        for(const auto &partner:song.tracks)if(partner.id==*track.stereoLinkPartner && partner.stereoLinkPartner==id)targets.insert(partner.id);
    }
    if(targets.empty())return;
    auto encoded=ProjectCodec::encode(project);
    for(auto song:list(get(encoded,"songs")))for(auto track:list(get(song,"tracks")))if(targets.count(utf8(str(track,"id")))) {
        const auto original=get(get(track,"stereoLink"),"original");
        if(!original.isObject())throw std::runtime_error("Os dados originais deste vínculo não foram encontrados.");
        for(auto key:originalKeys) {
            const auto value=get(original,Identifier(key));
            if(value.isVoid()){if(auto *object=track.getDynamicObject())object->removeProperty(Identifier(key));}else put(track,Identifier(key),value.clone());
        }
        if(auto *object=track.getDynamicObject())object->removeProperty("stereoLink");
    }
    project=ProjectCodec::decode(encoded);
}
inline void ungroup(jaras::Song &song,const ID &id) {
    const auto at=trackTree::index(song,id);if(at==song.tracks.size())return;
    const auto parent=song.tracks[at].parentTrackID;
    for(auto &track:song.tracks)if(track.parentTrackID==id){track.parentTrackID=parent;trackTree::resetGroupOutput(track);}
}
inline void removeFromGroup(jaras::Song &song,const ID &id) {
    const auto at=trackTree::index(song,id);if(at==song.tracks.size() || !song.tracks[at].parentTrackID)return;
    const auto parent=trackTree::index(song,*song.tracks[at].parentTrackID);if(parent==song.tracks.size())return;
    const auto last=trackTree::end(song,at),after=trackTree::end(song,parent);
    std::vector<jaras::Track> moving(song.tracks.begin()+at,song.tracks.begin()+last);
    moving.front().parentTrackID=song.tracks[parent].parentTrackID;trackTree::resetGroupOutput(moving.front());
    song.tracks.erase(song.tracks.begin()+at,song.tracks.begin()+last);
    song.tracks.insert(song.tracks.begin()+after-(last-at),moving.begin(),moving.end());
}
}
