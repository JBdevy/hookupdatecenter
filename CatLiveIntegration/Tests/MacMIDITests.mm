#include "Bridge.h"
#include "httplib.h"
#import <CoreMIDI/CoreMIDI.h>
#include <mutex>
#include <thread>
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
        send();std::this_thread::sleep_for(std::chrono::milliseconds(200));
        auto messages=capture.snapshot();bool full=false;int quarters=0;
        for(auto& bytes:messages) {
            if(bytes.size()==10 && bytes[0]==0xf0) {full=bytes[5]==0x61 && bytes[6]==2 && bytes[7]==3;}
            if(bytes.size()==2 && bytes[0]==0xf1)++quarters;
        }
        require(full && quarters>=8,"Actual MIDI sends full-frame position and all quarter-frame pieces");
        state["sequence"]=2;state["playing"]=false;send();std::this_thread::sleep_for(std::chrono::milliseconds(70));
        auto stopped=capture.snapshot().size();std::this_thread::sleep_for(std::chrono::milliseconds(100));
        require(capture.snapshot().size()==stopped,"Stop stops continuous MTC output");
        bridge.stop();
    } catch(...) {MIDIEndpointDispose(destination);MIDIClientDispose(client);throw;}
    MIDIEndpointDispose(destination);MIDIClientDispose(client);
}
