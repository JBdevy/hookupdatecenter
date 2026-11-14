#pragma once
#include "TempoEditMap.hpp"
#include <iomanip>
#include <cctype>
#include <limits>
#include <locale>
#include <sstream>
#include <stdexcept>
namespace jaras {
struct ItemRateSettings {
    double baseBPM=120,rate=1;
    double rateStepOrigin=1,lastSteppedRate=std::numeric_limits<double>::quiet_NaN();
    int rateSteps=0;
    ItemRateSettings(double base,double initial=1):baseBPM(std::isfinite(base)&&base>0?base:120),rate(initial){}
    double bpmOffset() const{return baseBPM*(rate-1);}
    void setBPMOffset(double offset){rate=(baseBPM+offset)/baseBPM;lastSteppedRate=std::numeric_limits<double>::quiet_NaN();}
    void stepRate(int count){if(rate!=lastSteppedRate){rateStepOrigin=rate;rateSteps=0;}rateSteps+=count;rate=rateStepOrigin+rateSteps/100.;lastSteppedRate=rate;}
    void stepBPM(int count){setBPMOffset(bpmOffset()+count);}
    bool valid() const{return std::isfinite(rate)&&rate>=1./32&&rate<=32;}
    void reset(){rate=1;lastSteppedRate=std::numeric_limits<double>::quiet_NaN();}
    std::string rateText() const {
        std::string result;
        for(int precision=6;precision<=std::numeric_limits<double>::max_digits10;++precision) {
            std::ostringstream out;out.imbue(std::locale::classic());out<<std::setprecision(precision)<<rate;result=out.str();
            std::istringstream in(result);in.imbue(std::locale::classic());double parsed=0;in>>parsed;if(parsed==rate)break;
        }
        if(std::isfinite(rate) && result.find_first_of("eE")==std::string::npos) {
            auto dot=result.find('.');if(dot==std::string::npos){result+='.';dot=result.size()-1;}
            const auto decimals=result.size()-dot-1;if(decimals<6)result.append(6-decimals,'0');
        }
        return result;
    }
};
inline double sourceSpanForItem(const Song& song,const AudioClip& clip) {
    if(clip.audioFile && clip.audioFile->path.rfind("Videos/",0)==0)return clip.duration*clip.playbackRate;
    TempoEditMap::PlaybackRates rates(song);
    double time=clip.startTime,span=0;
    const auto end=clip.startTime+clip.duration;
    for(const auto& point:rates.points(clip)) if(point.time>time && point.time<end) {
        span+=(point.time-time)*rates.playbackRate(clip,time);time=point.time;
    }
    return span+(end-time)*rates.playbackRate(clip,time);
}
inline double durationForSourceSpan(const Song& song,const AudioClip& clip,double sourceSpan) {
    if(clip.audioFile && clip.audioFile->path.rfind("Videos/",0)==0)return sourceSpan/clip.playbackRate;
    TempoEditMap::PlaybackRates rates(song);
    double remaining=sourceSpan,time=clip.startTime;
    for(const auto& point:rates.points(clip)) if(point.time>time) {
        const double rate=rates.playbackRate(clip,time),consumed=(point.time-time)*rate;
        if(remaining<=consumed) {time+=remaining/rate;remaining=0;break;}
        remaining-=consumed;time=point.time;
    }
    if(remaining>0)time+=remaining/rates.playbackRate(clip,time);
    return time-clip.startTime;
}
inline bool itemSupportsRate(const Track& track,const AudioClip& clip) {
    if(clip.audioFile) {
        auto path=clip.audioFile->path;std::transform(path.begin(),path.end(),path.begin(),[](unsigned char c){return std::tolower(c);});
        const auto dot=path.find_last_of('.');const auto ext=dot==std::string::npos?std::string{}:path.substr(dot+1);
        for(const auto* image:{"png","jpg","jpeg","gif","heic","heif","tif","tiff","bmp","webp","avif"})if(ext==image)return false;
    }
    return clip.midi || clip.audioFile || track.audioFile || track.role.id=="timecode" || track.role.id=="generatedClick";
}
inline AudioClip itemWithRate(const Song& song,const AudioClip& clip,double rate,const Track* track=nullptr) {
    if(!std::isfinite(rate) || rate<1./32 || rate>32)throw std::invalid_argument("Invalid playback rate");
    const bool click=track && track->role.id=="generatedClick" && !clip.audioFile;
    const double previous=click?clip.tempoBasePlaybackRate.value_or(clip.playbackRate):clip.playbackRate;
    if(rate==previous)return clip;
    auto result=clip;
    if(click) {
        std::vector<std::pair<double,double>> points{{0,song.bpm}};
        if(song.markers)for(const auto& marker:*song.markers)if(marker.tempoBPM)points.emplace_back(marker.position,*marker.tempoBPM);
        std::stable_sort(points.begin(),points.end(),[](const auto& a,const auto& b){return a.first<b.first;});
        double beats=0,remaining=0,time=clip.startTime;
        const double end=clip.startTime+clip.duration;
        for(size_t i=0;i<points.size();++i) {
            const double first=std::max(clip.startTime,points[i].first),last=std::min(end,i+1<points.size()?points[i+1].first:end);
            if(last>first)beats+=(last-first)*points[i].second/60*previous;
        }
        remaining=beats;
        for(size_t i=0;i<points.size();++i) {
            const double first=std::max(time,points[i].first),last=i+1<points.size()?points[i+1].first:std::numeric_limits<double>::infinity();
            if(last<=first)continue;
            const double speed=points[i].second/60*rate,available=(last-first)*speed;
            if(remaining<=available){time=first+remaining/speed;break;}
            remaining-=available;time=last;
        }
        result.playbackRate=rate;result.tempoBasePlaybackRate.reset();result.duration=time-clip.startTime;
        return result;
    }
    result.playbackRate=rate;result.tempoBasePlaybackRate.reset();
    result.duration=durationForSourceSpan(song,result,sourceSpanForItem(song,clip));
    if(result.fadeIn)result.fadeIn=std::min(*result.fadeIn,result.duration);
    if(result.fadeOut)result.fadeOut=std::min(*result.fadeOut,result.duration);
    return result;
}
// Reset is local to the selected item. Tempo markers and other items keep
// their applied rates; subsequent BPM edits still multiply the new baseline.
inline AudioClip resettingItemRate(const Song& song,const AudioClip& clip) {
    auto result=clip;result.playbackRate=1;result.tempoBasePlaybackRate.reset();
    result.tempoRateReferences.clear();
    if(song.markers)for(const auto& marker:*song.markers)if(marker.tempoBPM)
        result.tempoRateReferences.push_back({marker.id,tempoPlayback::rate(song,marker)});
    return result;
}
inline AudioClip restoringItemDuration(const Song& song,const AudioClip& clip,double sourceDuration) {
    if(!std::isfinite(sourceDuration) || sourceDuration<=0) return clip;
    AudioClip result=clip;
    result.sourceOffset=0;result.loopStart.reset();result.loopLength.reset();
    result.duration=durationForSourceSpan(song,result,sourceDuration);
    if(result.fadeIn) result.fadeIn=std::min(*result.fadeIn,result.duration);
    if(result.fadeOut) result.fadeOut=std::min(*result.fadeOut,result.duration);
    return result;
}
}
