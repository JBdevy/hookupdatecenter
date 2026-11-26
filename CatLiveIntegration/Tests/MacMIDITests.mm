#include "Bridge.h"
#include "httplib.h"
#import <CoreMIDI/CoreMIDI.h>
#include <mutex>
#include <thread>
#include <iostream>
using namespace integration;
extern void require(bool,const char*);
namespace {
struct Capture {
    std::mutex mutex;std::vector<std::vector<uint8_t>> messages;
    static void receive(const MIDIPacketList* list,void* context,void*) {
        auto& self=*static_cast<Capture*>(context);std::lock_guard lock(self.mutex);
        auto packet=&list->packet[0];
        for(UInt32 i=0;i<list->numPackets;++i) {self.messages.emplace_back(packet->data,packet->data+packet->length);packet=MIDIPacketNext(packet);}
    }
    auto snapshot(){std::lock_guard lock(mutex);return messages;}
};
}
void testMIDI() {
    MIDIClientRef client=0;MIDIEndpointRef destination=0;Capture capture;
    require(MIDIClientCreate(CFSTR("Integration Test"),nullptr,nullptr,&client)==noErr,"CoreMIDI test client");
    require(MIDIDestinationCreate(client,CFSTR("Integration Test Destination"),Capture::receive,&capture,&destination)==noErr,"CoreMIDI test destination");
    try {
        SInt32 identifier=0;MIDIObjectGetIntegerProperty(destination,kMIDIPropertyUniqueID,&identifier);
        httplib::Server probe;int port=probe.bind_to_any_port("127.0.0.1");probe.stop();Bridge bridge;bridge.start("127.0.0.1",port);
        httplib::Client http("127.0.0.1",port);
        auto result=http.Post("/v1/connect",JSON({{"protocol",1},{"name","MIDI test"},{"mtc",true},{"midiOutput",std::to_string(identifier)}}).dump(),"application/json");
        require(result && result->status==200,"MTC connection opens selected receiver port");
        auto token=JSON::parse(result->body)["token"].get<std::string>();
        JSON state={{"sequence",1},{"position",3723.0},{"playing",true}};
        auto send=[&] {http.Post("/v1/state",{{"X-CatLive-Token",token}},state.dump(),"application/json");};
        // CoreMIDI may batch multiple MIDI messages in one packet, especially
        // on a freshly started MIDI server in CI. Decode messages, not packets.
        bool full=false;int quarters=0;const auto started=Clock::now();int sequence=1;
        do {
            state["sequence"]=sequence++;state["position"]=3723.0+std::chrono::duration<double>(Clock::now()-started).count();
            send();CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
            std::vector<uint8_t> stream;
            for(auto& packet:capture.snapshot())stream.insert(stream.end(),packet.begin(),packet.end());
            quarters=0;full=false;
            for(size_t i=0;i<stream.size();) {
                if(stream[i]==0xf1 && i+1<stream.size()) {++quarters;i+=2;}
                else if(stream[i]==0xf0) {
                    auto end=std::find(stream.begin()+i,stream.end(),uint8_t(0xf7));
                    if(end==stream.end())break;
                    if(end-(stream.begin()+i)==9 && stream[i+1]==0x7f && stream[i+3]==1 && stream[i+4]==1)
                        full=full||(stream[i+5]==0x61 && stream[i+6]==2 && (stream[i+7]==3 || stream[i+7]==4));
                    i=size_t(end-stream.begin())+1;
                } else ++i;
            }
        } while((!full || quarters<8) && Clock::now()-started<std::chrono::seconds(2));
        if(!full || quarters<8)std::cerr<<"MIDI packets="<<capture.snapshot().size()<<" quarter messages="<<quarters<<" full-frame="<<full<<'\n';
        require(full && quarters>=8,"Actual MIDI sends full-frame position and all quarter-frame pieces");
        state["sequence"]=sequence;state["playing"]=false;send();CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.07,false);
        auto stopped=capture.snapshot().size();CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
        require(capture.snapshot().size()==stopped,"Stop stops continuous MTC output");
        bridge.stop();
    } catch(...) {MIDIEndpointDispose(destination);MIDIClientDispose(client);throw;}
    MIDIEndpointDispose(destination);MIDIClientDispose(client);
}
