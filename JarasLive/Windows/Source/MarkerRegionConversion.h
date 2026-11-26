#pragma once
#include "Common.h"
namespace catlive::markerRegions {
constexpr double epsilon = .000001;
struct Plan { jaras::TimelineMarker marker; double end; };
struct Result {
    std::vector<Plan> plans;
    StringArray skipped;
    String message() const {
        auto value=String((int)plans.size())+String::fromUTF8(" marcador(es) convertido(s) em região.");
        return skipped.isEmpty()?value:value+String::fromUTF8("\n\nNão convertidos:\n")+skipped.joinIntoString("\n");
    }
};
inline bool outsideRegions(const jaras::TimelineMarker &marker,const jaras::Song &song) {
    return !marker.tempoBPM && !marker.unifiedRegionID && !marker.sourceRegionID &&
        std::none_of(song.parts.begin(),song.parts.end(),[&](const auto &part){return marker.position>=part.startTime-epsilon && marker.position<part.endTime-epsilon;});
}
inline bool reserved(const jaras::TimelineMarker &marker) {
    auto name=text(marker.name).trim();const auto loop=name.startsWithChar('*')?name.substring(1).getIntValue():0;
    return marker.section.value_or(false)||marker.loopSection.value_or(false)||name.startsWithChar('$')||name.startsWithChar('!')||loop==1||loop==2;
}
inline Result plan(const jaras::Song &song,const ID &markerID={}) {
    Result result;
    auto markers=song.markers.value_or(std::vector<jaras::TimelineMarker>{});
    std::sort(markers.begin(),markers.end(),[](const auto &a,const auto &b){return a.position==b.position?a.id<b.id:a.position<b.position;});
    auto audioEnd=[&](double position)->std::optional<double>{
        std::optional<double> end;
        for(const auto &track:song.tracks)for(const auto &clip:track.clips)
            if(clip.audioFile && !clip.midi && clip.duration>epsilon && std::abs(clip.startTime-position)<=epsilon)
                end=std::max(end.value_or(0),clip.startTime+clip.duration);
        return end;
    };
    auto ordinary=[](const auto &m){return !m.tempoBPM&&!m.unifiedRegionID&&!m.sourceRegionID&&!reserved(m)&&text(m.name).trim().isNotEmpty();};
    for(const auto &marker:markers) {
        if(!markerID.empty() && marker.id!=markerID)continue;
        if(markerID.empty() && (marker.tempoBPM||marker.unifiedRegionID||marker.sourceRegionID))continue;
        auto name=text(marker.name).trim();const char *reason=nullptr;
        if(!outsideRegions(marker,song))reason="Já pertence a uma região ou é um marcador de tempo. Use um marcador comum fora das regiões.";
        else if(reserved(marker))reason="Marcador reservado para Parts/loops ou desativado. Use um marcador comum, sem os prefixos $, !, *1 ou *2.";
        else if(name.isEmpty())reason="O marcador está sem nome. Edite o marcador e dê um nome antes de converter.";
        else if(auto end=audioEnd(marker.position)) {
            double limit=*end;
            for(const auto &region:song.parts)if(region.startTime>marker.position+epsilon)limit=std::min(limit,region.startTime);
            for(const auto &next:markers)if(next.position>marker.position+epsilon && ordinary(next) && audioEnd(next.position))limit=std::min(limit,next.position);
            if(std::any_of(result.plans.begin(),result.plans.end(),[&](const auto &p){return std::abs(p.marker.position-marker.position)<=epsilon;}))
                reason="Outro marcador já será convertido neste ponto. Mova este marcador para o início de outro item de áudio.";
            else if(limit>marker.position+epsilon)result.plans.push_back({marker,limit});
            else reason="Não há duração disponível para a região. Ajuste o áudio ou o início da próxima região.";
        } else reason="Nenhum item de áudio começa neste ponto. Alinhe o marcador ao início de um item de áudio com duração maior que zero.";
        if(reason)result.skipped.add((name.isEmpty()?String("Sem nome"):name)+": "+String::fromUTF8(reason));
    }
    if(result.plans.empty()&&result.skipped.isEmpty())result.skipped.add(String::fromUTF8("Não há marcadores comuns nesta timeline. Crie um marcador no início de um item de áudio, fora das regiões."));
    return result;
}
inline void apply(jaras::Project &project,const ID &songID,const Result &result) {
    for(auto &song:project.songs)if(song.id==songID) {
        std::set<ID> converted;
        for(const auto &plan:result.plans) {
            jaras::Part part;part.id=uuid();part.name=plan.marker.name;part.startTime=plan.marker.position;part.endTime=plan.end;part.color=plan.marker.color;
            song.parts.push_back(part);converted.insert(plan.marker.id);
        }
        if(song.markers)song.markers->erase(std::remove_if(song.markers->begin(),song.markers->end(),[&](const auto &m){return converted.count(m.id);}),song.markers->end());
    }
}
}
