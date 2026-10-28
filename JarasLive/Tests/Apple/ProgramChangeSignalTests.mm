#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <mach/mach_time.h>
#import "../../Apple/Bridge/JarasTimecode.h"
#include <mutex>
#include <memory>
#include <vector>
#include <array>
#include <cassert>
#include <thread>
int main(){ @autoreleasepool {
    MIDIClientRef client=0;MIDIEndpointRef destination=0;struct Capture { std::mutex mutex;std::vector<int> received; };auto capture=std::make_shared<Capture>();
    assert(MIDIClientCreate(CFSTR("CatLive PC test"),nullptr,nullptr,&client)==noErr);
    assert(MIDIDestinationCreateWithBlock(client,CFSTR("CatLive PC test destination"),&destination,^(const MIDIPacketList *list,void*) {
        auto packet=&list->packet[0];
        for(UInt32 i=0;i<list->numPackets;++i){
            for(int n=0;n+1<packet->length;n+=2)if((packet->data[n]&0xf0)==0xc0){std::lock_guard<std::mutex> guard(capture->mutex);capture->received.push_back((packet->data[n]<<8)|packet->data[n+1]);}
            packet=MIDIPacketNext(packet);
        }
    })==noErr);
    SInt32 identifier=0;assert(MIDIObjectGetIntegerProperty(destination,kMIDIPropertyUniqueID,&identifier)==noErr);
    JarasProgramChangeSender *sender=[JarasProgramChangeSender new];
    [sender setMarkers:@[@{@"id":@"zero",@"position":@0,@"program":@3,@"channel":@1},@{@"id":@"next",@"position":@.05,@"program":@127,@"channel":@16}] destination:identifier muted:NO];
    [sender setPosition:0 subPosition:0 running:YES subRunning:NO hostTime:mach_absolute_time() promotion:0];
    std::this_thread::sleep_for(std::chrono::milliseconds(130));[sender stop];
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    {std::lock_guard<std::mutex> guard(capture->mutex);assert((capture->received==std::vector<int>{0xc003,0xcf7f}));capture->received.clear();}
    [sender setMarkers:@[@{@"id":@"muted",@"position":@0,@"program":@9,@"channel":@2}] destination:identifier muted:YES];
    [sender setPosition:0 subPosition:0 running:YES subRunning:NO hostTime:mach_absolute_time() promotion:0];
    std::this_thread::sleep_for(std::chrono::milliseconds(40));[sender stop];
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    {std::lock_guard<std::mutex> guard(capture->mutex);assert(capture->received.empty());}
    std::array<MIDIEndpointRef,6> endpoints{};
    std::array<std::shared_ptr<Capture>,6> outputs;
    NSMutableArray *markers=[NSMutableArray array];
    for(int slot=0;slot<6;++slot) {
        outputs[slot]=std::make_shared<Capture>();auto received=outputs[slot];
        NSString *name=[NSString stringWithFormat:@"CatLive PC output %d",slot+1];
        assert(MIDIDestinationCreateWithBlock(client,(__bridge CFStringRef)name,&endpoints[slot],^(const MIDIPacketList *list,void*) {
            auto packet=&list->packet[0];
            for(UInt32 i=0;i<list->numPackets;++i){for(int n=0;n+1<packet->length;n+=2)if((packet->data[n]&0xf0)==0xc0){std::lock_guard<std::mutex> guard(received->mutex);received->received.push_back((packet->data[n]<<8)|packet->data[n+1]);}packet=MIDIPacketNext(packet);}
        })==noErr);
        SInt32 uid=0;assert(MIDIObjectGetIntegerProperty(endpoints[slot],kMIDIPropertyUniqueID,&uid)==noErr);
        [markers addObject:@{@"id":name,@"position":@0,@"program":@(10+slot),@"channel":@(slot+1),@"destination":@(uid)}];
    }
    [sender setMarkers:markers destination:identifier muted:NO];
    [sender setPosition:0 subPosition:0 running:YES subRunning:NO hostTime:mach_absolute_time() promotion:0];
    std::this_thread::sleep_for(std::chrono::milliseconds(80));[sender stop];
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    for(int slot=0;slot<6;++slot){std::lock_guard<std::mutex> guard(outputs[slot]->mutex);assert((outputs[slot]->received==std::vector<int>{((0xc0+slot)<<8)|(10+slot)}));}
    {std::lock_guard<std::mutex> guard(capture->mutex);assert(capture->received.empty());}
    sender=nil;for(auto endpoint:endpoints)MIDIEndpointDispose(endpoint);MIDIEndpointDispose(destination);MIDIClientDispose(client);
    puts("PROGRAM_CHANGE_COREMIDI_EXACT_START_CHANNEL16_MUTE_SIX_DESTINATIONS_OK");
} }
