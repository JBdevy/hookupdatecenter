#pragma once
#include "Common.h"
namespace catlive {
class NativeFX {
public:
    NativeFX();~NativeFX();
    void swap(NativeFX &) noexcept;
    void prepare(const var& settings,double sampleRate);
    void process(AudioBuffer<float>&,int samples);
    StringArray unsupported;
private:
    struct Effect;
    std::vector<std::unique_ptr<Effect>> effects;
};
}
