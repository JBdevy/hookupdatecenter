#pragma once
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>

// HTDemucs6's real-valued Core ML boundary. This transform runs exclusively
// on the inference worker; the audio render callback only exchanges packets.
// The layout matches torch.view_as_real(...).permute(0, 1, 4, 2, 3).
namespace CatStemMobile {
class Spectrogram {
public:
    static constexpr unsigned context = 44100;
    static constexpr unsigned fftSize = 4096;
    static constexpr unsigned hop = 1024;
    static constexpr unsigned bins = fftSize / 2;
    static constexpr unsigned frames = (context + hop - 1) / hop;
    static constexpr unsigned values = 4 * bins * frames;
private:
    static constexpr unsigned leftPad = 3 * hop / 2;
    static constexpr unsigned synthesisFrames = frames + 4;
    static constexpr unsigned synthesisLength = (synthesisFrames - 1) * hop + fftSize;
    static constexpr unsigned outputOffset = fftSize / 2 + leftPad;
    vDSP_DFT_Setup forwardSetup = nullptr;
    vDSP_DFT_Setup inverseSetup = nullptr;
    std::array<float, fftSize> window{}, real{}, imaginary{}, realResult{}, imaginaryResult{};
    std::vector<float> overlap, weight;

    static unsigned reflected(int index) {
        if (index < 0) return unsigned(-index);
        if (index >= int(context)) return unsigned(2 * int(context) - 2 - index);
        return unsigned(index);
    }
public:
    Spectrogram(): overlap(synthesisLength), weight(synthesisLength) {
        forwardSetup = vDSP_DFT_zop_CreateSetup(nullptr, fftSize, vDSP_DFT_FORWARD);
        inverseSetup = vDSP_DFT_zop_CreateSetup(nullptr, fftSize, vDSP_DFT_INVERSE);
        if (!forwardSetup || !inverseSetup) {
            if (forwardSetup) vDSP_DFT_DestroySetup(forwardSetup);
            if (inverseSetup) vDSP_DFT_DestroySetup(inverseSetup);
            throw std::runtime_error("Could not prepare the CatStem spectral transform.");
        }
        for (unsigned n = 0; n < fftSize; ++n)
            window[n] = float(0.5 - 0.5 * std::cos(2 * M_PI * n / fftSize));
        // ISTFT normalization includes the two zero-padded frames at each end.
        for (unsigned frame = 0; frame < synthesisFrames; ++frame)
            for (unsigned n = 0; n < fftSize; ++n)
                weight[frame * hop + n] += window[n] * window[n];
    }
    ~Spectrogram() {
        vDSP_DFT_DestroySetup(forwardSetup);
        vDSP_DFT_DestroySetup(inverseSetup);
    }
    Spectrogram(const Spectrogram&) = delete;
    Spectrogram& operator=(const Spectrogram&) = delete;

    // Input is planar [2,44100]. Output is [4,2048,44], with real/imaginary
    // planes next to one another for each of the two input channels.
    void encode(const float *pcm, float *spectrum) {
        constexpr float scale = 1.0f / 64.0f; // normalized=True: sqrt(4096)
        imaginary.fill(0);
        for (unsigned channel = 0; channel < 2; ++channel) {
            for (unsigned frame = 0; frame < frames; ++frame) {
                for (unsigned n = 0; n < fftSize; ++n)
                    real[n] = pcm[channel * context + reflected(int(frame * hop + n) - int(leftPad))] * window[n];
                vDSP_DFT_Execute(forwardSetup, real.data(), imaginary.data(), realResult.data(), imaginaryResult.data());
                for (unsigned frequency = 0; frequency < bins; ++frequency) {
                    spectrum[((channel * 2) * bins + frequency) * frames + frame] = realResult[frequency] * scale;
                    spectrum[((channel * 2 + 1) * bins + frequency) * frames + frame] = imaginaryResult[frequency] * scale;
                }
            }
        }
    }

    // One predicted stem spectrum [4,2048,44] becomes planar [2,44100].
    // The caller adds the separately predicted, already denormalized time
    // branch. No audio normalization, threshold or substitute model is used.
    void decode(const float *spectrum, float *pcm) {
        constexpr float scale = 1.0f / 64.0f;
        for (unsigned channel = 0; channel < 2; ++channel) {
            std::fill(overlap.begin(), overlap.end(), 0);
            for (unsigned frame = 0; frame < frames; ++frame) {
                real.fill(0); imaginary.fill(0);
                for (unsigned frequency = 0; frequency < bins; ++frequency) {
                    const float r = spectrum[((channel * 2) * bins + frequency) * frames + frame];
                    const float i = spectrum[((channel * 2 + 1) * bins + frequency) * frames + frame];
                    real[frequency] = r; imaginary[frequency] = i;
                    if (frequency) { real[fftSize - frequency] = r; imaginary[fftSize - frequency] = -i; }
                }
                vDSP_DFT_Execute(inverseSetup, real.data(), imaginary.data(), realResult.data(), imaginaryResult.data());
                const unsigned start = (frame + 2) * hop;
                for (unsigned n = 0; n < fftSize; ++n)
                    overlap[start + n] += realResult[n] * window[n] * scale;
            }
            for (unsigned n = 0; n < context; ++n)
                pcm[channel * context + n] = overlap[outputOffset + n] / weight[outputOffset + n];
        }
    }
};
}
