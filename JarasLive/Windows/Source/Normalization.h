#pragma once
#include "ProjectCodec.h"
namespace catlive::normalization {
namespace library {
#include "../../Core/ThirdParty/EBUR128/ebur128.h"
}
using namespace library;
enum Mode { lufs, rms, peak, truePeak };
inline String name(Mode mode) {
    return StringArray{"LUFS-I", "RMS-I", "Peak", "True Peak"}[(int)mode];
}
inline double gain(double measured, double target) {
    return std::isfinite(measured) && measured > -150
               ? std::pow(10., jlimit(-120., 24., target - measured) / 20.)
               : 1;
}
inline double measure(const jaras::AudioClip &clip, const File &directory, Mode mode,
                      const std::function<bool()> &cancelled = {},
                      const std::function<void(double)> &progress = {}) {
    auto check = [&] {
        if (cancelled && cancelled())
            throw std::runtime_error("Análise cancelada.");
    };
    check();
    if (!clip.audioFile)
        throw std::runtime_error("O item não tem arquivo de áudio.");
    AudioFormatManager formats;
    formats.registerBasicFormats();
    std::unique_ptr<AudioFormatReader> reader(
        formats.createReaderFor(ProjectCodec::resolveMedia(directory, clip.audioFile->path)));
    if (!reader || reader->numChannels < 1 || reader->numChannels > 128 || reader->sampleRate < 1)
        throw std::runtime_error("Não foi possível analisar este arquivo.");
    const double rate = reader->sampleRate;
    const int channels = (int)reader->numChannels;
    const auto framesAt = [&](double seconds) -> int64 {
        const auto frames = seconds * rate;
        if (!std::isfinite(frames) || frames < 0 || frames > 9e15)
            throw std::runtime_error("Duração de análise inválida.");
        return (int64)frames;
    };
    const int64 loopFirst = framesAt(clip.loopStart.value_or(0));
    const int64 loopEnd = std::min(
        reader->lengthInSamples,
        loopFirst + framesAt(clip.loopLength.value_or((double)reader->lengthInSamples / rate)));
    const bool looping = clip.loopLength.has_value();
    const auto rawFirst = framesAt(clip.sourceOffset);
    const int64 first =
        looping && loopEnd > loopFirst
            ? loopFirst + ((rawFirst - loopFirst) % (loopEnd - loopFirst) + (loopEnd - loopFirst)) %
                              (loopEnd - loopFirst)
            : std::min(reader->lengthInSamples, rawFirst);
    const auto total = framesAt(clip.duration * clip.playbackRate + .5 / rate);
    const int64 wanted = looping ? total : std::min(reader->lengthInSamples - first, total);
    if (wanted <= 0 || loopEnd <= loopFirst)
        throw std::runtime_error("O intervalo do item não contém áudio.");
    struct Meter {
        ebur128_state *value = nullptr;
        ~Meter() {
            if (value)
                ebur128_destroy(&value);
        }
    } meter{ebur128_init((unsigned)channels, (unsigned long)std::llround(rate),
                         EBUR128_MODE_I | EBUR128_MODE_TRUE_PEAK)};
    if (!meter.value)
        throw std::runtime_error("Não foi possível iniciar a análise.");
    AudioBuffer<float> buffer(channels, 16384);
    std::vector<float> interleaved((size_t)channels * 16384);
    double squares = 0;
    int64 frames = 0, position = first;
    while (frames < wanted) {
        check();
        if (looping && position >= loopEnd)
            position = loopFirst;
        const auto available = (looping ? loopEnd : reader->lengthInSamples) - position;
        const int count = (int)std::min<int64>(16384, std::min(available, wanted - frames));
        if (count <= 0 ||
            !reader->read(buffer.getArrayOfWritePointers(), channels, position, count))
            throw std::runtime_error("Falha ao ler o áudio para análise.");
        for (int ch = 0; ch < channels; ++ch)
            for (int i = 0; i < count; ++i) {
                const auto sample = buffer.getSample(ch, i);
                if (!std::isfinite(sample))
                    throw std::runtime_error("O arquivo contém amostras inválidas.");
                squares += (double)sample * sample;
                interleaved[(size_t)i * channels + ch] = sample;
            }
        if (ebur128_add_frames_float(meter.value, interleaved.data(), (size_t)count) !=
            EBUR128_SUCCESS)
            throw std::runtime_error("Falha na medição de nível.");
        position += count;
        frames += count;
        if (progress)
            progress((double)frames / wanted);
    }
    check();
    if (mode == rms)
        return 10 * std::log10(std::max(1e-20, squares / ((double)frames * channels)));
    if (mode == lufs) {
        if (frames / rate < .4) {
            const auto padding = (size_t)std::ceil(rate * .4) - (size_t)frames;
            std::vector<float> silence(padding * channels, 0);
            ebur128_add_frames_float(meter.value, silence.data(), padding);
        }
        double level = 0;
        if (ebur128_loudness_global(meter.value, &level) != EBUR128_SUCCESS)
            throw std::runtime_error("Falha na medição LUFS-I.");
        return level;
    }
    if (mode == truePeak) {
        std::vector<float> tail((size_t)channels * 64, 0);
        ebur128_add_frames_float(meter.value, tail.data(), 64);
    }
    double maximum = 0;
    for (int ch = 0; ch < channels; ++ch) {
        double level = 0;
        if (mode == peak)
            ebur128_sample_peak(meter.value, (unsigned)ch, &level);
        else
            ebur128_true_peak(meter.value, (unsigned)ch, &level);
        maximum = std::max(maximum, level);
    }
    return 20 * std::log10(std::max(1e-20, maximum));
}
} // namespace catlive::normalization
