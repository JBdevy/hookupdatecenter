#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>

namespace catlive::native {

enum class AudioFileFormat { wav, aiff, mp3, flac };

struct AudioFileInfo {
    std::uint32_t sampleRate = 0;
    std::uint32_t channels = 0;
    // Source precision; MP3 has no fixed PCM bit depth and reports zero.
    std::uint32_t bitsPerSample = 0, validBitsPerSample = 0;
    std::uint32_t channelMask = 0; // Zero when not specified by the container.
    std::uint64_t frameCount = 0, encodedBytes = 0;
    AudioFileFormat format = AudioFileFormat::wav;
    bool floatingPoint = false;
    double durationSeconds() const noexcept {
        return sampleRate ? static_cast<double>(frameCount) / sampleRate : 0;
    }
};

// Disk/decoder resource for one serialized loader/read-ahead worker. No method
// belongs in an audio callback. Independent playback heads open independent
// readers; immutable decoded blocks are published by the host's streaming cache.
// The API and implementation are identical on Windows and the test platform.
class AudioFile final {
  public:
    explicit AudioFile(const std::filesystem::path&);
    ~AudioFile();
    AudioFile(const AudioFile&) = delete;
    AudioFile& operator=(const AudioFile&) = delete;

    const AudioFileInfo& info() const noexcept;
    const std::filesystem::path& path() const noexcept;

    // Container metadata for preparing an inactive timeline source. MP3 length
    // retains gapless trimming, but no synthesis/checkpoint index is built.
    // The playback reader still validates decoded audio and exact seeking.
    static AudioFileInfo inspect(const std::filesystem::path&);

    // Float PCM in source channel order, without resampling or downmixing.
    // firstFrame indexes decoded PCM; MP3 priming/padding declared by the
    // source's gapless metadata is excluded.
    // Returns frames from the file; any requested tail beyond EOF is zeroed.
    // Invalid arguments, damaged/truncated data and decoder errors throw.
    std::size_t readInterleaved(std::uint64_t firstFrame, float* destination,
                                std::size_t frames);
    // Extra output channels are silent; null individual planes are skipped.
    std::size_t readFrames(std::uint64_t firstFrame, float* const* destination,
                           std::size_t destinationChannels, std::size_t frames);

  private:
    AudioFile(const std::filesystem::path&, bool prepareSeeking);
    struct Impl;
    std::unique_ptr<Impl> impl;
};

} // namespace catlive::native
