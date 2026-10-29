#pragma once
#include "Common.h"
namespace catlive {
class Instrument {
public:
    Instrument();~Instrument();
    void prepare(double sampleRate);
    void loadSoundFont(const File&);
    std::unique_ptr<Instrument> copy()const;
    void configure(const var &,bool drums=false);
    void render(AudioBuffer<float>&,const MidiBuffer&,int samples,int start=0);
    void stop();
    String name;
private:
    struct Impl;std::unique_ptr<Impl> impl;
};
}
