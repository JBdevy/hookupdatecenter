#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace catlive::native::audio::asio_detail {
// Our PCM conversion description, independent of the external ASIO SDK.
// Integer samples are signed and right-aligned, with sign-extended padding.
struct PCMFormat {
    unsigned storageBytes = 0, validBits = 0;
    bool bigEndian = false, floatingPoint = false;
};
struct Converter {
    using Decode = void (*)(float*, const void*, std::size_t) noexcept;
    using Encode = void (*)(void*, const float*, std::size_t) noexcept;
    Decode decode = nullptr;
    Encode encode = nullptr;
    unsigned bytes = 0;
    explicit operator bool() const noexcept { return decode && encode; }
};
template<unsigned Bytes, bool BigEndian>
inline std::uint64_t readWord(const unsigned char* source) noexcept {
    std::uint64_t result = 0;
    for (unsigned byte = 0; byte < Bytes; ++byte)
        result |= std::uint64_t(source[byte]) << ((BigEndian ? Bytes - byte - 1 : byte) * 8);
    return result;
}
template<unsigned Bytes, bool BigEndian>
inline void writeWord(unsigned char* destination, std::uint64_t value) noexcept {
    for (unsigned byte = 0; byte < Bytes; ++byte)
        destination[byte] = static_cast<unsigned char>(value >> ((BigEndian ? Bytes - byte - 1 : byte) * 8));
}
template<unsigned Bytes, unsigned Bits, bool BigEndian>
void decodeInteger(float* destination, const void* source, std::size_t count) noexcept {
    const auto* bytes = static_cast<const unsigned char*>(source);
    constexpr auto sign = std::uint64_t(1) << (Bits - 1), range = std::uint64_t(1) << Bits;
    constexpr double inverse = 1.0 / double(sign);
    for (std::size_t frame = 0; frame < count; ++frame) {
        const auto raw = readWord<Bytes, BigEndian>(bytes + frame * Bytes) & (range - 1);
        const auto sample = (raw & sign) ? std::int64_t(raw) - std::int64_t(range) : std::int64_t(raw);
        destination[frame] = static_cast<float>(double(sample) * inverse);
    }
}
template<unsigned Bytes, unsigned Bits, bool BigEndian>
void encodeInteger(void* destination, const float* source, std::size_t count) noexcept {
    auto* bytes = static_cast<unsigned char*>(destination);
    constexpr auto scale = std::int64_t(1) << (Bits - 1);
    for (std::size_t frame = 0; frame < count; ++frame) {
        const double finite = std::isfinite(source[frame]) ? source[frame] : 0.;
        const auto sample = std::clamp(static_cast<std::int64_t>(std::llround(std::clamp(finite, -1., 1.) * double(scale))), -scale, scale - 1);
        writeWord<Bytes, BigEndian>(bytes + frame * Bytes, static_cast<std::uint64_t>(sample));
    }
}
template<unsigned Bytes, bool BigEndian>
void decodeFloat(float* destination, const void* source, std::size_t count) noexcept {
    const auto* bytes = static_cast<const unsigned char*>(source);
    for (std::size_t frame = 0; frame < count; ++frame) {
        const auto word = readWord<Bytes, BigEndian>(bytes + frame * Bytes);
        double sample;
        if constexpr (Bytes == 4) {
            const auto word32 = static_cast<std::uint32_t>(word); float value;
            std::memcpy(&value, &word32, sizeof(value)); sample = value;
        } else std::memcpy(&sample, &word, sizeof(sample));
        destination[frame] = std::isfinite(sample) && std::abs(sample) <= std::numeric_limits<float>::max() ? static_cast<float>(sample) : 0.f;
    }
}
template<unsigned Bytes, bool BigEndian>
void encodeFloat(void* destination, const float* source, std::size_t count) noexcept {
    auto* bytes = static_cast<unsigned char*>(destination);
    for (std::size_t frame = 0; frame < count; ++frame) {
        const auto sample = std::isfinite(source[frame]) ? source[frame] : 0.f;
        std::uint64_t word = 0;
        if constexpr (Bytes == 4) {
            std::uint32_t word32; std::memcpy(&word32, &sample, sizeof(sample)); word = word32;
        } else { const double value = sample; std::memcpy(&word, &value, sizeof(value)); }
        writeWord<Bytes, BigEndian>(bytes + frame * Bytes, word);
    }
}
template<bool BigEndian>
inline Converter makeConverter(PCMFormat format) noexcept {
    if (format.floatingPoint) {
        if (format.storageBytes == 4 && format.validBits == 32) return {decodeFloat<4, BigEndian>, encodeFloat<4, BigEndian>, 4};
        if (format.storageBytes == 8 && format.validBits == 64) return {decodeFloat<8, BigEndian>, encodeFloat<8, BigEndian>, 8};
    } else {
        if (format.storageBytes == 2 && format.validBits == 16) return {decodeInteger<2,16,BigEndian>, encodeInteger<2,16,BigEndian>, 2};
        if (format.storageBytes == 3 && format.validBits == 24) return {decodeInteger<3,24,BigEndian>, encodeInteger<3,24,BigEndian>, 3};
        if (format.storageBytes == 4) switch (format.validBits) {
            case 16: return {decodeInteger<4,16,BigEndian>, encodeInteger<4,16,BigEndian>, 4};
            case 18: return {decodeInteger<4,18,BigEndian>, encodeInteger<4,18,BigEndian>, 4};
            case 20: return {decodeInteger<4,20,BigEndian>, encodeInteger<4,20,BigEndian>, 4};
            case 24: return {decodeInteger<4,24,BigEndian>, encodeInteger<4,24,BigEndian>, 4};
            case 32: return {decodeInteger<4,32,BigEndian>, encodeInteger<4,32,BigEndian>, 4};
        }
    }
    return {};
}
inline Converter makeConverter(PCMFormat format) noexcept {
    return format.bigEndian ? makeConverter<true>(format) : makeConverter<false>(format);
}
} // namespace catlive::native::audio::asio_detail
