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
    require(!meter.update({2,4}), "Above-scale input changed saturated bars");
    meter.invalidate();
    require(meter.update({2,4}), "Resized meter failed to repaint");
    require(fraction(std::numeric_limits<float>::quiet_NaN())==0 &&
            fraction(std::numeric_limits<float>::infinity())==0 && fraction(-1)==0,
            "Invalid meter sample must be silent");
    std::cout << "PASS: idle, live input, stereo, decay, saturation and resize\n";
}
