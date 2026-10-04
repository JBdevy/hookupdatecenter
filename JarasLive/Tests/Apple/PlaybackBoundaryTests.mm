#import "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>
int main() {
    ItemFadeKernel gate; gate.rate=48000;
    float data[1024]; std::fill(data,data+1024,1.f);
    AudioBufferList buffers{};buffers.mNumberBuffers=1;buffers.mBuffers[0]={1,sizeof(data),data};
    AudioTimeStamp time{};time.mFlags=kAudioTimeStampHostTimeValid;time.mHostTime=mach_absolute_time();
    const auto end=time.mHostTime+uint64_t((512.0/gate.rate)/gate.hostSecondsPerTick);
    gate.boundaryHost.store(end);gate.gate(&buffers,1024,&time);
    assert(data[300]==1.f && data[450]>0.f && data[450]<1.f);
    assert(data[512]==0.f && data[1023]==0.f);
    for(int i=301;i<1024;++i) assert(data[i]<=data[i-1]);
    gate.boundaryHost.store(0);std::fill(data,data+1024,1.f);gate.gate(&buffers,1024,&time);
    assert(data[1023]==1.f); // cancellation/recycled player clears the cutoff
    std::cout<<"PLAYBACK_BOUNDARY_SAMPLE_CLOCK_OK\n";
}
