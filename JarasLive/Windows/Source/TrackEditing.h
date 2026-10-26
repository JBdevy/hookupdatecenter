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
