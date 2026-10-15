#pragma once
#include "Common.h"
namespace catlive {
// The Windows 8+ Media Foundation MP3 encoder accepts signed 16-bit PCM.
// https://learn.microsoft.com/en-us/windows/win32/medfound/mp3-audio-encoder
class MP3Writer {
  public:
    MP3Writer(const File &,int sampleRate,int channels,int bitrate);
    ~MP3Writer();
    void write(const AudioBuffer<float> &,int samples);
    void finish();
  private:
    struct Impl;std::unique_ptr<Impl> impl;
};
}
