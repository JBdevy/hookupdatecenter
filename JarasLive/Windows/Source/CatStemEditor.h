#pragma once
#include "Common.h"
#include "../../WindowsNative/Source/StemSeparator.h"
namespace catlive {
namespace stemMix {
inline var defaults() {
    auto mix=object();Array<var> sources;
    for(int i=0;i<5;i++){auto source=object();put(source,"gain",1.);put(source,"mute",false);put(source,"solo",false);sources.add(source);}
    put(mix,"sources",sources);return mix;
}
inline native::stem::Mix decode(const var &value) {
    native::stem::Mix mix;mix.enabled=flag(value,"stemSeparatorEnabled");
    const auto sources=list(get(get(value,"stemMix"),"sources"));
    for(int i=0;i<std::min(5,sources.size());i++){
        mix.gains[size_t(i)]=(float)jlimit(0.,4.,num(sources[i],"gain",1));
        if(flag(sources[i],"mute"))mix.muteMask|=1u<<i;if(flag(sources[i],"solo"))mix.soloMask|=1u<<i;
    }
    return mix;
}
}
// Temporary Windows presentation; project settings remain portable to Mac.
class CatStemEditor final : public Component {
    String title;
public:
    CatStemEditor(String name, std::function<var()>, std::function<void(var,bool)>,
                  std::function<native::stem::Status()>) : title(std::move(name)) {}
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(19));
        g.drawText(native::stem::effectName,20,16,getWidth()-40,28,Justification::centredLeft);
        g.setColour(theme::secondary); g.setFont(theme::font(11));
        g.drawText(title,20,46,getWidth()-40,18,Justification::centredLeft);
        g.setColour(Colours::white); g.setFont(theme::mediumFont(16));
        g.drawText("Em desenvolvimento",getLocalBounds().reduced(20),Justification::centred);
    }
};
}
