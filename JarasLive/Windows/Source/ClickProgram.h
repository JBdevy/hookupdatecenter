#pragma once
#include "Common.h"
namespace catlive {
struct ClickProgram {
    struct Section {double start=0,end=0,origin=0,bpm=120;int beats=4,unit=4;};
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
        std::vector<std::pair<double,double>>spans;
        for(const auto &clip:track->clips)if(!clip.muted&&!clip.audioFile&&clip.duration>0)spans.push_back({clip.startTime,clip.startTime+clip.duration});
        std::sort(spans.begin(),spans.end());std::vector<std::pair<double,double>>merged;
        for(const auto &span:spans){if(!merged.empty()&&merged.back().second>=span.first)merged.back().second=std::max(merged.back().second,span.second);else merged.push_back(span);}
        for(const auto &span:merged)for(auto section:timing)if(section.end>span.first&&section.start<span.second){
            section.start=std::max(span.first,section.start);section.end=std::min(span.second,section.end);sections.push_back(section);
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
    float sample(double time,int mode=0,float gainA=1,float gainB=1)const{
        const auto next=std::upper_bound(sections.begin(),sections.end(),time,[](double t,const Section &s){return t<s.start;});
        if(next==sections.begin())return 0;const auto &section=*(next-1);if(time>=section.end||section.bpm<=0||section.unit<=0)return 0;
        const double beat=60./section.bpm*4/section.unit;const auto index=(int64)std::floor((time-section.origin)/beat+1e-9);
        const bool accent=mode==1||(mode==0&&index%std::max(1,section.beats)==0);
        const auto &sound=accent?a:b;const double offset=(time-section.origin-index*beat)*sound.rate;
        if(offset<0||offset>=(double)sound.data.size())return 0;const auto n=(size_t)offset;const float fraction=(float)(offset-n);
        const float left=sound.data[n],right=n+1<sound.data.size()?sound.data[n+1]:0;
        return (left+(right-left)*fraction)*(accent?gainA:gainB);
    }
};
}
