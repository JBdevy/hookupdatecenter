#include "../../Windows/Source/MeterRepaint.h"
#include <iostream>
#include <limits>
#include <stdexcept>

int main() {
    using namespace catlive::meterDisplay;
    const auto require=[](bool value,const char* message) { if (!value) throw std::runtime_error(message); };
    RepaintState meter;
    require(meter.update({0,0}), "Initial meter must paint");
    for (int i=0;i<3600;++i)
        require(!meter.update({0,0}), "Silent meter kept repainting");
    require(!meter.update({.0001f,.00001f}), "Below-scale input dirtied an empty meter");
    require(meter.update({.2f,0}), "Live input must wake the meter even while stopped");
    require(!meter.update({.2f,0}), "Unchanged level kept repainting");
    require(meter.update({.2f,.3f}), "Right channel change was lost");
    require(meter.update({.1f,.15f}), "Meter fall must repaint");
    require(meter.update({0,0}), "Last decay frame must clear the bars");
    require(!meter.update({0,0}), "Settled decay kept repainting");
    require(meter.update({1,1}), "Full-scale input did not paint");
    require(meter.update({2,4}), "Positive peaks must rise past the 0 dB mark");
    require(meter.update({4,5}) && !meter.update({5,6}), "Only levels above +12 dB saturate the rail");
    for (float db : {-60.f, -24.f, -12.f, -6.f, 0.f, .1f, 6.f, 12.f}) {
        const float gain = std::pow(10.f, db / 20.f);
        require(std::abs(fraction(gain) - (db + 60.f) / 72.f) < .00001f, "Meter misses its scale mark");
    }
    meter.invalidate();
    require(meter.update({2,4}), "Resized meter failed to repaint");
    require(fraction(std::numeric_limits<float>::quiet_NaN())==0 &&
            fraction(std::numeric_limits<float>::infinity())==0 && fraction(-1)==0,
            "Invalid meter sample must be silent");
    require(meter.update({.5f, .2f}) && meter.update({.2f, .5f}),
            "Swapping channels at the same peak must update the compact stereo rail");
    std::cout << "PASS: idle, live input, stereo, decay, saturation and resize\n";
}
