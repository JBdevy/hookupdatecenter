#include "MediaSource.h"
#include "AudioFormats.h"
#include "Common.h"
#include "../../WindowsNative/Source/AudioFile.h"
#include <array>
#include <filesystem>

namespace catlive {
namespace {
class GaplessMP3Reader final : public AudioFormatReader {
  public:
    explicit GaplessMP3Reader(std::unique_ptr<native::AudioFile> file)
        : AudioFormatReader(nullptr, "MP3"), audio(std::move(file)) {
        const auto &info = audio->info();
        sampleRate = info.sampleRate;
        numChannels = info.channels;
        lengthInSamples = (int64)info.frameCount;
        bitsPerSample = 32;
        usesFloatingPointData = true;
    }
    bool readSamples(int *const *destination, int channels, int offset,
                     int64 first, int count) override {
        clearSamplesBeyondAvailableLength(destination, channels, offset, first, count, lengthInSamples);
        if (count <= 0) return true;
        if (first < 0 || channels < 1 || channels > 128) return false;
        std::array<float *, 128> planes{};
        for (int i = 0; i < channels; ++i)
            if (destination[i]) planes[(size_t)i] = reinterpret_cast<float *>(destination[i]) + offset;
        try {
            audio->readFrames((uint64)first, planes.data(), (size_t)channels, (size_t)count);
            return true;
        } catch (...) {
            for (int i = 0; i < channels; ++i)
                if (planes[(size_t)i]) std::fill_n(planes[(size_t)i], count, 0.f);
            return false;
        }
    }
  private:
    std::unique_ptr<native::AudioFile> audio;
};
class GaplessMP3Format final : public AudioFormat {
  public:
    GaplessMP3Format() : AudioFormat("MP3 gapless", ".mp3") {}
    Array<int> getPossibleSampleRates() override { return {8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000}; }
    Array<int> getPossibleBitDepths() override { return {}; }
    bool canDoStereo() override { return true; }
    bool canDoMono() override { return true; }
    bool isCompressed() override { return true; }
    AudioFormatReader *createReaderFor(InputStream *stream, bool deleteIfInvalid) override {
        if (auto *file = dynamic_cast<FileInputStream *>(stream)) {
            if (file->getFile().hasFileExtension("mp3")) try {
                auto audio = std::make_unique<native::AudioFile>(
                    std::filesystem::path(file->getFile().getFullPathName().toWideCharPointer()));
                if (audio->info().format == native::AudioFileFormat::mp3) {
                    auto reader = std::make_unique<GaplessMP3Reader>(std::move(audio));
                    reader->input = stream;
                    return reader.release();
                }
            } catch (...) {}
        }
        if (deleteIfInvalid) delete stream;
        return nullptr;
    }
    std::unique_ptr<AudioFormatWriter> createWriterFor(std::unique_ptr<OutputStream>&,
                                                      const AudioFormatWriterOptions&) override { return {}; }
};
}
void registerAudioFormats(juce::AudioFormatManager &formats) {
    formats.registerFormat(new GaplessMP3Format(), false);
    formats.registerBasicFormats();
    registerMediaSourceFormat(formats);
}
}
