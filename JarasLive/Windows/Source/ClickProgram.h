#pragma once
#include "Common.h"
#include "ClipEditing.h"
#include "../../Core/Transport/PlaybackScope.hpp"
namespace catlive {
struct ClickProgram {
    struct ItemGate { std::optional<double> playbackStart; std::uint32_t owner=0; int rate=1; };
    struct Section {
        double start=0,end=0,origin=0,bpm=120; int beats=4,unit=4,rate=1;
        // Prepared on control; the callback only checks overlapping item gates.
        std::vector<ItemGate> items;
    };
    struct Sample {std::vector<float> data;double rate=48000;};
    std::vector<Section>sections;Sample a,b;
    static std::vector<Section> tempo(const jaras::Song &song){
        std::vector<Section> result;Section current{0,song.duration,0,song.bpm,song.beatsPerBar,song.beatUnit};
        auto markers=song.markers.value_or(std::vector<jaras::TimelineMarker>{});
        std::stable_sort(markers.begin(),markers.end(),[](const auto &a,const auto &b){return a.position==b.position?a.id<b.id:a.position<b.position;});
        for(const auto &marker:markers)if(marker.tempoBPM&&marker.position<=song.duration){
            if(marker.position>current.start){current.end=marker.position;result.push_back(current);}
            current={marker.position,song.duration,marker.position,*marker.tempoBPM,marker.tempoBeats.value_or(4),marker.tempoUnit.value_or(4)};
        }
        if(current.end>current.start)result.push_back(current);return result;
    }
    void prepare(const jaras::Song &song,const jaras::Track *track=nullptr){
        sections.clear();auto timing=tempo(song);
        if(!track){sections=timing;return;}
        std::vector<double> edges;
        for(const auto &clip:track->clips)if(!clip.muted&&!clip.audioFile&&clip.duration>0){edges.push_back(clip.startTime);edges.push_back(clip.startTime+clip.duration);}
        std::sort(edges.begin(),edges.end());edges.erase(std::unique(edges.begin(),edges.end()),edges.end());
        for(size_t i=1;i<edges.size();++i){
            const double start=edges[i-1],end=edges[i]; int rate=0;
            std::vector<ItemGate> items;
            for(const auto &clip:track->clips) if(!clip.muted&&!clip.audioFile&&clip.startTime<end&&clip.startTime+clip.duration>start) {
                const int itemRate=clip.clickDouble.value_or(false)?2:1;
                rate=std::max(rate,itemRate);
                jaras::AudioClip owned;owned.startTime=clip.startTime;owned.regionOwnerID=clip.regionOwnerID;
                if (!owned.regionOwnerID) if (const auto *region = clipEditing::generatedClickRegion(song,clip)) owned.regionOwnerID=region->id;
                items.push_back({jaras::playbackItemStart(song,owned),jaras::playbackOwnerIndex(song,owned.regionOwnerID),itemRate});
            }
            if(!rate)continue;
            for(auto section:timing)if(section.end>start&&section.start<end){
                section.start=std::max(start,section.start);section.end=std::min(end,section.end);
                section.bpm*=rate;section.beats*=rate;section.rate=rate;section.items=items;sections.push_back(std::move(section));
            }
        }
    }

    static Sample decode(std::unique_ptr<AudioFormatReader> reader){
        if(!reader||reader->sampleRate<8000||reader->lengthInSamples<=0||reader->lengthInSamples>reader->sampleRate*30)throw std::runtime_error("O som de click deve ser um arquivo de áudio de até 30 segundos.");
        Sample result;result.rate=reader->sampleRate;const int count=(int)reader->lengthInSamples;
        AudioBuffer<float>buffer(std::min(2,(int)reader->numChannels),count);
        if(!reader->read(&buffer,0,count,0,true,true))throw std::runtime_error("Não foi possível ler o som de click.");
        result.data.resize((size_t)count);
        for(int i=0;i<count;++i)result.data[(size_t)i]=buffer.getNumChannels()>1?(buffer.getSample(0,i)+buffer.getSample(1,i))*.5f:buffer.getSample(0,i);
        return result;
    }
    static Sample tone(String preset,bool accent){
        Sample sample;sample.data.resize(1680);const double hz=preset=="Wood"?(accent?1000:700):preset=="Clave"?(accent?2200:1700):(accent?1600:1000);
        float peak=0;
        for(size_t i=0;i<sample.data.size();++i){
            const double t=i/48000.,envelope=std::min(1.,t/.0008)*std::pow(std::max(0.,1-t/.035),4);
            const double harmonic=preset=="Digital"?0:std::sin(MathConstants<double>::twoPi*hz*1.67*t)*(preset=="Wood"?.6:.3);
            sample.data[i]=(float)((std::sin(MathConstants<double>::twoPi*hz*t)+harmonic)*envelope);peak=std::max(peak,std::abs(sample.data[i]));
        }
        if(peak>0)for(auto &v:sample.data)v/=peak;return sample;
    }
    float sample(double time,int mode=0,float gainA=1,float gainB=1,const jaras::PlaybackScope *scope=nullptr)const{
        const auto next=std::upper_bound(sections.begin(),sections.end(),time,[](double t,const Section &s){return t<s.start;});
        if(next==sections.begin())return 0;const auto &section=*(next-1);if(time>=section.end||section.bpm<=0||section.unit<=0)return 0;
        int rate=section.rate;
        if(scope && *scope!=jaras::PlaybackScope{} && !section.items.empty()) {
            rate=0;
            for(const auto &item:section.items) if(scope->allows(item.playbackStart,item.owner)) rate=std::max(rate,item.rate);
            if(!rate)return 0;
        }
        const double bpm=section.bpm/section.rate*rate;
        const int beats=section.beats/section.rate*rate;
        const double beat=60./bpm*4/section.unit;const auto index=(int64)std::floor((time-section.origin)/beat+1e-9);
        const bool accent=mode==1||(mode==0&&index%std::max(1,beats)==0);
        const auto &sound=accent?a:b;const double offset=(time-section.origin-index*beat)*sound.rate;
        if(offset<0||offset>=(double)sound.data.size())return 0;const auto n=(size_t)offset;const float fraction=(float)(offset-n);
        const float left=sound.data[n],right=n+1<sound.data.size()?sound.data[n+1]:0;
        return (left+(right-left)*fraction)*(accent?gainA:gainB);
    }
};
}
