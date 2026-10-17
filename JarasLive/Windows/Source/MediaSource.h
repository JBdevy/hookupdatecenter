#pragma once
#include "Common.h"
namespace catlive {
struct MediaSourceInfo { double duration=0; bool audio=false, video=false; };
MediaSourceInfo inspectMediaSource(const File &);
void registerMediaSourceFormat(AudioFormatManager &);
}
