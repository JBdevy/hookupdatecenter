#include "../../Core/Audio/StopTransition.hpp"
#include <cassert>
#include <iostream>
#include <vector>
int main() {
    for (double rate : {44100., 48000., 96000.}) {
        jaras::audio::StopTransition transition;
        std::vector<float> left(512), right(512);
        float *output[]{left.data(), right.data()};
        for (unsigned i=0;i<512;++i) { left[i]=i%2 ? .5f : -.5f; right[i]=-left[i]; }
        transition.process(output,2,512);
        transition.begin(rate);
        std::fill(left.begin(),left.end(),0); std::fill(right.begin(),right.end(),0);
        transition.process(output,2,512);
        const unsigned length=unsigned(rate*.002);
        double dc=0;
        for(unsigned i=0;i<512;++i) {
            assert(std::isfinite(left[i])&&left[i]==-right[i]);
            if(i>=length)assert(left[i]==0);
            dc+=left[i];
        }
        assert(std::abs(dc)<.51); // A held .5 sample would produce a large pulse.
        transition.begin(rate); transition.cancel();
        std::fill(left.begin(),left.end(),.25f); std::fill(right.begin(),right.end(),.25f);
        transition.process(output,2,512);
        for(auto value:left)assert(value==.25f);
    }
    std::cout<<"STOP_TRANSITION_WAVEFORM_NO_DC_PULSE_FINITE_STEREO_AND_RESTART_OK\n";
}