#pragma once
#include "Common.h"
namespace catlive {
// LAME 3.100 encodes float PCM through a separately replaceable LGPL DLL.
// The finalized Xing/LAME tag preserves the original gapless sample clock.
class MP3Writer {
  public:
    MP3Writer(const File &,int sampleRate,int channels,int bitrate);
    ~MP3Writer();
    void write(const AudioBuffer<float> &,int samples);
    void finish();
    // Encoder priming in samples, also written in the LAME gapless tag.
    int encoderDelaySamples() const;
  private:
    struct Impl;std::unique_ptr<Impl> impl;
};
}
