#pragma once
#include "AudioDevice.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace catlive::native::audio::detail {
// Interleaved little-endian Windows PCM/IEEE float. Configuration happens before
// the stream starts; the conversion functions neither allocate nor acquire locks.
class PCMConversion {
public:
    static bool supports(const SampleFormat& f) noexcept {
        if (!f.channels || f.channels > 128 || !f.validBits || f.validBits > f.containerBits) return false;
        if (f.encoding == SampleEncoding::floatingPoint)
            return (f.containerBits == 32 || f.containerBits == 64) && f.validBits == f.containerBits;
        if (f.encoding == SampleEncoding::unsignedPCM) return f.containerBits == 8 && f.validBits == 8;
        return (f.containerBits == 16 || f.containerBits == 24 || f.containerBits == 32);
    }
    explicit PCMConversion(SampleFormat value) noexcept : format(value) {
        bytes = format.containerBits / 8;
        padding = format.containerBits - format.validBits;
        decodeScale = std::ldexp(1., 1 - int(format.containerBits));
        encodeScale = std::ldexp(1., int(format.validBits) - 1);
    }
    std::size_t frameBytes() const noexcept { return std::size_t(bytes) * format.channels; }
    void decode(const void* source, float* const* destination, const std::uint32_t* channels,
                std::uint32_t count, std::uint32_t frames, bool silent) const noexcept {
        if (silent || !source) {
            for (std::uint32_t channel = 0; channel < count; ++channel)
                std::fill_n(destination[channel], frames, 0.f);
            return;
        }
        const auto* data = static_cast<const unsigned char*>(source);
        for (std::uint32_t channel = 0; channel < count; ++channel)
            for (std::uint32_t frame = 0; frame < frames; ++frame)
                destination[channel][frame] = read(data + (std::size_t(frame) * format.channels + channels[channel]) * bytes);
    }
    void encode(float* const* source, void* destination, const std::uint32_t* channels,
                std::uint32_t count, std::uint32_t frames) const noexcept {
        auto* data = static_cast<unsigned char*>(destination);
        std::memset(data, format.encoding == SampleEncoding::unsignedPCM ? 128 : 0, std::size_t(frames) * frameBytes());
        for (std::uint32_t channel = 0; channel < count; ++channel)
            for (std::uint32_t frame = 0; frame < frames; ++frame)
                write(data + (std::size_t(frame) * format.channels + channels[channel]) * bytes, source[channel][frame]);
    }
private:
    SampleFormat format;
    unsigned bytes = 0, padding = 0;
    double decodeScale = 0, encodeScale = 0;
    float read(const unsigned char* data) const noexcept {
        if (format.encoding == SampleEncoding::floatingPoint) {
            if (bytes == 4) {
                float sample; std::memcpy(&sample, data, sizeof(sample));
                return std::isfinite(sample) ? sample : 0.f;
            }
            double sample; std::memcpy(&sample, data, sizeof(sample));
            const float narrowed = static_cast<float>(sample);
            return std::isfinite(narrowed) ? narrowed : 0.f;
        }
        if (format.encoding == SampleEncoding::unsignedPCM) return (int(*data) - 128) / 128.f;
        std::uint64_t raw = 0;
        for (unsigned byte = 0; byte < bytes; ++byte) raw |= std::uint64_t(data[byte]) << (byte * 8);
        raw &= ~((std::uint64_t(1) << padding) - 1);
        const auto sign = std::uint64_t(1) << (format.containerBits - 1);
        const std::int64_t signedValue = raw & sign ? std::int64_t(raw) - std::int64_t(sign * 2) : std::int64_t(raw);
        return static_cast<float>(signedValue * decodeScale);
    }
    void write(unsigned char* data, float sample) const noexcept {
        if (!std::isfinite(sample)) sample = 0;
        if (format.encoding == SampleEncoding::floatingPoint) {
            if (bytes == 4) std::memcpy(data, &sample, sizeof(sample));
            else { const double value = sample; std::memcpy(data, &value, sizeof(value)); }
            return;
        }
        const double bounded = std::clamp(double(sample), -1., 1.);
        if (format.encoding == SampleEncoding::unsignedPCM) {
            *data = static_cast<unsigned char>(std::clamp(std::llround(bounded * 128) + 128, 0ll, 255ll));
            return;
        }
        const std::int64_t maximum = (std::int64_t(1) << (format.validBits - 1)) - 1;
        const std::int64_t minimum = -maximum - 1;
        const auto quantized = std::clamp<std::int64_t>(std::llround(bounded * encodeScale), minimum, maximum);
        const std::uint64_t raw = static_cast<std::uint64_t>(quantized) << padding;
        for (unsigned byte = 0; byte < bytes; ++byte) data[byte] = static_cast<unsigned char>(raw >> (byte * 8));
    }
};
} // namespace catlive::native::audio::detail
