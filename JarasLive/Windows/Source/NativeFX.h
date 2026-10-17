#pragma once
#include "Common.h"
#include "../../WindowsNative/Source/VST3Host.h"
namespace catlive {
class NativeFX {
public:
    NativeFX();~NativeFX();
    void swap(NativeFX &) noexcept;
    void prepare(const var& settings,double sampleRate,const NativeFX *previous=nullptr);
    void process(AudioBuffer<float>&,int samples,double seconds=0,bool playing=true,const MidiBuffer *midi=nullptr);
    bool hasExternal() const;
    std::shared_ptr<native::vst3::Processor> external(const String &key) const;
    void captureExternalState(var &) const;
    StringArray unsupported;
private:
    struct Effect;
    std::vector<std::unique_ptr<Effect>> effects;
};
}
