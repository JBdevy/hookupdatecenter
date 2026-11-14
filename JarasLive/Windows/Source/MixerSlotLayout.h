#pragma once
#include <algorithm>
namespace catlive {
struct MixerSlotSections {
    int plugins=0,outputs=0,divider=0;
    MixerSlotSections(int height,int count) {
        height=std::max(0,height);
        outputs=count>0 && height>=87 ? std::min(std::min(2,count)*21-2,height-68) : 0;
        divider=outputs>0?5:0;plugins=std::max(0,height-outputs-divider);
    }
};
}
