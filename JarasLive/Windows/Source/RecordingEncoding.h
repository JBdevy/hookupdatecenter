#pragma once
#include <array>
#include <optional>
#include <string>

namespace catlive::recordingEncoding {
inline constexpr std::array<int, 6> mp3Bitrates{128, 160, 192, 224, 256, 320};
inline int normalizedBitrate(int value) {
    for (int allowed : mp3Bitrates) if (value == allowed) return value;
    return 320;
}
struct Encoding {
    std::string extension = ".wav";
    int bits = 24, bitrate = 320;
    bool floatingPoint = false;
};
// Same keys/defaults as MediaProcessingFormat.recordingKey(for:) on macOS.
// Advanced WAV32 is PCM; the per-track "wav32" override is IEEE float.
inline Encoding resolve(const std::optional<std::string> &trackFormat,
                        const std::string &advancedFormat, int bits, int bitrate) {
    Encoding result;
    result.bitrate = normalizedBitrate(bitrate);
    result.bits = bits == 16 || bits == 32 ? bits : 24;
    if (trackFormat == "wav") result.bits = 24;
    else if (trackFormat == "wav32") { result.bits = 32; result.floatingPoint = true; }
    else if (trackFormat == "mp3" || advancedFormat == "MP3") result.extension = ".mp3";
    else if (advancedFormat == "AIFF") result.extension = ".aiff";
    return result;
}
} // namespace catlive::recordingEncoding
