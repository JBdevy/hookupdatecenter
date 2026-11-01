#include "Bridge.h"
#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Security/Security.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <map>
namespace integration {
static std::string utf(CFStringRef value) {
    if(!value) return {};
    return [(__bridge NSString*)value UTF8String] ?: "";
}
std::vector<Adapter> adapters() {
    std::map<std::string,std::string> names;
    if(auto all=SCNetworkInterfaceCopyAll()) {
        for(CFIndex i=0;i<CFArrayGetCount(all);++i) {
            auto entry=(SCNetworkInterfaceRef)CFArrayGetValueAtIndex(all,i);
            auto type=SCNetworkInterfaceGetInterfaceType(entry);
            if(type && CFEqual(type,kSCNetworkInterfaceTypeEthernet))
                names[utf(SCNetworkInterfaceGetBSDName(entry))]=utf(SCNetworkInterfaceGetLocalizedDisplayName(entry));
        }
        CFRelease(all);
    }
    std::vector<Adapter> result; ifaddrs* list=nullptr;
    if(getifaddrs(&list)==0) {
        for(auto p=list;p;p=p->ifa_next) if(p->ifa_addr && p->ifa_addr->sa_family==AF_INET && (p->ifa_flags&IFF_UP) && names.count(p->ifa_name)) {
            char address[INET_ADDRSTRLEN]{}; inet_ntop(AF_INET,&((sockaddr_in*)p->ifa_addr)->sin_addr,address,sizeof(address));
            result.push_back({p->ifa_name,names[p->ifa_name],address});
        }
        freeifaddrs(list);
    }
    return result;
}
std::filesystem::path documents() {
    @autoreleasepool { return std::filesystem::u8path([NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject UTF8String]); }
}
std::string secureToken() {
    uint8_t bytes[32]; if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess) throw std::runtime_error("Random source unavailable");
    std::string result; const char* hex="0123456789abcdef"; for(auto b:bytes) {result+=hex[b>>4];result+=hex[b&15];} return result;
}
std::vector<MIDIPort> midiPorts() {
    std::vector<MIDIPort> result{{"virtual","CatLive Integration"}};
    for(ItemCount i=0;i<MIDIGetNumberOfDestinations();++i) {
        auto endpoint=MIDIGetDestination(i); SInt32 id=0; CFStringRef name=nullptr;
        if(MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&id)!=noErr) continue;
        MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&name);
        result.push_back({std::to_string(id),utf(name)}); if(name) CFRelease(name);
    }
    return result;
}
struct MIDIOutput::Impl { MIDIClientRef client=0; MIDIPortRef port=0; MIDIEndpointRef endpoint=0; bool local=false; };
MIDIOutput::MIDIOutput():impl(std::make_unique<Impl>()){}
MIDIOutput::~MIDIOutput(){close();}
void MIDIOutput::close() {
    if(impl->local && impl->endpoint) MIDIEndpointDispose(impl->endpoint);
    if(impl->port) MIDIPortDispose(impl->port);
    if(impl->client) MIDIClientDispose(impl->client);
    *impl=Impl{};
}
void MIDIOutput::open(const std::string& id) {
    close();
    if(MIDIClientCreate(CFSTR("CatLive Integration"),nullptr,nullptr,&impl->client)!=noErr) throw std::runtime_error("Could not open MIDI");
    if(id=="virtual" || id.empty()) {
        impl->local=true;
        if(MIDISourceCreate(impl->client,CFSTR("CatLive Integration"),&impl->endpoint)!=noErr) {close();throw std::runtime_error("Could not create MIDI port");}
    } else {
        for(ItemCount i=0;i<MIDIGetNumberOfDestinations();++i) { auto ep=MIDIGetDestination(i); SInt32 uid=0; MIDIObjectGetIntegerProperty(ep,kMIDIPropertyUniqueID,&uid); if(std::to_string(uid)==id) {impl->endpoint=ep;break;} }
        if(!impl->endpoint || MIDIOutputPortCreate(impl->client,CFSTR("MTC"),&impl->port)!=noErr) {close();throw std::runtime_error("MIDI output unavailable");}
    }
}
void MIDIOutput::send(const std::vector<uint8_t>& bytes) {
    if(!impl->endpoint || bytes.empty() || bytes.size()>256) return;
    alignas(MIDIPacketList) uint8_t storage[512]{}; auto list=(MIDIPacketList*)storage;
    auto packet=MIDIPacketListInit(list); if(!MIDIPacketListAdd(list,sizeof(storage),packet,0,bytes.size(),bytes.data())) return;
    if(impl->local) MIDIReceived(impl->endpoint,list); else MIDISend(impl->port,impl->endpoint,list);
}
}
