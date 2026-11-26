#include "../../Core/MIDI/ProgramChangePlayback.hpp"
#include "../../Core/Transport/Engine.hpp"
#include <cassert>
#include <iostream>
int main(){
    using namespace jaras;
    std::vector<ProgramChangeMarker> m{{"start",0,0,1},{"a",1,127,16},{"b",2,7,3}};
    std::vector<std::string> sent;auto send=[&](const auto &v){sent.push_back(v.id);};
    ProgramChangeCursor c;c.advance(m,0,true,true,send);c.advance(m,.001,true,false,send);
    c.advance(m,1.1,true,false,send);c.advance(m,1.2,true,false,send);
    assert((sent==std::vector<std::string>{"start","a"}));
    c.advance(m,2.5,true,true,send);assert(sent.size()==2);
    c.advance(m,1,true,true,send);assert(sent.back()=="a"&&sent.size()==3);
    ProgramChangeCursor main=c;main.advance(m,1.01,true,false,send);assert(sent.size()==3);
    main.advance(m,2.1,true,false,send);assert(sent.back()=="b");
    main.advance(m,0,false,true,send);main.advance(m,0,true,false,send);assert(sent.back()=="start");
    std::cout<<"PROGRAM_CHANGE_EXACT_START_CROSSINGS_JUMPS_AND_PROMOTION_OK\n";
}
