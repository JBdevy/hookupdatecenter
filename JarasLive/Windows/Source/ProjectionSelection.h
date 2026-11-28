#pragma once
#include "Common.h"
namespace catlive {
inline bool projectionMedia(const jaras::AudioClip &clip){return clip.adjustedVideo || (clip.audioFile && (clip.audioFile->path.rfind("Videos/",0)==0 || File(text(clip.audioFile->path)).hasFileExtension("mp4;mov;m4v;avi;mkv;webm;wmv;png;jpg;jpeg;bmp;gif;tif;tiff")));}
inline std::pair<double,double> projectionClock(const jaras::AudioClip& clip,double at) {
    const double elapsed=at-clip.startTime;
    if(!clip.adjustedVideo || clip.adjustedVideo->points.size()<2)return {clip.sourceOffset+elapsed*clip.playbackRate,clip.playbackRate};
    const auto& points=clip.adjustedVideo->points;
    const auto it=std::upper_bound(points.begin(),points.end(),elapsed,[](double t,const auto& p){return t<p.time;});
    const auto n=std::clamp<std::ptrdiff_t>(it-points.begin()-1,0,static_cast<std::ptrdiff_t>(points.size()-2));
    const auto& a=points[n];const auto& b=points[n+1];
    const double rate=(b.source-a.source)/(b.time-a.time);
    return {a.source+(elapsed-a.time)*rate,rate};
}
inline std::string projectionPath(const jaras::AudioClip& clip){return clip.adjustedVideo?clip.adjustedVideo->path:clip.audioFile->path;}
inline const jaras::AudioClip *firstProjectionItem(const jaras::Song &song,double at,const String &role){
    if(!std::isfinite(at))return nullptr;
    for(const auto &track:song.tracks)if(!track.mute&&(role=="video" ? track.role.id!="teleprompt"&&track.role.id!="teleprompt2" : text(track.role.id)==role))
        for(const auto &clip:track.clips)if(!clip.muted&&at>=clip.startTime&&at<clip.startTime+clip.duration&&(role!="video"||projectionMedia(clip)))return &clip;
    return nullptr;
}
}
