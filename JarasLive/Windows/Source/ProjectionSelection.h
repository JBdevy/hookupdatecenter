#pragma once
#include "Common.h"
namespace catlive {
inline bool projectionMedia(const jaras::AudioClip &clip){return clip.audioFile && (clip.audioFile->path.rfind("Videos/",0)==0 || File(text(clip.audioFile->path)).hasFileExtension("mp4;mov;m4v;avi;mkv;webm;wmv;png;jpg;jpeg;bmp;gif;tif;tiff"));}
inline const jaras::AudioClip *firstProjectionItem(const jaras::Song &song,double at,const String &role){
    if(!std::isfinite(at))return nullptr;
    for(const auto &track:song.tracks)if(!track.mute&&(role=="video"||text(track.role.id)==role))
        for(const auto &clip:track.clips)if(!clip.muted&&at>=clip.startTime&&at<clip.startTime+clip.duration&&(role!="video"||projectionMedia(clip)))return &clip;
    return nullptr;
}
}
