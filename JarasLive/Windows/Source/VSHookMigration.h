#pragma once
#include "ProjectMigration.h"
namespace catlive::migration {
// Kept in step with Application/Project/VSHookProjectMigration.swift.
// REAPER marker IDs and region IDs are separate namespaces.
struct VSHookMigration {
    using State = std::map<String, std::map<String, String>>;
    State state;
    std::map<String, ID> regions, tracks;
    struct SourceMarker { String number; jaras::TimelineMarker marker; };
    std::vector<SourceMarker> markers;
    String value(const String &section, const String &key) const {
        auto s = state.find(section); if (s == state.end()) return {};
        auto v = s->second.find(key); return v == s->second.end() ? String{} : v->second;
    }
    bool technical(const std::string &name) const {
        auto n = text(name).trim(); return n.startsWithChar('*') || n.startsWithChar('$') || (!state.empty() && n.startsWithChar('!'));
    }
    static String uppercase(const String &value) {
        const auto *source = value.toWideCharPointer();
        const int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, source, -1, nullptr, 0, nullptr, nullptr, 0);
        if (count <= 0) return value.toUpperCase();
        std::vector<wchar_t> output((size_t)count);
        if (!LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, source, -1, output.data(), count, nullptr, nullptr, 0)) return value.toUpperCase();
        return String(output.data());
    }
    static String unescape(const String &text) {
        String out;
        for (int i=0; i<text.length(); ++i) {
            if (text[i]=='\\' && i+1<text.length()) {
                const auto c=text[i+1];
                if(c=='p'||c=='t'||c=='n'||c=='\\') {out+=String::charToString(c=='p'?'|':c=='t'?'\t':c=='n'?'\n':'\\');++i;continue;}
            }
            out+=String::charToString(text[i]);
        }
        return out;
    }
    static std::vector<StringArray> rows(const String &text) {
        std::vector<StringArray> result;
        for (auto line : StringArray::fromLines(text)) result.push_back(StringArray::fromTokens(line, "\t", ""));
        return result;
    }
    const jaras::Part *markerPart(const SourceMarker &source, const jaras::Song &song) const {
        if (technical(source.marker.name)) return nullptr;
        for (const auto &p:song.parts) if(p.parentRegionID && std::abs(p.startTime-source.marker.position)<=1e-6) return &p;
        return nullptr;
    }
    static void sortParts(jaras::Song &song) {
        std::stable_sort(song.parts.begin(),song.parts.end(),[](const auto &a,const auto &b){return a.startTime==b.startTime?a.endTime>b.endTime:a.startTime<b.startTime;});
    }
    static std::vector<jaras::TimelineMarker> uniqueFlags(std::vector<jaras::TimelineMarker> values) {
        std::stable_sort(values.begin(),values.end(),[](const auto &a,const auto &b){return a.position<b.position;});
        values.erase(std::unique(values.begin(),values.end(),[](const auto &a,const auto &b){return std::abs(a.position-b.position)<=1e-6;}),values.end());
        return values;
    }
    void convertSpecial(jaras::Song &song, StringArray &warnings) const {
        sortParts(song);
        std::vector<jaras::Part> accepted;
        for(auto part:song.parts) {
            for(const auto &parent:accepted) if(!parent.parentRegionID && parent.startTime<=part.startTime && parent.endTime>=part.endTime){part.parentRegionID=parent.id;break;}
            std::vector<std::pair<double,int>> edges;
            for(const auto &p:accepted){edges.emplace_back(p.startTime,1);edges.emplace_back(p.endTime,-1);}
            edges.emplace_back(part.startTime,1);edges.emplace_back(part.endTime,-1);std::sort(edges.begin(),edges.end());
            int depth=0,maximum=0;for(const auto &edge:edges){depth+=edge.second;maximum=std::max(maximum,depth);}
            if(maximum<=2) accepted.push_back(part);
            else {
                warnings.addIfNotAlreadyThere("Regions beyond the two supported overlap lanes were converted to start and end markers.");
                for(int end=0;end<2;++end){jaras::TimelineMarker m;m.id=uuid();m.name=utf8((text(part.name)+(end?" end":"")).substring(0,256));m.position=end?part.endTime:part.startTime;m.color=part.color.value_or(0xc7ab40);song.markers->push_back(m);}
            }
        }
        song.parts=std::move(accepted);
        std::vector<jaras::TimelineMarker> technicalFlags, ordinary;
        for(auto marker:*song.markers) {
            if(technical(marker.name)) {
                double distance=.00050001;
                for(const auto &p:song.parts)if(std::abs(p.endTime-marker.position)<distance){distance=std::abs(p.endTime-marker.position);marker.position=p.endTime;}
                technicalFlags.push_back(marker);
            } else ordinary.push_back(marker);
        }
        ordinary=uniqueFlags(std::move(ordinary));
        std::vector<jaras::Part> roots;for(const auto &p:song.parts)if(!p.parentRegionID)roots.push_back(p);
        std::set<ID> consumed;std::vector<jaras::TimelineMarker> linked;
        for(const auto &root:roots) {
            std::vector<jaras::TimelineMarker> inside;
            for(const auto &m:ordinary) {
                if(!state.empty() && !text(root.name).trim().startsWith("--"))continue;
                if(m.position<root.startTime || m.position>=root.endTime)continue;
                const jaras::Part *owner=nullptr;
                for(const auto &p:roots)if(m.position>=p.startTime && m.position<p.endTime && (!owner || p.endTime-p.startTime<owner->endTime-owner->startTime))owner=&p;
                if(owner && owner->id==root.id)inside.push_back(m);
            }
            std::vector<jaras::Part> children;for(const auto &p:song.parts)if(p.parentRegionID==root.id)children.push_back(p);
            for(const auto &m:inside) {
                consumed.insert(m.id);
                if(std::any_of(children.begin(),children.end(),[&](const auto &p){return std::abs(p.startTime-m.position)<=1e-6;}))continue;
                double end=root.endTime;
                for(const auto &next:inside)if(next.position>m.position+1e-6)end=std::min(end,next.position);
                for(const auto &p:children){if(p.startTime>m.position+1e-6)end=std::min(end,p.startTime);if(p.startTime<m.position&&p.endTime>m.position)end=std::min(end,p.endTime);}
                if(end>m.position){jaras::Part p;p.id=uuid();p.name=m.name;p.startTime=m.position;p.endTime=end;p.color=m.color;p.parentRegionID=root.id;song.parts.push_back(p);}
            }
            for(const auto &child:children)for(const auto &m:inside)if(m.position>child.startTime+1e-6&&m.position<child.endTime){for(auto &p:song.parts)if(p.id==child.id)p.endTime=m.position;break;}
            for(const auto &p:song.parts)if(p.parentRegionID==root.id){jaras::TimelineMarker m;m.id=uuid();m.name=p.name;m.position=p.startTime;m.color=p.color.value_or(0xc7ab40);m.unifiedRegionID=root.id;m.sourceRegionID=p.id;linked.push_back(m);}
        }
        for(const auto &m:ordinary)if(!consumed.count(m.id))linked.push_back(m);
        auto flags=uniqueFlags(std::move(linked));
        for(auto m:technicalFlags) {
            auto label=text(m.name).trim();
            if(label.startsWithChar('*')||label.startsWithChar('$')) {
                bool slot=false;for(int i=1;i<=4;++i)slot|=label.startsWith("*"+String(i));
                auto title=label.substring(slot?2:1).trim();m.name=utf8(title.isEmpty()?"Trecho":title);
                const bool inside=std::any_of(song.parts.begin(),song.parts.end(),[&](const auto &p){return m.position>=p.startTime&&m.position<=p.endTime;});
                if(inside){m.section=true;m.loopSection=label.startsWithChar('*');}
                else warnings.addIfNotAlreadyThere("VS Hook: um marcador de trecho fora de uma música foi mantido como marcador comum.");
            }
            auto same=std::find_if(flags.begin(),flags.end(),[&](const auto &p){return std::abs(p.position-m.position)<=1e-6;});
            if(same!=flags.end()){if(m.section.value_or(false)){same->section=true;if(m.loopSection.value_or(false))same->loopSection=true;}}
            else flags.push_back(m);
        }
        for(auto &m:flags)if(!m.unifiedRegionID)m.name=utf8((m.section.value_or(false)?uppercase(text(m.name)):text(m.name)).substring(0,256));
        song.markers=std::move(flags);sortParts(song);
    }
    static unsigned blockColor(String name, int number) {
        const std::vector<String> names={"yellow","green","blue","purple","red","cyan","pink","olive"};
        const unsigned palette[]={0xffbd1f,0x2ebd5c,0x3385ff,0x8f57f0,0xff6147,0x1ab3c7,0xf261b8,0x94b32e};
        for(size_t i=0;i<names.size();++i)if(name==names[i])return palette[i];
        if(name=="orange")return 0xf58f29;if(name=="white"||name=="none")return 0x22262b;
        return palette[(std::max<int64>(1,std::abs((int64)number))-1)%8];
    }
    void apply(jaras::Project &project,StringArray &warnings) const {
        auto &song=project.songs.front();std::set<ID> groups,parents;
        for(const auto &t:song.tracks)if(t.parentTrackID)groups.insert(*t.parentTrackID);
        for(const auto &p:song.parts)if(p.parentRegionID)parents.insert(*p.parentRegionID);
        std::vector<ID> pitchTracks,pitchGroups;
        for(const auto &t:song.tracks)if(jaras::fixedTrackName(t.role).empty()&&text(t.name).trim().startsWithChar('#'))(groups.count(t.id)?pitchGroups:pitchTracks).push_back(t.id);
        if(state.empty()&&pitchTracks.empty()&&pitchGroups.empty()&&!std::any_of(markers.begin(),markers.end(),[](const auto &m){return text(m.marker.name).trim().startsWithChar('*');}))return;
        for(const auto &t:song.tracks)if(t.parentTrackID&&std::find(pitchGroups.begin(),pitchGroups.end(),*t.parentTrackID)!=pitchGroups.end()&&text(t.name).trim().startsWithChar('#'))warnings.addIfNotAlreadyThere("VS Hook: uma pasta e uma pista filha estão marcadas com #. O CatLive aplica a transposição uma única vez; revise essa seleção.");
        std::map<ID,String> numbers;for(const auto &r:regions)numbers[r.second]=r.first;
        for(const auto &m:markers)if(auto p=markerPart(m,song);p&&!numbers.count(p->id))numbers[p->id]=m.number;
        std::map<String,int> offsets;
        for(auto field:StringArray::fromTokens(value("CHATGPT_REGION_PLAYLIST","TUNER_OFFSETS_V1"),"|","")){auto pair=StringArray::fromTokens(field,"=","");if(pair.size()==2)offsets[pair[0].trim()]=jlimit(-12,12,pair[1].getIntValue());}
        for(auto &p:song.parts){p.pitchTrackIDs=pitchTracks;p.pitchGroupIDs=pitchGroups;if(!parents.count(p.id)&&numbers.count(p.id))p.pitchSemitones=offsets[numbers[p.id]];auto name=text(p.name).trim();if(name.startsWith("--")&&name.substring(2).trim().isNotEmpty())p.name=utf8(name.substring(2).trim());}
        for(auto &m:*song.markers)if(m.sourceRegionID)for(const auto &p:song.parts)if(p.id==*m.sourceRegionID)m.name=p.name;
        const auto loopRows=rows(value("VS_HOOK_MULTILOOPS","STATE_V2")+"\n"+value("VS_HOOK_MULTILOOPS","MS_STATE_V1"));
        std::map<String,StringArray> enabled;for(const auto &r:loopRows)if(r.size()>=6&&r[0]=="E")enabled[unescape(r[1])]=r;
        for(auto &p:song.parts)if(!parents.count(p.id)&&numbers.count(p.id))for(int slot=1;slot<=4;++slot) {
            std::vector<jaras::TimelineMarker> points;for(const auto &m:markers)if(text(m.marker.name).trim().startsWith("*"+String(slot))&&m.marker.position>=p.startTime&&m.marker.position<=p.endTime+.0005)points.push_back(m.marker);
            std::stable_sort(points.begin(),points.end(),[](const auto &a,const auto &b){return a.position<b.position;});
            if(points.size()<2||points[1].position<=points[0].position+.0005){if(!points.empty())warnings.addIfNotAlreadyThere("VS Hook: um par de multiloop incompleto foi mantido como marcador; revise os pontos *1 a *4.");continue;}
            std::vector<ID> anchors;for(int i=0;i<2;++i){const double at=std::abs(points[i].position-p.endTime)<=.0005?p.endTime:points[i].position;for(const auto &m:*song.markers)if(!m.tempoBPM&&std::abs(m.position-at)<=1e-6){anchors.push_back(m.id);break;}}
            if(anchors.size()!=2||anchors[0]==anchors[1])continue;
            jaras::MultiLoop loop;loop.id=uuid();loop.name="*"+std::to_string(slot);loop.marker1=anchors[0];loop.marker2=anchors[1];
            const auto row=enabled[numbers[p.id]];const int li[]={2,3,6,7},mi[]={4,5,8,9};loop.enabled=row[li[slot-1]]=="1";loop.mixerEnabled=row[mi[slot-1]]=="1";
            std::map<ID,jaras::MultiLoopTrack> rules;
            for(const auto &r:loopRows)if(r.size()>=6&&unescape(r[1])==numbers[p.id]&&r[2].getIntValue()==slot){
                if(r[0]=="T"){loop.fadeSeconds=jlimit(1.,5.,r[3].getDoubleValue());continue;}
                auto track=tracks.find(unescape(r[3]).toUpperCase());if(track==tracks.end())continue;
                auto [it,inserted]=rules.emplace(track->second,jaras::MultiLoopTrack{track->second,0});auto &rule=it->second;
                if(r[0]=="P"){rule.mute=r[4]=="1";rule.solo=r[5]=="1";if(rule.mute){rule.solo=false;rule.autoFader=false;}}
                else if(r[0]=="F"){rule.autoFader=r[4]=="1"||r[5]=="1";if(rule.autoFader)rule.mute=false;}
                else if(r[0]=="L"){double db=r[4].getDoubleValue();rule.gain=db<=-89.999?0:std::pow(10.,std::min(12.,db)/20.);if(db>12)warnings.addIfNotAlreadyThere("VS Hook: limites de Auto Fader acima de +12 dB foram ajustados ao máximo do CatLive.");}
            }
            for(const auto &t:song.tracks)if(rules.count(t.id))loop.tracks.push_back(rules[t.id]);p.multiLoops.push_back(loop);
        }
        auto setlist=project.regionSetlist.value_or(jaras::RegionSetlist{});String name;bool active=false;std::vector<StringArray> entries;
        auto findPart=[&](const ID &id)->const jaras::Part*{for(const auto &p:song.parts)if(p.id==id)return &p;return nullptr;};
        auto resolve=[&](const StringArray &r)->const jaras::Part* {
            const bool marker=r[7]=="marker"||(r[7].isEmpty()&&r[9]=="1");const auto key=marker&&r[10].isNotEmpty()?r[10]:r[2];
            if(marker){for(const auto &m:markers)if(m.number==key)if(auto p=markerPart(m,song))return p;}
            else if(auto it=regions.find(key);it!=regions.end())if(auto p=findPart(it->second))return p;
            if(key.isEmpty())for(const auto &p:song.parts)if(std::abs(p.startTime-r[3].getDoubleValue())<.0005&&std::abs(p.endTime-r[4].getDoubleValue())<.0005)return &p;
            return nullptr;
        };
        auto finish=[&]{
            if(!active)return;jaras::RegionPlaylist playlist{uuid(),utf8(name),song.id,{}};
            std::vector<std::pair<jaras::SetlistBlock,size_t>> blocks;
            for(const auto &r:entries)if(r.size()>=6){if(r[1]=="block"||r[2].getIntValue()<0){jaras::SetlistBlock b;b.id=uuid();b.songId=song.id;b.playlistId=playlist.id;auto title=unescape(r[5]).trim();b.name=utf8(title.isEmpty()?"Bloco":title);b.color=blockColor(r[6],r[2].getIntValue());b.symbol=r[13]!="1";blocks.emplace_back(b,playlist.regionIds.size());}
                else if(auto p=resolve(r)){auto id=p->parentRegionID.value_or(p->id);if(std::find(playlist.regionIds.begin(),playlist.regionIds.end(),id)==playlist.regionIds.end())playlist.regionIds.push_back(id);}
                else warnings.addIfNotAlreadyThere("VS Hook: músicas removidas do projeto de origem foram ignoradas nos repertórios.");}
            setlist.playlists.push_back(playlist);
            for(auto &b:blocks){if(b.second<playlist.regionIds.size())b.first.beforeRegionId=playlist.regionIds[b.second];if(!setlist.blocks)setlist.blocks.emplace();setlist.blocks->push_back(b.first);}
        };
        for(const auto &r:rows(value("CHATGPT_REGION_PLAYLIST","PLAYLISTS_DB_V3"))){if(r[0]=="PLAYLIST"){finish();entries.clear();active=true;name=unescape(r[1]).trim();if(name.isEmpty())name="Repertório "+String(setlist.playlists.size()+1);}
            else if(r[0]=="END"){finish();active=false;entries.clear();}else if(r[0]=="ITEM"&&active)entries.push_back(r);}
        finish();if(!setlist.playlists.empty()){auto selected=value("CHATGPT_REGION_PLAYLIST","LAST_PLAYLIST_NAME_V1").trim();setlist.selectedId.reset();if(selected.isEmpty())setlist.selectedId=setlist.playlists.front().id;else for(const auto &p:setlist.playlists)if(text(p.name)==selected)setlist.selectedId=p.id;project.regionSetlist=setlist;}
    }
};
}
