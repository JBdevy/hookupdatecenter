#pragma once
#include "Common.h"
namespace catlive {
// Store actual gain; map only the control's position through the Mac dB range.
class GainFader final : public ParameterSlider {
  public:
    GainFader() { setRange(0, std::pow(10., 12. / 20.), 0); }
    void setMonitorOff(bool off) {
        const auto colour = off ? Colours::red : Colours::white.withAlpha(.25f);
        if (!isColourSpecified(Slider::trackColourId) || findColour(Slider::trackColourId) != colour)
            setColour(Slider::trackColourId, colour);
    }
    double proportionOfLengthToValue(double proportion) override {
        return proportion <= 0 ? 0 : std::pow(10., (-60 + jlimit(0., 1., proportion) * 72) / 20.);
    }
    double valueToProportionOfLength(double gain) override {
        return gain <= 0 ? 0 : jlimit(0., 1., (20 * std::log10(gain) + 60) / 72.);
    }
};
}
