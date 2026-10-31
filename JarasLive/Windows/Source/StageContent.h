#pragma once
#include "ItemTextColors.h"
#include "Session.h"
#include "StageState.h"
namespace catlive {
struct StageContent {
    var payload = object();
    File media;
    Image noticeImage;
    static StageContent make(const Session &session, const StageState &stage, int index) {
        StageContent result;
        auto &out=result.payload;
        const auto settings=stage.settings(index);
        const auto transport=session.presentationTransport();
        const double position=(transport.playing||transport.paused)?transport.position:transport.editPosition;
        const bool preview=stage.preview && flag(settings,"previewEnabled",true) && !flag(settings,"ignorePreview");
        put(out,"index",index);put(out,"settings",settings);put(out,"preview",preview);
        put(out,"timer",stage.timeText(true));put(out,"expired",stage.seconds()<0);
        put(out,"localTime",Time::getCurrentTime().formatted("%H:%M:%S"));
        put(out,"mediaStretch",flag(settings,"mediaStretch"));
        const auto noticeSettings=stage.preferences.value("jaras.notices.appearance",object());
        const bool activeNotice=!preview && stage.noticeActive() && flag(noticeSettings,index==1?"window1":"window2",true);
        auto notice=object();put(notice,"active",activeNotice);
        if(activeNotice) {
            put(notice,"message",stage.noticeText(noticeSettings));
            put(notice,"font",str(noticeSettings,"font","Arial"));
            put(notice,"scale",num(noticeSettings,"scale",100));
            put(notice,"textColor",(int)(StageState::colour(noticeSettings,"text",0xffffff).getARGB()&0xffffff));
            put(notice,"backgroundColor",(int)(StageState::colour(noticeSettings,"background",0).getARGB()&0xffffff));
            put(notice,"flashColor",(int)(StageState::colour(noticeSettings,"flash",0xffdc52).getARGB()&0xffffff));
            put(notice,"elapsed",std::max(0.,StageState::now()-stage.noticeSent));
            if(stage.noticeImage.isValid()) { result.noticeImage=stage.noticeImage;put(notice,"imageID",String(stage.noticeSent,6)); }
        }
        put(out,"notice",notice);
        String name,queued,lyrics,chords;double progress=0;
        Array<var> blocks;
        if(const auto *song=session.song()) {
            const jaras::Part *current=nullptr;
            for(const auto &part:song->parts) {
                if(position>=part.startTime && position<part.endTime && (!current || part.endTime-part.startTime<current->endTime-current->startTime)) current=&part;
                if(transport.queuedRegionId==part.id)queued=text(part.name);
            }
            if(current)name=text(current->name);
            if(queued.isEmpty())for(const auto &entry:session.project().songs)if(entry.id==transport.queue.songId)queued=text(entry.name);
            const jaras::AudioClip *lyric=nullptr,*chord=nullptr,*media=nullptr;
            const double mediaPosition=transport.playing||transport.paused?transport.position:transport.editPosition;
            for(const auto &track:song->tracks) if(!track.mute) {
                const bool target=track.role.id==(index==2?"teleprompt2":"teleprompt");
                const jaras::AudioClip *active=nullptr;
                for(const auto &clip:track.clips) if(!clip.muted) {
                    const bool projection=clip.audioFile && clip.audioFile->path.rfind("Videos/",0)==0;
                    if(target && projection && !media && mediaPosition>=clip.startTime && mediaPosition<clip.startTime+clip.duration)media=&clip;
                    if(!projection && clip.text && position>=clip.startTime && position<clip.startTime+clip.duration && (!active||clip.startTime>active->startTime))active=&clip;
                }
                if(target && !lyric)lyric=active;
                if(track.role.id=="chords" && !chord)chord=active;
            }
            if(lyric)lyrics=text(*lyric->text);if(chord)chords=text(*chord->text);
            const auto *progressClip=str(settings,"progressMode")=="chords"?chord:lyric;
            if(progressClip && progressClip->duration>0 && flag(settings,"progressEnabled"))
                progress=std::round(jlimit(0.,1.,(position-progressClip->startTime)/progressClip->duration)*1000)/1000;
            if(media && !preview) {
                result.media=ProjectCodec::resolveMedia(session.mediaDirectory,media->audioFile->path,false);
                put(out,"mediaID",text(media->id));put(out,"imageID",text(media->id));put(out,"mediaName",text(media->name));
                put(out,"mediaKind",result.media.hasFileExtension("png;jpg;jpeg;gif;bmp;webp;heic")?"image":"video");
                put(out,"mediaTime",std::max(0.,media->sourceOffset+(mediaPosition-media->startTime)*media->playbackRate));
                put(out,"mediaRate",transport.playing?media->playbackRate:0);
            }
            std::vector<std::pair<ID,const jaras::Part*>> roots;
            const auto &setlist=session.project().regionSetlist;
            const jaras::RegionPlaylist *playlist=nullptr;
            if(setlist)for(const auto &entry:setlist->playlists)if(entry.id==setlist->selectedId && entry.songId==song->id)playlist=&entry;
            if(playlist) {for(const auto &id:playlist->regionIds)for(const auto &part:song->parts)if(part.id==playlist->resolvedRegionId(id))roots.push_back({id,&part});}
            if(!playlist){for(const auto &part:song->parts)if(!part.parentRegionID)roots.push_back({part.id,&part});
                std::stable_sort(roots.begin(),roots.end(),[](auto a,auto b){return a.second->startTime<b.second->startTime;});}
            struct PreviewRegion { ID first; const jaras::Part *second; ID playlistEntry; std::vector<ID> anchors; };
            std::vector<PreviewRegion> regions;
            std::map<ID,std::vector<const jaras::Part*>> drawerChildren;
            for(const auto &part:song->parts)if(part.parentRegionID)drawerChildren[*part.parentRegionID].push_back(&part);
            for(auto &family:drawerChildren)std::stable_sort(family.second.begin(),family.second.end(),[](auto a,auto b){return a->startTime<b->startTime;});
            const auto childID=[](ID child,const ID &parent,const ID &occurrence){
                if(parent==occurrence)return child;
                const auto compact=[](const ID &value){ID result;for(char c:value)if(c!='-')result+=c>='a'&&c<='f'?char(c-'a'+'A'):c;return result;};
                const auto c=compact(child),p=compact(parent),o=compact(occurrence);
                const auto valid=[](const ID &v){return v.size()==32&&std::all_of(v.begin(),v.end(),[](char x){return (x>='0'&&x<='9')||(x>='A'&&x<='F');});};
                if(!valid(c)||!valid(p)||!valid(o))return child;
                const auto nibble=[](char x){return x<='9'?x-'0':x-'A'+10;};
                ID result;
                for(size_t i=0;i<32;++i){
                    if(i==8||i==12||i==16||i==20)result+='-';
                    result+="0123456789ABCDEF"[nibble(c[i])^nibble(p[i])^nibble(o[i])];
                }
                return result;
            };
            std::function<void(const jaras::Part*,ID,ID,std::vector<ID>,std::set<ID>)> appendSongs;
            appendSongs=[&](const jaras::Part *part,ID entry,ID root,std::vector<ID> anchors,std::set<ID> visited){
                if(!visited.insert(part->id).second)return;
                const auto nested=drawerChildren.find(part->id);
                if(nested==drawerChildren.end()){regions.push_back({entry,part,root,std::move(anchors)});return;}
                bool first=true;
                for(const auto *child:nested->second){
                    auto childAnchors=first?anchors:std::vector<ID>{};childAnchors.push_back(child->id);
                    appendSongs(child,childID(child->id,part->id,entry),root,std::move(childAnchors),visited);first=false;
                }
            };
            for(const auto &root:roots)appendSongs(root.second,root.first,root.first,{root.first},{});
            auto block=[&](ID id,String label,unsigned colour){auto v=object();put(v,"id",text(id));put(v,"name",label);put(v,"nameColor",(int)(stage.preferences.colour("jaras.setlist.blockTextColor",0x69ed91).getARGB()&0xffffff));put(v,"color",(int64)colour);put(v,"duration",0.);put(v,"songs",Array<var>{});put(v,"rows",Array<var>{});return v;};
            Array<var> all;all.add(block(song->id,"",0xffea00));
            auto appendBlocks=[&](std::optional<ID> before){if(setlist&&setlist->blocks)for(const auto &b:*setlist->blocks)
                if(b.songId==song->id&&b.playlistId==(playlist?std::optional<ID>(playlist->id):std::nullopt)&&b.beforeRegionId==before)all.add(block(b.id,text(b.name),b.color));};
            std::set<ID> played;
            if(setlist && setlist->liveEnabled.value_or(false) && setlist->playedLiveRegionIDs)
                played.insert(setlist->playedLiveRegionIDs->begin(),setlist->playedLiveRegionIDs->end());
            // The wrapper represents all current children, just like the setlist.
            std::map<ID,std::vector<ID>> children;
            for(const auto &part:song->parts)if(part.parentRegionID)children[*part.parentRegionID].push_back(part.id);
            for(const auto &family:children){
                played.erase(family.first);
                if(std::all_of(family.second.begin(),family.second.end(),[&](const auto &id){return played.count(id)>0;}))played.insert(family.first);
            }
            std::optional<ID> playingEntry,queuedEntry,queuedOwner;
            for(const auto &entry:regions){
                if(entry.second==current&&(!playingEntry||transport.playlistEntryId==entry.playlistEntry))playingEntry=entry.first;
                if(transport.queuedRegionId&&(transport.queuedRegionId==entry.second->id||transport.queuedRegionId==entry.second->parentRegionID)&&
                    (!queuedEntry||(transport.queuedPlaylistEntryId==entry.playlistEntry&&queuedOwner!=entry.playlistEntry))){
                    queuedEntry=entry.first;queuedOwner=entry.playlistEntry;
                }
            }
            const auto *owner=current;
            for(const auto &part:song->parts)if(transport.regionId==part.id)owner=&part;
            const double playbackEnd=transport.ignoreNextEnd.value_or(owner?owner->endTime:song->duration);
            const double queueProgress=jlimit(0.,1.,(playbackEnd-transport.position)/std::max(.001,playbackEnd-transport.queueStartedAt));
            for(const auto &entry:regions){
                const auto *part=entry.second;
                for(const auto &anchor:entry.anchors)appendBlocks(anchor);auto &b=all.getReference(all.size()-1);auto rows=list(get(b,"songs"));auto row=object();
                const auto duration=part->endTime-part->startTime;
                put(row,"id",text(entry.first));
                put(row,"name",part->uppercaseName.value_or(true)?unicodeCase(text(part->name)):text(part->name));
                put(row,"duration",duration);
                const bool active=(transport.playing||transport.paused)&&playingEntry==entry.first;
                const bool waiting=(transport.playing||transport.paused)&&queuedEntry==entry.first;
                put(row,"liveExecuted",played.count(part->id)>0);put(row,"playing",active);put(row,"queued",waiting);
                const double regionEnd=transport.ignoreNextEnd.value_or(part->endTime);
                put(row,"playbackProgress",active?jlimit(0.,1.,(transport.position-part->startTime)/std::max(.001,regionEnd-part->startTime)):waiting?queueProgress:0.);
                put(row,"color",(playingEntry==entry.first)?get(settings,"highlightColor",0x00ff55):(queuedEntry==entry.first)?get(settings,"queueNameColor",0xffea00):var((int64)part->color.value_or((unsigned)(int64)get(b,"color"))));
                rows.add(row);put(b,"songs",rows);put(b,"rows",rows);put(b,"duration",num(b,"duration")+duration);
            }
            appendBlocks({});Array<var> nonempty;
            for(const auto &b:all)if(str(b,"name").isNotEmpty()||!list(get(b,"songs")).isEmpty())nonempty.add(b);
            for(int i=stage.previewPage*4;i<std::min(nonempty.size(),stage.previewPage*4+4);++i)blocks.add(nonempty[i]);
        }
        put(out,"text",ItemTextColors::plain(lyrics));put(out,"chords",ItemTextColors::plain(chords));put(out,"textStyled",lyrics);put(out,"chordsStyled",chords);put(out,"song",name);put(out,"queued",queued);put(out,"progress",progress);put(out,"blocks",blocks);
        return result;
    }
};
}
