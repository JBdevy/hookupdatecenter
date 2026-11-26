#include "Bridge.h"
#include "httplib.h"
#include <thread>
#ifdef _WIN32
#include <winsock2.h>
#else
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif
using namespace integration;
extern void require(bool,const char*);
void testOSC() {
    // The actual receiver worker sends to a real localhost UDP socket.
    auto socket=::socket(AF_INET,SOCK_DGRAM,0);
    sockaddr_in endpoint{};endpoint.sin_family=AF_INET;endpoint.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    require(::bind(socket,(sockaddr*)&endpoint,sizeof(endpoint))==0,"OSC socket binds");
#ifdef _WIN32
    int length=sizeof(endpoint);
#else
    socklen_t length=sizeof(endpoint);
#endif
    getsockname(socket,(sockaddr*)&endpoint,&length);
    struct Packet {std::string address;uint32_t value;Clock::time_point time;};
    std::vector<Packet> packets;
    auto read=[&](int count,int ms) {
        auto deadline=Clock::now()+std::chrono::milliseconds(ms);
        while(int(packets.size())<count && Clock::now()<deadline) {
            fd_set read;FD_ZERO(&read);FD_SET(socket,&read);timeval wait{0,20000};
            if(select(int(socket)+1,&read,nullptr,nullptr,&wait)<=0)continue;
            char data[1024]{};auto n=recv(socket,data,sizeof(data),0);if(n<8)continue;
            uint32_t value=0;std::memcpy(&value,data+n-4,4);
            packets.push_back({std::string(data),ntohl(value),Clock::now()});
        }
    };
    httplib::Server probe;int port=probe.bind_to_any_port("127.0.0.1");probe.stop();
    Bridge bridge;bridge.start("127.0.0.1",port);httplib::Client client("127.0.0.1",port);
    auto connection=client.Post("/v1/connect",JSON({{"protocol",1},{"name","OSC test"},{"resolume",true},{"oscPort",ntohs(endpoint.sin_port)}}).dump(),"application/json");
    require(connection && connection->status==200,"OSC client connects");auto token=JSON::parse(connection->body)["token"].get<std::string>();
    JSON state={{"sequence",1},{"position",5},{"playing",false},{"deck",2},{"column",3}};
    auto send=[&] {return client.Post("/v1/state",{{"X-CatLive-Token",token}},state.dump(),"application/json");};
    require(send()->status==200,"OSC state accepted");read(4,800);
    require(packets.size()==4,"Pause, select deck, press and release column arrive");
    require(packets[0].address=="/composition/speed" && packets[0].value==0,"Stopped transport pauses Resolume");
    require(packets[1].address=="/composition/decks/2/select","Deck selected before triggering column");
    require(packets[2].address=="/composition/columns/3/connect" && packets[2].value==1 && packets[3].value==0,"OSC trigger releases its button");
    require(packets[2].time-packets[1].time>=std::chrono::milliseconds(40),"Allow Resolume to switch decks");
    state["playing"]=true;state["sequence"]=2;send();read(5,300);
    require(packets.size()>=5 && packets[4].address=="/composition/speed" && packets[4].value==0x3f800000,"Play resumes Resolume at normal speed");
    state["deck"]=4;state["sequence"]=1;send();read(6,900);
    require(packets.size()==6 && packets.back().address=="/composition/speed" && packets.back().value==0,"Lost heartbeat pauses output; stale cue never triggers");
    bridge.stop();
#ifdef _WIN32
    closesocket(socket);
#else
    close(socket);
#endif
}
