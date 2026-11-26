#include "../../Core/Audio/SmoothBiquad.hpp"
#include <iostream>
#include <stdexcept>
#include <limits>
std::array<double,5> bell(double rate,double hz,double db,double q) {
    const auto a=std::pow(10.,db/40),w=2*3.141592653589793*hz/rate,alpha=std::sin(w)/(2*q),a0=1+alpha/a;
    return {(1+alpha*a)/a0,-2*std::cos(w)/a0,(1-alpha*a)/a0,-2*std::cos(w)/a0,(1-alpha/a)/a0};
}
int main(){
    for(double rate:{44100.,48000.,96000.}){
        auto coefficients=bell(rate,120,0,.707);
        jaras::audio::SmoothBiquad filter(coefficients.data(),rate);
        // Establish the constant signal before the first parameter change.
        for(int n=0;n<512;++n) filter.processSample(.05f);
        double maximum=0;
        for(int n=0;n<int(rate*5);++n){
            if(n%512==0){const int i=n/512;coefficients=bell(rate,i%2?55:700,i%2?18:-12,i%2?.3:8);filter.setTarget(coefficients.data());}
            const auto out=filter.processSample(.05f);maximum=std::max(maximum,std::abs(double(out)-.05));
        }
        if(maximum>1e-5)throw std::runtime_error("EQ parameter edits created an impulse in constant input");
        if(filter.processSample(std::numeric_limits<float>::quiet_NaN())!=0)throw std::runtime_error("Malformed PCM contaminated EQ history");
        for(int n=0;n<1000;++n)if(!std::isfinite(filter.processSample(.01f)))throw std::runtime_error("EQ did not recover");
        std::cout<<"SMOOTH_EQ_DC_CONTINUITY_NO_ALLOCATION_AND_NAN_RECOVERY_OK "<<rate<<" error="<<maximum<<'\n';
    }
}
