#include "../../Windows/Source/WaveformDetailPeaks.h"
#include <array>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>

static void require(bool value, const char *message) {
    if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
    using catlive::WaveformDetailPeaks;
    constexpr int pageFrames=65536, frames=pageFrames+173;
    std::array<std::vector<float>,3> pcm;
    for(auto &channel:pcm)channel.assign(frames,0);
    // Isolated transients, including both sides of a decoder-page boundary.
    for(int frame:{127,4095,65535,65536,frames-1}) {
        pcm[0][frame]=.9f;pcm[1][frame]=-.7f;
    }
    std::mt19937 random(42);
    for(int frame=0;frame<frames;++frame)pcm[2][frame]=(int(random()%2001)-1000)/1000.f;
    std::array<WaveformDetailPeaks,2> pages;
    int reads=0;
    for(int page=0;page<2;++page) {
        const int begin=page*pageFrames,count=std::min(pageFrames,frames-begin);
        pages[page].prepare(3,count,[&](int channel,int frame){++reads;return pcm[channel][begin+frame];});
        require(pages[page].bytes()==std::size_t((count+15)/16)*3*8,"Summary memory is one eighth of PCM, with a bounded EOF bucket");
    }
    require(reads==3*frames,"Every PCM sample is inspected only once during preparation");
    const auto range=[&](int channel,int begin,int end) {
        float low=std::numeric_limits<float>::max(),high=-low;
        while(begin<end) {
            const int page=begin/pageFrames,origin=page*pageFrames,finish=std::min(end,origin+pageFrames);
            const auto value=pages[page].alignedRange(channel,begin-origin,finish-origin);
            low=std::min(low,value.first);high=std::max(high,value.second);begin=finish;
        }
        return std::pair<float,float>{low,high};
    };
    for(int step:{32,48,64,80,96,128,192,256}) {
        require(WaveformDetailPeaks::needsDetail(step),"Intermediate LOD selects detail instead of 256-sample file peaks");
        for(int begin=0;begin<frames;begin+=step)for(int channel=0;channel<3;++channel) {
            const int end=std::min(frames,begin+step);
            const auto expected=std::minmax_element(pcm[channel].begin()+begin,pcm[channel].begin()+end);
            const auto actual=range(channel,begin,end);
            require(actual.first==*expected.first&&actual.second==*expected.second,"Every detail bucket exactly matches PCM, including page crossings and EOF");
        }
    }
    require(!WaveformDetailPeaks::needsDetail(256.001),"Distant views retain the small persistent overview cache");
    require(range(0,0,64).second==0&&range(0,64,128).second==.9f&&range(0,128,192).second==0&&range(0,192,256).second==0,
            "An impulse belongs only to its 64-sample interval, not four overview columns");
    require(reads==3*frames,"Paint-time summary queries do not revisit PCM");
    for(float density:{1.f,1.25f,1.5f,2.f,3.f,8.f}) {
        const auto silent=WaveformDetailPeaks::displayEdges(0,0,40,1,density);
        require(std::abs((silent.second-silent.first)*density-1)<.0001f,"Silence remains one physical pixel at every DPI");
        require(std::abs(WaveformDetailPeaks::pixelWidth(density)*density-1)<.0001f,"PCM contours use physical pixels, not logical points");
        const auto ordinary=WaveformDetailPeaks::displayEdges(-.5f,1,40,20,density);
        const auto inverted=WaveformDetailPeaks::displayEdges(-.5f,1,40,-20,density);
        require(ordinary==std::pair<float,float>{20,50}&&inverted==std::pair<float,float>{30,60},"Signed amplitude and inversion preserve extrema");
    }
    std::cout<<"PASS: waveform detail impulse, signed peaks, page boundaries, EOF, cache cost, silence and physical DPI\n";
}
