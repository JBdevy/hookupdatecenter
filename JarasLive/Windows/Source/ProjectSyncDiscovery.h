#pragma once
#include "Common.h"
#include <winsock2.h>
#include <ws2tcpip.h>
namespace catlive::remote {
// Same discovery approach as Hook Center: short UDP beacons over the cable.
// A beacon only advertises a TCP endpoint, never authorizes a peer or carries
// transport commands. The encrypted pairing protocol remains mandatory.
class SyncDiscovery final : private Thread {
public:
    struct Peer { String id,name,address; int port=0; double seen=0; };
    SyncDiscovery():Thread("CatLive cable discovery"){}
    ~SyncDiscovery() override { stop(); }
    void start(ULONG index,const String &address,const String &node,const String &name,int port) {
        stop(); if(!index || address.isEmpty() || port<=0)return;
        interfaceIndex=index;localAddress=address;identity=node;
        auto beacon=object();put(beacon,"magic","CATLIVE_PROJECT_SYNC");put(beacon,"version",1);
        put(beacon,"node",node);put(beacon,"name",name.substring(0,80));put(beacon,"port",port);
        announcement=JSON::toString(beacon,true);error=0;startThread();
    }
    void stop() {signalThreadShouldExit();notify();stopThread(-1);const ScopedLock lock(mutex);found.clear();}
    void search() {sendSoon=true;notify();}
    int lastError() const {return error.load();}
    std::vector<Peer> peers() const {
        const ScopedLock lock(mutex);std::vector<Peer> result;
        const double now=Time::getMillisecondCounterHiRes();
        for(const auto &entry:found)if(now-entry.second.seen<4000)result.push_back(entry.second);
        return result;
    }
private:
    ULONG interfaceIndex=0;String localAddress,identity,announcement;
    mutable CriticalSection mutex;std::map<String,Peer> found;
    std::atomic<int> error{0};std::atomic<bool> sendSoon{false};
    void run() override {
        const SOCKET receiver=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP),sender=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
        const auto close=[&]{if(receiver!=INVALID_SOCKET)closesocket(receiver);if(sender!=INVALID_SOCKET)closesocket(sender);};
        if(receiver==INVALID_SOCKET || sender==INVALID_SOCKET){error=WSAGetLastError();close();return;}
        DWORD yes=1,index=htonl(interfaceIndex);u_long nonblocking=1;
        const auto option=[](SOCKET s,int level,int key,const DWORD &value){return setsockopt(s,level,key,reinterpret_cast<const char*>(&value),sizeof(value))==0;};
        // IP_IFLIST restricts incoming packets too, including broadcast traffic.
        // Never silently fall back to an unrestricted socket if it is rejected.
        if(!option(receiver,SOL_SOCKET,SO_REUSEADDR,yes) || !option(receiver,IPPROTO_IP,IP_IFLIST,yes) ||
           !option(receiver,IPPROTO_IP,IP_ADD_IFLIST,interfaceIndex) || !option(sender,IPPROTO_IP,IP_UNICAST_IF,index) ||
           !option(sender,SOL_SOCKET,SO_BROADCAST,yes) || ioctlsocket(receiver,FIONBIO,&nonblocking)!=0) {
            error=WSAGetLastError();close();return;
        }
        sockaddr_in incoming{};incoming.sin_family=AF_INET;incoming.sin_port=htons(47839);
        sockaddr_in outgoing{};outgoing.sin_family=AF_INET;InetPtonA(AF_INET,localAddress.toRawUTF8(),&outgoing.sin_addr);
        if(bind(receiver,reinterpret_cast<const sockaddr*>(&incoming),sizeof(incoming))!=0 ||
           bind(sender,reinterpret_cast<const sockaddr*>(&outgoing),sizeof(outgoing))!=0){error=WSAGetLastError();close();return;}
        sockaddr_in broadcast{};broadcast.sin_family=AF_INET;broadcast.sin_port=htons(47839);broadcast.sin_addr.s_addr=INADDR_BROADCAST;
        double lastSend=0;
        while(!threadShouldExit()) {
            const auto now=Time::getMillisecondCounterHiRes();
            for(int count=0;count<32;++count) {
                char bytes[1025]{};sockaddr_in source{};int sourceSize=sizeof(source);
                const int length=recvfrom(receiver,bytes,sizeof(bytes),0,reinterpret_cast<sockaddr*>(&source),&sourceSize);
                if(length<=0)break;if(length>1024)continue;
                const auto value=JSON::parse(String::fromUTF8(bytes,length));
                if(!value.isObject() || value["magic"].toString()!="CATLIVE_PROJECT_SYNC" || (int)value["version"]!=1 || !validID(value["node"]))continue;
                const auto id=value["node"].toString().toUpperCase(),name=value["name"].toString();const int port=(int)value["port"];
                if(id==identity || name.getNumBytesAsUTF8()>256 || port<=0 || port>65535)continue;
                char address[INET_ADDRSTRLEN]{};if(!InetNtopA(AF_INET,&source.sin_addr,address,sizeof(address)))continue;
                const ScopedLock lock(mutex);
                if(found.size()<32 || found.count(id))found[id]={id,name,address,port,now};
            }
            if(sendSoon.exchange(false) || now-lastSend>=1000) {
                lastSend=now;
                if(sendto(sender,announcement.toRawUTF8(),(int)announcement.getNumBytesAsUTF8(),0,reinterpret_cast<const sockaddr*>(&broadcast),sizeof(broadcast))<0)error=WSAGetLastError();
                else error=0;
                const ScopedLock lock(mutex);
                for(auto i=found.begin();i!=found.end();)if(now-i->second.seen>=4000)i=found.erase(i);else ++i;
            }
            wait(100);
        }
        close();
    }
};
}
