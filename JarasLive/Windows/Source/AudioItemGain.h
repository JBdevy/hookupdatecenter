#pragma once
#include "Common.h"
namespace catlive {
// Constant controls need one vector operation per channel, not an automation
// evaluation for every sample. Fades, envelopes and the start ramp stay on the
// sample-accurate path in AudioEngine.
inline void applyConstantItemGain(AudioBuffer<float>& buffer,int count,double gain,double pan,int mode) noexcept {
    auto *a=buffer.getWritePointer(0),*b=buffer.getWritePointer(1);
    float left=float(gain),right=left;
    if(pan>0)left*=1-float(pan);else right*=1+float(pan);
    if(mode==1)FloatVectorOperations::copy(b,a,count);
    else if(mode==2)FloatVectorOperations::copy(a,b,count);
    else if(mode==3) {
        FloatVectorOperations::add(a,b,count);
        FloatVectorOperations::multiply(a,.5f,count);
        FloatVectorOperations::copy(b,a,count);
    } else if(mode==4)for(int i=0;i<count;++i)std::swap(a[i],b[i]);
    if(left!=1)FloatVectorOperations::multiply(a,left,count);
    if(right!=1)FloatVectorOperations::multiply(b,right,count);
}
}
