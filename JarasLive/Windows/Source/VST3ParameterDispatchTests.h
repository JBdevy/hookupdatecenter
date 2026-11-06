#pragma once
#include "../../WindowsNative/Source/VST3ParameterSlots.h"

namespace catlive::vst3ParameterDispatchTests {
template<class Register> void run(Register&& test) {
    test("VST3 large preset dispatch preserves sparse IDs, hidden MIDI and next-block queues", [] {
        const auto require=[](bool ok,const char* message){if(!ok)throw std::runtime_error(message);};
        constexpr int parameters=32768, midiMappings=16*130;
        std::vector<std::pair<std::uint32_t,int>> identifiers;
        identifiers.reserve(parameters+midiMappings+1);
        const auto parameterID=[](int index){return 100000u+unsigned(parameters-index)*3u;};
        for(int i=0;i<parameters;++i)identifiers.emplace_back(parameterID(i),i);
        // Every MIDI channel may expose 128 CCs plus aftertouch/pitch bend.
        // Some plugins do not list those hidden IDs as ordinary parameters.
        for(int i=0;i<midiMappings;++i)identifiers.emplace_back(unsigned(i),-1);
        identifiers.emplace_back(parameterID(17),-1); // MIDI can share a normal ID.
        native::vst3::ParameterSlots slots;slots.prepare(std::move(identifiers));
        require(slots.capacity()==parameters+midiMappings,"Shared MIDI ID created duplicate storage");
        for(int i=0;i<parameters;++i)
            require(slots.parameterIndex(parameterID(i))==i,"Sparse parameter IDs selected another control");
        require(slots.parameterIndex(0)==-1 && slots.parameterIndex(99999)==-1,"Hidden/unknown parameter reached controller edits");
        for(int block=0;block<3;++block) {
            slots.beginBlock();
            for(int i=parameters-1;i>=0;--i) {
                int index=-1;bool inserted=false;
                require(slots.queue(parameterID(i),index,inserted)&&inserted&&index==parameters-1-i,
                        "Preset dispatch lost a parameter or reused an earlier block queue");
                int repeated=-1;bool duplicate=true;
                require(slots.queue(parameterID(i),repeated,duplicate)&&!duplicate&&repeated==index,
                        "Repeated automation/MIDI edits did not coalesce to their parameter queue");
            }
            for(int i=0;i<midiMappings;++i) {
                int index=-1;bool inserted=false;
                require(slots.queue(unsigned(i),index,inserted)&&inserted&&index==parameters+i,
                        "A hidden MIDI mapping was dropped after the full preset");
            }
            int index=123;bool inserted=true;
            require(!slots.queue(99999,index,inserted)&&index==-1&&!inserted&&slots.count()==slots.capacity(),
                    "Unknown ID modified a prepared queue");
        }
        slots.beginBlock();
        require(slots.count()==0,"Unedited block retained preset changes");
        int index=-1;bool inserted=false;
        require(slots.queue(parameterID(17),index,inserted)&&inserted&&index==0&&slots.count()==1,
                "Single edit after a full preset retained stale dispatch indices");
    });
}
}
