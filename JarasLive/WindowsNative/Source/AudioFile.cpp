#include "AudioFile.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#define DR_WAV_IMPLEMENTATION
#include "../ThirdParty/dr_libs/dr_wav.h"
#define DR_MP3_FLOAT_OUTPUT
#define DR_MP3_IMPLEMENTATION
#include "../ThirdParty/dr_libs/dr_mp3.h"
#define DR_FLAC_IMPLEMENTATION
#include "../ThirdParty/dr_libs/dr_flac.h"

namespace catlive::native {
namespace {
constexpr std::size_t decodeBlock = 4096;
constexpr std::uint32_t maximumChannels = 128;
constexpr std::uint64_t unknownPosition = std::numeric_limits<std::uint64_t>::max();

bool starts(const std::array<char, 16>& header, const char* value, std::size_t size) {
    return std::memcmp(header.data(), value, size) == 0;
}
void validInfo(const AudioFileInfo& info) {
    if (info.channels == 0 || info.channels > maximumChannels ||
        info.sampleRate == 0 || info.sampleRate > 768000 ||
        info.frameCount > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))
        throw std::runtime_error("Unsupported audio channel count, rate or length.");
}
void validBuffer(const void* destination, std::size_t channels, std::size_t frames) {
    if (channels == 0 || channels > maximumChannels || (frames != 0 && !destination) ||
        frames > std::numeric_limits<std::size_t>::max() / channels / sizeof(float))
        throw std::invalid_argument("Invalid audio destination buffer.");
}
} // namespace

struct AudioFile::Impl {
    std::filesystem::path path;
    AudioFileInfo info;
    drwav wav{};
    drmp3 mp3{};
    drflac* flac = nullptr;
    bool wavOpen = false, mp3Open = false;
    bool truncatedWaveChunk = false;
    struct MP3Checkpoint {
        std::uint64_t frame = 0, rawFrame = 0, byte = 0;
        // Only persistent synthesis state; the decoder scratch contains transient
        // pointers and is deliberately excluded. No decoded song PCM is cached.
        float overlap[2][9 * 32]{}, qmf[15 * 2 * 32]{};
        int reservoir = 0, freeFormatBytes = 0;
        unsigned char header[4]{}, reservoirBytes[511]{};
    };
    std::vector<MP3Checkpoint> mp3Checkpoints;
    std::uint64_t mp3Position = 0, checkpointSpacing = 0;
    std::vector<float> scratch;
    std::vector<unsigned char> pcm8;
    std::uint64_t position = 0;

    ~Impl() {
        if (wavOpen) drwav_uninit(&wav);
        if (mp3Open) drmp3_uninit(&mp3);
        if (flac) drflac_close(flac);
    }

    static drwav_uint64 waveChunk(void* context, drwav_read_proc, drwav_seek_proc,
                                  void* stream, const drwav_chunk_header* header,
                                  drwav_container, const drwav_fmt*) {
        auto& self = *static_cast<Impl*>(context);
        drwav_int64 position = 0;
        // dr_wav intentionally tolerates truncated chunks by clamping them.
        // Preserve the original declaration before that repair so a damaged
        // song cannot silently acquire a different timeline length.
        if (self.wav.onTell && self.wav.onTell(stream, &position) && position >= 0 &&
            header->sizeInBytes != 0xffffffffU &&
            (static_cast<std::uint64_t>(position) > self.info.encodedBytes ||
             header->sizeInBytes > self.info.encodedBytes - static_cast<std::uint64_t>(position)))
            self.truncatedWaveChunk = true;
        return 0;
    }

    void openWave() {
#if defined(_WIN32)
        wavOpen = drwav_init_file_ex_w(&wav, path.c_str(), waveChunk, this, 0, nullptr) != 0;
#else
        wavOpen = drwav_init_file_ex(&wav, path.c_str(), waveChunk, this, 0, nullptr) != 0;
#endif
        if (!wavOpen) throw std::runtime_error("Invalid or unsupported WAV/AIFF audio.");
        info.format = wav.container == drwav_container_aiff ? AudioFileFormat::aiff : AudioFileFormat::wav;
        info.sampleRate = wav.sampleRate;
        info.channels = wav.channels;
        info.bitsPerSample = wav.bitsPerSample;
        info.validBitsPerSample = wav.fmt.validBitsPerSample ? wav.fmt.validBitsPerSample : wav.bitsPerSample;
        info.channelMask = wav.fmt.channelMask;
        info.frameCount = wav.totalPCMFrameCount;
        info.floatingPoint = wav.translatedFormatTag == DR_WAVE_FORMAT_IEEE_FLOAT;
        const auto bytesPerFrame = drwav_get_bytes_per_pcm_frame(&wav);
        if (truncatedWaveChunk || wav.dataChunkDataPos > info.encodedBytes ||
            wav.dataChunkDataSize > info.encodedBytes - wav.dataChunkDataPos)
            throw std::runtime_error("Truncated WAV/AIFF audio data.");
        if ((wav.translatedFormatTag == DR_WAVE_FORMAT_PCM || info.floatingPoint) &&
            (bytesPerFrame == 0 || info.frameCount > wav.dataChunkDataSize / bytesPerFrame))
            throw std::runtime_error("WAV/AIFF frame count exceeds its PCM data.");
    }

    MP3Checkpoint checkpoint(std::uint64_t frame) const {
        MP3Checkpoint point;
        point.frame = frame;
        point.rawFrame = mp3.currentPCMFrame;
        point.byte = mp3.streamCursor - mp3.dataSize;
        std::memcpy(point.overlap, mp3.decoder.mdct_overlap, sizeof point.overlap);
        std::memcpy(point.qmf, mp3.decoder.qmf_state, sizeof point.qmf);
        point.reservoir = mp3.decoder.reserv;
        point.freeFormatBytes = mp3.decoder.free_format_bytes;
        std::memcpy(point.header, mp3.decoder.header, sizeof point.header);
        std::memcpy(point.reservoirBytes, mp3.decoder.reserv_buf, sizeof point.reservoirBytes);
        return point;
    }

    bool restore(const MP3Checkpoint& point) {
        // Public stdio callbacks take signed 32-bit offsets. Advance in chunks
        // so recordings beyond 2 GiB keep their actual 64-bit file positions.
        if (!mp3.onSeek(mp3.pUserData, 0, DRMP3_SEEK_SET)) return false;
        auto remaining = point.byte;
        while (remaining) {
            const auto step = static_cast<int>(std::min<std::uint64_t>(remaining,
                static_cast<std::uint64_t>(std::numeric_limits<int>::max())));
            if (!mp3.onSeek(mp3.pUserData, step, DRMP3_SEEK_CUR)) return false;
            remaining -= static_cast<std::uint64_t>(step);
        }
        mp3.streamCursor = point.byte;
        mp3.dataConsumed = mp3.dataSize = 0;
        mp3.pcmFramesConsumedInMP3Frame = mp3.pcmFramesRemainingInMP3Frame = 0;
        mp3.currentPCMFrame = point.rawFrame;
        mp3.atEnd = DRMP3_FALSE;
        std::memcpy(mp3.decoder.mdct_overlap, point.overlap, sizeof point.overlap);
        std::memcpy(mp3.decoder.qmf_state, point.qmf, sizeof point.qmf);
        mp3.decoder.reserv = point.reservoir;
        mp3.decoder.free_format_bytes = point.freeFormatBytes;
        std::memcpy(mp3.decoder.header, point.header, sizeof point.header);
        std::memcpy(mp3.decoder.reserv_buf, point.reservoirBytes, sizeof point.reservoirBytes);
        mp3Position = point.frame;
        return true;
    }

    std::uint64_t readMP3(float* destination, std::uint64_t frames) {
        std::uint64_t count = 0;
        while (count < frames) {
            // Visit every compressed-frame boundary: changing rate or channels
            // inside one MP3 would invalidate its single timeline sample clock.
            const auto request = std::min<std::uint64_t>(frames - count,
                std::max<drmp3_uint32>(1, mp3.pcmFramesRemainingInMP3Frame));
            const auto got = drmp3_read_pcm_frames_f32(&mp3, request,
                destination ? destination + static_cast<std::size_t>(count) * info.channels : nullptr);
            if (mp3.mp3FrameSampleRate != info.sampleRate || mp3.mp3FrameChannels != info.channels)
                throw std::runtime_error("MP3 changes sample rate or channels inside the file.");
            count += got;
            mp3Position += got;
            // Keep exact synthesis state as the worker visits new audio. A
            // first Play only decodes the required prefix, not the entire song.
            if (got && checkpointSpacing && mp3.pcmFramesRemainingInMP3Frame == 0 &&
                mp3Checkpoints.size() < 4096 &&
                mp3Position >= mp3Checkpoints.back().frame + checkpointSpacing)
                mp3Checkpoints.push_back(checkpoint(mp3Position));
            if (got != request) break;
        }
        return count;
    }

    void openMP3(bool prepareSeeking) {
#if defined(_WIN32)
        mp3Open = drmp3_init_file_w(&mp3, path.c_str(), nullptr) != 0;
#else
        mp3Open = drmp3_init_file(&mp3, path.c_str(), nullptr) != 0;
#endif
        if (!mp3Open) throw std::runtime_error("Invalid MP3 audio.");
        info.format = AudioFileFormat::mp3;
        info.sampleRate = mp3.sampleRate;
        info.channels = mp3.channels;
        const auto expected = drmp3_get_pcm_frame_count(&mp3);
        info.frameCount = expected;
        validInfo(info);
        if (expected == 0) throw std::runtime_error("MP3 has no decodable audio frames.");
        if (!prepareSeeking) return;
        if (!drmp3_seek_to_pcm_frame(&mp3, 0))
            throw std::runtime_error("Unable to rewind MP3 audio.");
        // The compressed seek table does not preserve synthesis/bit-reservoir
        // history. Capture the real decoder state instead, at frame boundaries,
        // for sample-identical random access, progressively on this worker.
        // ~6.6 KiB per two seconds, capped to 4096 checkpoints per open reader.
        checkpointSpacing = std::max<std::uint64_t>(2 * info.sampleRate, expected / 4095 + 1);
        mp3Checkpoints.reserve(static_cast<std::size_t>(std::min<std::uint64_t>(4096, expected / checkpointSpacing + 2)));
        mp3Checkpoints.push_back(checkpoint(0));
    }

    void openFlac() {
#if defined(_WIN32)
        flac = drflac_open_file_w(path.c_str(), nullptr);
#else
        flac = drflac_open_file(path.c_str(), nullptr);
#endif
        if (!flac) throw std::runtime_error("Invalid FLAC audio.");
        info.format = AudioFileFormat::flac;
        info.sampleRate = flac->sampleRate;
        info.channels = flac->channels;
        info.bitsPerSample = info.validBitsPerSample = flac->bitsPerSample;
        info.frameCount = flac->totalPCMFrameCount;
        validInfo(info);
        if (info.frameCount == 0) {
            // A legal STREAMINFO block may leave length unspecified. Count
            // actual decoded frames on this worker instead of inventing time.
            std::vector<float> block(decodeBlock * info.channels);
            drflac_uint64 read = 0;
            while ((read = drflac_read_pcm_frames_f32(flac, decodeBlock, block.data())) != 0) {
                if (info.frameCount > std::numeric_limits<std::uint64_t>::max() - read)
                    throw std::runtime_error("FLAC frame count overflow.");
                info.frameCount += read;
            }
            // The decoder's seek clamp needs the measured count too when the
            // legal STREAMINFO total was initially unspecified.
            flac->totalPCMFrameCount = info.frameCount;
            if (!drflac_seek_to_pcm_frame(flac, 0))
                throw std::runtime_error("Unable to rewind FLAC audio.");
        }
    }

    void seek(std::uint64_t frame) {
        if (frame == position) return;
        // A failed seek may already have moved the underlying decoder. Never
        // reuse its previous logical position after an exception.
        position = unknownPosition;
        bool ok = false;
        if (wavOpen) ok = drwav_seek_to_pcm_frame(&wav, frame) != 0;
        else if (flac) ok = drflac_seek_to_pcm_frame(flac, frame) != 0;
        else if (mp3Open) {
            const auto after = std::upper_bound(mp3Checkpoints.begin(), mp3Checkpoints.end(), frame,
                [](std::uint64_t at, const MP3Checkpoint& point) { return at < point.frame; });
            const auto& point = *std::prev(after);
            const auto distance = frame - point.frame;
            ok = restore(point) && readMP3(nullptr, distance) == distance;
        }
        if (!ok) {
            position = unknownPosition;
            throw std::runtime_error("Unable to seek to PCM frame " + std::to_string(frame) + ".");
        }
        position = frame;
    }

    std::size_t decoded(float* destination, std::size_t frames) {
        const auto firstFrame = position;
        // Decoders advance before PCM validation. A rejected block must force
        // the next read to seek, including a retry at the same logical frame.
        position = unknownPosition;
        std::uint64_t count = 0;
        if (wavOpen && wav.translatedFormatTag == DR_WAVE_FORMAT_PCM && wav.bitsPerSample == 8) {
            // PCM8 silence is 128 in WAV (0 signed in AIFF). Map exactly to
            // zero; dr_wav's convenience converter instead spans -1 to +1.
            while (count < frames) {
                const auto request = std::min<std::uint64_t>(frames - count, decodeBlock);
                const auto got = drwav_read_pcm_frames(&wav, request, pcm8.data());
                for (std::uint64_t i = 0; i < got * info.channels; ++i)
                    destination[static_cast<std::size_t>(count * info.channels + i)] =
                        (static_cast<int>(pcm8[static_cast<std::size_t>(i)]) - 128) / 128.f;
                count += got;
                if (got != request) break;
            }
        }
        else if (wavOpen) count = drwav_read_pcm_frames_f32(&wav, frames, destination);
        else if (flac) count = drflac_read_pcm_frames_f32(flac, frames, destination);
        else if (mp3Open) count = readMP3(destination, frames);
        for (std::uint64_t i = 0; i < count * info.channels; ++i)
            if (!std::isfinite(destination[static_cast<std::size_t>(i)]))
                throw std::runtime_error("Audio contains non-finite PCM samples.");
        if (count != frames) {
            throw std::runtime_error("Audio ended before its declared PCM frame count.");
        }
        position = firstFrame + count;
        return static_cast<std::size_t>(count);
    }
};

AudioFile::AudioFile(const std::filesystem::path& path) : AudioFile(path, true) {}
AudioFile::AudioFile(const std::filesystem::path& path, bool prepareSeeking) : impl(std::make_unique<Impl>()) {
    impl->path = path;
    impl->info.encodedBytes = std::filesystem::file_size(path);
    std::array<char, 16> header{};
    std::ifstream probe(path, std::ios::binary);
    if (!probe || !probe.read(header.data(), static_cast<std::streamsize>(header.size())))
        throw std::runtime_error("Unable to read audio file header.");
    if (starts(header, "RIFF", 4) || starts(header, "RIFX", 4) || starts(header, "RF64", 4) ||
        starts(header, "riff", 4) || starts(header, "FORM", 4)) impl->openWave();
    else if (starts(header, "fLaC", 4) || starts(header, "OggS", 4)) impl->openFlac();
    else if (starts(header, "ID3", 3) ||
             (static_cast<unsigned char>(header[0]) == 0xff &&
              (static_cast<unsigned char>(header[1]) & 0xe0) == 0xe0)) impl->openMP3(prepareSeeking);
    else throw std::runtime_error("Unsupported audio container.");
    validInfo(impl->info);
    if (!prepareSeeking) return;
    impl->scratch.resize(decodeBlock * impl->info.channels);
    if (impl->wavOpen && impl->wav.bitsPerSample == 8)
        impl->pcm8.resize(decodeBlock * impl->info.channels);
}
AudioFile::~AudioFile() = default;
const AudioFileInfo& AudioFile::info() const noexcept { return impl->info; }
const std::filesystem::path& AudioFile::path() const noexcept { return impl->path; }
AudioFileInfo AudioFile::inspect(const std::filesystem::path& path) { return AudioFile(path, false).info(); }

std::size_t AudioFile::readInterleaved(std::uint64_t first, float* destination, std::size_t frames) {
    const auto channels = impl->info.channels;
    validBuffer(destination, channels, frames);
    if (frames == 0) return 0;
    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(frames,
        first < impl->info.frameCount ? impl->info.frameCount - first : 0));
    if (count != 0) {
        impl->seek(first);
        impl->decoded(destination, count);
    }
    std::fill(destination + count * channels, destination + frames * channels, 0.f);
    return count;
}

std::size_t AudioFile::readFrames(std::uint64_t first, float* const* destination,
                                 std::size_t destinationChannels, std::size_t frames) {
    validBuffer(destination, destinationChannels, frames);
    if (frames == 0) return 0;
    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(frames,
        first < impl->info.frameCount ? impl->info.frameCount - first : 0));
    if (count != 0) impl->seek(first);
    const auto channels = impl->info.channels;
    for (std::size_t offset = 0; offset < count;) {
        const auto amount = std::min(decodeBlock, count - offset);
        impl->decoded(impl->scratch.data(), amount);
        for (std::size_t ch = 0; ch < std::min<std::size_t>(channels, destinationChannels); ++ch)
            if (destination[ch])
                for (std::size_t n = 0; n < amount; ++n)
                    destination[ch][offset + n] = impl->scratch[n * channels + ch];
        offset += amount;
    }
    for (std::size_t ch = 0; ch < destinationChannels; ++ch)
        if (destination[ch]) std::fill(destination[ch] + (ch < channels ? count : 0), destination[ch] + frames, 0.f);
    return count;
}

} // namespace catlive::native
