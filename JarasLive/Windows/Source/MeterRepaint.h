#pragma once
#include <algorithm>
#include <array>
#include <cmath>

namespace catlive::meterDisplay {
// Compare the displayed level, not the raw sample. Silence below the scale
// and clipping above it must not continuously invalidate an unchanged bar.
inline constexpr float fractionForDB(float db) noexcept {
    return std::clamp((db + 60.f) / 72.f, 0.f, 1.f);
}
inline float fraction(float amplitude) noexcept {
    return amplitude > 0 && std::isfinite(amplitude)
        ? fractionForDB(20.f * std::log10(amplitude)) : 0.f;
}
class RepaintState {
public:
    bool update(const std::array<float, 2>& amplitude) noexcept {
        const std::array<float, 2> next{fraction(amplitude[0]), fraction(amplitude[1])};
        const std::array<bool, 2> nextClipping{amplitude[0] > 1.f, amplitude[1] > 1.f};
        const bool changed = !valid || next != shown || nextClipping != clipping;
        shown = next; clipping = nextClipping;
        valid = true;
        return changed;
    }
    void invalidate() noexcept { valid = false; }
private:
    std::array<float, 2> shown{};
    std::array<bool, 2> clipping{};
    bool valid = false;
};
}
