#pragma once
#include <array>
#include <algorithm>
#include <cmath>
namespace jaras::audio {
// Render-owned, allocation-free filter. Coefficients and history are doubles
// so near-DC pole cancellation does not amplify Float32 rounding on bass bands.
class SmoothBiquad {
    std::array<double,5> current{1,0,0,0,0}, target=current;
    double x1=0,x2=0,y1=0,y2=0, smoothing=-std::expm1(-1.0/(48000.0*.005));
    bool moving=false;
public:
    SmoothBiquad() = default;
    template<class T> SmoothBiquad(const T* values,double rate) { setSampleRate(rate);setImmediate(values); }
    void setSampleRate(double rate) noexcept { smoothing=-std::expm1(-1.0/(std::max(1.0,rate)*.005)); }
    template<class T> void setImmediate(const T* values) noexcept {
        for(unsigned i=0;i<5;++i)current[i]=target[i]=double(values[i]);
        moving=false;reset();
    }
    template<class T> void setTarget(const T* values) noexcept {
        moving=false;
        for(unsigned i=0;i<5;++i){target[i]=double(values[i]);moving|=target[i]!=current[i];}
    }
    void reset() noexcept { x1=x2=y1=y2=0; }
    float processSample(float input) noexcept {
        if(moving){
            moving=false;
            for(unsigned i=0;i<5;++i){
                current[i]+=(target[i]-current[i])*smoothing;
                if(std::abs(target[i]-current[i])<1e-14*std::max(1.0,std::abs(target[i])))current[i]=target[i];
                else moving=true;
            }
        }
        if(!std::isfinite(input)){reset();return 0;}
        const double output=current[0]*input+current[1]*x1+current[2]*x2-current[3]*y1-current[4]*y2;
        if(!std::isfinite(output)||std::abs(output)>double(3.402823466e38F)){reset();return 0;}
        x2=x1;x1=input;y2=y1;y1=output;
        return float(output);
    }
};
}
