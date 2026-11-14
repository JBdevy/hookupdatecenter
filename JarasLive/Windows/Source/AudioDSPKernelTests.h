#pragma once
#include "AudioItemGain.h"
#include "SharedClipAudio.h"
namespace catlive::audioDSPKernelTests {
inline void gain() {
    AudioBuffer<float> buffer(2,517),reference(2,517);
    for(int mode=0;mode<5;++mode)for(double gain:{0.,.15,1.,2.5})for(double pan:{-1.,-.25,0.,.75,1.}) {
        for(int i=0;i<517;++i){buffer.setSample(0,i,std::sin(i*.17f));buffer.setSample(1,i,std::cos(i*.13f));}
        reference.makeCopyOf(buffer);
        for(int i=0;i<513;++i) {
            float a=reference.getSample(0,i),b=reference.getSample(1,i);
            if(mode==1)b=a;else if(mode==2)a=b;else if(mode==3)a=b=(a+b)*.5f;else if(mode==4)std::swap(a,b);
            float left=float(gain),right=left;
            if(pan>0)left*=1-float(pan);else right*=1+float(pan);
            reference.setSample(0,i,a*left);reference.setSample(1,i,b*right);
        }
        applyConstantItemGain(buffer,513,gain,pan,mode);
        for(int c=0;c<2;++c)for(int i=0;i<517;++i)
            if(buffer.getSample(c,i)!=reference.getSample(c,i))throw std::runtime_error("Constant gain changed channel-mode PCM or wrote past the block");
    }
}
inline void fft() {
    using Complex=std::complex<float>;
    for(int count:{8,16,32,128,1024,4096,8192}) {
        signalsmith::linear::SimpleFFT<float> reference(count);
        signalsmith::linear::Pow2FFT<float> fast(count);
        // Offset the buffers to exercise the backend's alignment handling.
        std::vector<Complex> input(count+1),expected(count+1),output(count+1),inverse(count+1);
        for(int i=0;i<count;++i)input[i+1]={std::sin(i*.173f)+.2f*std::cos(i*.057f),std::cos(i*.231f)};
        reference.fft(input.data()+1,expected.data()+1);fast.fft(input.data()+1,output.data()+1);
        fast.ifft(output.data()+1,inverse.data()+1);
        double signal=0,error=0;
        for(int i=1;i<=count;++i){signal+=std::norm(expected[i]);error+=std::norm(expected[i]-output[i]);
            if(std::abs(inverse[i]/float(count)-input[i])>2e-5f)throw std::runtime_error("SIMD FFT round trip changed gain or phase");}
        if(error>signal*1e-11)throw std::runtime_error("SIMD FFT differs from portable reference");
        std::vector<float> inR(count+1),inI(count+1),outR(count+1),outI(count+1);
        for(int i=1;i<=count;++i){inR[i]=input[i].real();inI[i]=input[i].imag();}
        fast.fft(inR.data()+1,inI.data()+1,outR.data()+1,outI.data()+1);
        for(int i=1;i<=count;++i)if(std::abs(Complex(outR[i],outI[i])-output[i])>1e-4f)
            throw std::runtime_error("SIMD FFT split channel layout differs");
        signalsmith::linear::Pow2FFT<float> moved(std::move(fast));
        moved.ifft(output.data()+1,inverse.data()+1);
        for(int i=1;i<=count;++i)if(std::abs(inverse[i]/float(count)-input[i])>2e-5f)
            throw std::runtime_error("Moved SIMD FFT lost its prepared state");
    }
}
}
