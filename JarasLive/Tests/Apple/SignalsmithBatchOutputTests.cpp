// Emit deterministic stereo PCM for comparison with the original sample loop.
#if defined(_WIN32)
#define SIGNALSMITH_USE_PFFFT 1
#include <fcntl.h>
#include <io.h>
#else
#define SIGNALSMITH_USE_ACCELERATE 1
#endif
#define CATLIVE_SIGNALSMITH_NEUTRAL_WARMUP 1
#include "../../Windows/ThirdParty/Signalsmith/signalsmith-stretch.h"
#include <cstdio>
#include <vector>
#include <cmath>

int main() {
#if defined(_WIN32)
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    for (bool split : {false, true}) for (bool warm : {false, true}) {
        signalsmith::stretch::SignalsmithStretch<float> processor(0);
        processor.presetDefault(2, 44100, split);
        processor.setNeutralWarmup(warm);
        std::vector<float> left(16384), right(16384), outL(2048), outR(2048);
        const float *in[]{left.data(), right.data()};
        float *out[]{outL.data(), outR.data()};
        int position = 0;
        auto fill = [&](int count) {
            for (int n=0; n<count; ++n) {
                const int frame=position++;
                left[n]=float(.2*std::sin(frame*.071)+.07*std::cos(frame*.039));
                right[n]=float(.13*std::sin(frame*.09)+(frame%217==0 ? .1 : 0));
            }
        };
        const int seek=processor.outputSeekLength(1);
        fill(seek); processor.outputSeek(in, seek);
        for (int block=0; block<180; ++block) {
            const int outputCount=1+(block*179)%2048;
            const int inputCount=block<60 ? outputCount : std::max(1, outputCount*(block<120 ? 3 : 2)/4);
            if (block==60) { processor.setNeutralWarmup(false); processor.setTransposeSemitones(3); }
            if (block==120) processor.setTransposeSemitones(-5);
            fill(inputCount);
            processor.process(in, inputCount, out, outputCount);
            std::fwrite(outL.data(), sizeof(float), outputCount, stdout);
            std::fwrite(outR.data(), sizeof(float), outputCount, stdout);
        }
    }
}
