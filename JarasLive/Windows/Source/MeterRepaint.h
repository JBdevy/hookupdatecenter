#pragma once
#include <algorithm>
#include <array>
#include <cmath>

namespace catlive::meterDisplay {
// Compare the displayed level, not the raw sample. Silence below the scale
// and clipping above it must not continuously invalidate an unchanged bar.
inline float fraction(float amplitude) noexcept {
    return amplitude > 0 && std::isfinite(amplitude)
        ? std::clamp((20 * std::log10(amplitude) + 60) / 60, 0.f, 1.f) : 0.f;
}
class RepaintState {
public:
    bool update(const std::array<float, 2>& amplitude) noexcept {
        const std::array<float, 2> next{fraction(amplitude[0]), fraction(amplitude[1])};
        const bool changed = !valid || next != shown;
        shown = next;
        valid = true;
        return changed;
    }
    void invalidate() noexcept { valid = false; }
private:
    std::array<float, 2> shown{};
    bool valid = false;
};
}
