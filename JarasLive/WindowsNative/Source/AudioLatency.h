#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <vector>
#include "../../Core/Audio/PiecewiseTimeMap.hpp"
namespace catlive::native {
// Allocated on the graph/control thread. A render call only copies floats and
// advances counters; discontinuities clear logically by starting a new epoch.
class StereoDelay {
    std::vector<std::array<float,2>> ring;
    uint64_t position=0,valid=0;
    int64_t expected=0;
    bool moving=false;
public:
    explicit StereoDelay(unsigned frames=0):ring(frames){}
    unsigned latency()const{return unsigned(ring.size());}
    void reset()noexcept{valid=0;moving=false;}
    void process(float *left,float *right,unsigned count,int64_t sample,bool playing)noexcept{
        if(ring.empty())return;
        if(moving!=playing||(playing&&sample!=expected))valid=0;
        moving=playing;expected=sample+count;
        for(unsigned n=0;n<count;n++){
            auto &slot=ring[size_t(position%ring.size())];
            const std::array<float,2> input{left[n],right[n]};
            left[n]=valid>=ring.size()?slot[0]:0;right[n]=valid>=ring.size()?slot[1]:0;
            slot=input;++position;++valid;
        }
    }
};
// The transport source clock is intentionally separate from its audible clock.
// Keeping a sample history also handles loop wraps and scheduled jumps exactly.
class TimelineDelay {
public:
    struct Frame { double position=0; bool moving=false; };
    explicit TimelineDelay(unsigned frames=0):ring(frames){}
    // Ring entries remain in canonical coordinates across tempo edits. Prepare
    // the composed map on control, then swap once at the block boundary instead
    // of rewriting seconds of per-sample history in the callback.
    catlive::audio::PiecewiseTimeMap prepareRemap(const catlive::audio::PiecewiseTimeMap& edit) const {
        return mapping.followedBy(edit);
    }
    void adoptRemap(catlive::audio::PiecewiseTimeMap& prepared)noexcept{mapping.swap(prepared);}
    void reset(double position)noexcept{valid=0;fallback={mapping.inverse(position),false};}
    Frame previous(unsigned framesAgo)const noexcept {
        auto result=(!framesAgo||framesAgo>valid||framesAgo>ring.size())?fallback:ring[size_t((cursor-framesAgo)%ring.size())];
        result.position=mapping.position(result.position);return result;
    }
    Frame process(Frame input)noexcept {
        if(ring.empty())return input;
        auto &slot=ring[size_t(cursor%ring.size())];
        auto result=valid>=ring.size()?slot:fallback;
        input.position=mapping.inverse(input.position);
        slot=input;++cursor;++valid;result.position=mapping.position(result.position);return result;
    }
private:
    std::vector<Frame> ring;
    uint64_t cursor=0,valid=0;
    Frame fallback;
    catlive::audio::PiecewiseTimeMap mapping;
};

}
