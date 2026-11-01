#include "Bridge.h"
#include <cstring>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif
namespace integration {
void sendOSC(int port, const std::string& address, int value, bool speed) {
    if (port < 1 || port > 65535 || address.empty() || address.front() != '/') return;
    std::vector<uint8_t> packet;
    auto text = [&](const std::string& s) { packet.insert(packet.end(),s.begin(),s.end()); packet.push_back(0); while(packet.size()%4) packet.push_back(0); };
    text(address); text(speed ? ",sf" : ",i");
    uint32_t bits = uint32_t(value);
    if(speed) { text("a"); float number = float(value); std::memcpy(&bits,&number,4); }
    bits=htonl(bits); auto p=reinterpret_cast<uint8_t*>(&bits); packet.insert(packet.end(),p,p+4);
    // Always local: a sender cannot turn this service into an arbitrary UDP relay.
    sockaddr_in target{}; target.sin_family=AF_INET; target.sin_port=htons(uint16_t(port)); target.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    auto socketFD=::socket(AF_INET,SOCK_DGRAM,0);
#ifdef _WIN32
    if(socketFD==INVALID_SOCKET) return;
#else
    if(socketFD<0) return;
#endif
    ::sendto(socketFD,reinterpret_cast<const char*>(packet.data()),int(packet.size()),0,reinterpret_cast<sockaddr*>(&target),sizeof(target));
#ifdef _WIN32
    closesocket(socketFD);
#else
    ::close(socketFD);
#endif
}
}
