#pragma once
#include "Common.h"
namespace catlive {
// Same ordering, block placement and drawer indentation as SetlistShareText.swift.
inline String setlistShareText(const jaras::Song &song,const jaras::RegionSetlist &state,std::optional<ID> id) {
    String title=String::fromUTF8("Todas as regiões");std::vector<jaras::Part> regions;
    if(id){const auto list=std::find_if(state.playlists.begin(),state.playlists.end(),[&](const auto &p){return p.id==id && p.songId==song.id;});if(list==state.playlists.end())return {};
        title=text(list->name);for(const auto &key:list->regionIds)for(const auto &p:song.parts)if(p.id==key && !p.parentRegionID)regions.push_back(p);
    }else{for(const auto &p:song.parts)if(!p.parentRegionID)regions.push_back(p);
        std::sort(regions.begin(),regions.end(),[](const auto &a,const auto &b){return a.startTime==b.startTime?a.id<b.id:a.startTime<b.startTime;});}
    double total=0;for(const auto &p:regions)total+=std::max(0.,p.endTime-p.startTime);
    const auto seconds=(int64)std::min(total,9e15);StringArray lines{title,String::fromUTF8("Duração total: ")+String::formatted("%02lld:%02lld:%02lld",seconds/3600,seconds/60%60,seconds%60),""};
    auto blocks=[&](std::optional<ID> before){if(state.blocks)for(const auto &b:*state.blocks)if(b.songId==song.id && b.playlistId==id && b.beforeRegionId==before && text(b.name).trim().isNotEmpty()){if(lines[lines.size()-1].isNotEmpty())lines.add("");lines.add(text(b.name));}};
    auto name=[](const auto &p){return p.uppercaseName.value_or(true)?text(p.name).toUpperCase():text(p.name);};
    for(size_t i=0;i<regions.size();++i){const auto &p=regions[i];blocks(p.id);lines.add(String::formatted("%02d. ",(int)i+1)+name(p));std::vector<jaras::Part> children;
        for(const auto &child:song.parts)if(child.parentRegionID==p.id)children.push_back(child);
        std::sort(children.begin(),children.end(),[](const auto &a,const auto &b){return a.startTime==b.startTime?a.endTime<b.endTime:a.startTime<b.startTime;});
        for(size_t j=0;j<children.size();++j)lines.add(String::fromUTF8(j+1==children.size()?"    └─ ":"    ├─ ")+name(children[j]));}
    blocks({});if(lines[lines.size()-1].isEmpty())lines.remove(lines.size()-1);return lines.joinIntoString("\n");
}
}
