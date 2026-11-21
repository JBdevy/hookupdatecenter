#pragma once
#include "Common.h"
#include "MeterRepaint.h"
namespace catlive {
// Store actual gain; map only the control's position through the Mac dB range.
class GainFader final : public ParameterSlider {
    std::array<float, 2> levels{};
    meterDisplay::RepaintState meterPaint;
    float reduction = -1.f;

  public:
    std::function<void()> mapControl;
    void mouseDown(const MouseEvent &event) override {
        if (event.mods.isPopupMenu() && mapControl) { mapControl(); return; }
        ParameterSlider::mouseDown(event);
    }
    void setMeterLevels(const std::array<float, 2>& next) {
        levels = next;
        if (meterPaint.update(levels)) repaint();
    }
    void setGainReduction(float db) {
        const auto next = db < 0.f ? -1.f : std::round(std::min(24.f, db) * 10.f) / 10.f;
        if (reduction != next) { reduction = next; repaint(); }
    }
    float gainReduction() const { return reduction; }
    const std::array<float, 2>& meterLevels() const { return levels; }

    GainFader() { setRange(0, std::pow(10., 12. / 20.), 0); }
    double proportionOfLengthToValue(double proportion) override {
        return proportion <= 0 ? 0 : std::pow(10., (-60 + jlimit(0., 1., proportion) * 72) / 20.);
    }
    double valueToProportionOfLength(double gain) override {
        return gain <= 0 ? 0 : jlimit(0., 1., (20 * std::log10(gain) + 60) / 72.);
    }
};
}
