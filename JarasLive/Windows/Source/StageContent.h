#pragma once
#include "Session.h"
#include "StageState.h"
namespace catlive {
struct StageContent {
    var payload = object();
    File media;
    static StageContent make(const Session &session, const StageState &stage, int index) {
        StageContent result;
        auto &out=result.payload;
        const auto settings=stage.settings(index);
        const auto &transport=session.transport();
        const double position=transport.playing?transport.position:transport.editPosition;
        const bool preview=stage.preview && flag(settings,"previewEnabled",true) && !flag(settings,"ignorePreview");
        put(out,"index",index);put(out,"settings",settings);put(out,"preview",preview);
        put(out,"timer",stage.timeText(true));put(out,"expired",stage.seconds()<0);
        put(out,"localTime",Time::getCurrentTime().formatted("%H:%M:%S"));
        put(out,"mediaStretch",flag(settings,"mediaStretch"));
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
            if(media && (!preview||flag(settings,"clearMode"))) {
                result.media=ProjectCodec::resolveMedia(session.mediaDirectory,media->audioFile->path,false);
                put(out,"mediaID",text(media->id));put(out,"imageID",text(media->id));put(out,"mediaName",text(media->name));
                put(out,"mediaKind",result.media.hasFileExtension("png;jpg;jpeg;gif;bmp;webp;heic")?"image":"video");
                put(out,"mediaTime",std::max(0.,media->sourceOffset+(mediaPosition-media->startTime)*media->playbackRate));
                put(out,"mediaRate",transport.playing?media->playbackRate:0);
            }
            std::vector<const jaras::Part*> regions;
            const auto &setlist=session.project().regionSetlist;
            const jaras::RegionPlaylist *playlist=nullptr;
            if(setlist)for(const auto &entry:setlist->playlists)if(entry.id==setlist->selectedId && entry.songId==song->id)playlist=&entry;
            if(playlist) {for(const auto &id:playlist->regionIds)for(const auto &part:song->parts)if(part.id==id)regions.push_back(&part);}
            if(!playlist){for(const auto &part:song->parts)if(!part.parentRegionID)regions.push_back(&part);
                std::stable_sort(regions.begin(),regions.end(),[](auto a,auto b){return a->startTime<b->startTime;});}
            auto block=[](String label,unsigned colour){auto v=object();put(v,"name",label);put(v,"color",(int64)colour);put(v,"duration",0.);put(v,"songs",Array<var>{});return v;};
            Array<var> all;all.add(block("",0xffea00));
            auto appendBlocks=[&](std::optional<ID> before){if(setlist&&setlist->blocks)for(const auto &b:*setlist->blocks)
                if(b.songId==song->id&&b.playlistId==(playlist?std::optional<ID>(playlist->id):std::nullopt)&&b.beforeRegionId==before)all.add(block(text(b.name),b.color));};
            for(const auto *part:regions){
                appendBlocks(part->id);auto &b=all.getReference(all.size()-1);auto rows=list(get(b,"songs"));auto row=object();
                const auto duration=part->endTime-part->startTime;
                put(row,"name",part->uppercaseName.value_or(true)?unicodeCase(text(part->name)):text(part->name));
                put(row,"duration",duration);
                put(row,"color",current==part?get(settings,"highlightColor",0x00ff55):transport.queuedRegionId==part->id?get(settings,"queueNameColor",0xffea00):var((int64)part->color.value_or((unsigned)(int64)get(b,"color"))));
                rows.add(row);put(b,"songs",rows);put(b,"duration",num(b,"duration")+duration);
            }
            appendBlocks({});Array<var> nonempty;
            for(const auto &b:all)if(str(b,"name").isNotEmpty()||!list(get(b,"songs")).isEmpty())nonempty.add(b);
            for(int i=stage.previewPage*4;i<std::min(nonempty.size(),stage.previewPage*4+4);++i)blocks.add(nonempty[i]);
        }
        put(out,"text",lyrics);put(out,"chords",chords);put(out,"song",name);put(out,"queued",queued);put(out,"progress",progress);put(out,"blocks",blocks);
        return result;
    }
};
}
