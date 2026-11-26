#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace catlive::integration {
struct HTTPResponse { int status = 0; std::string body; };
inline HTTPResponse ethernetRequest(const std::string& host, int port, const std::string& path,
                                    const std::string* body, const std::string& token) {
    static const bool initialized = [] { WSADATA value{}; return WSAStartup(MAKEWORD(2,2), &value) == 0; }();
    if (!initialized) throw std::runtime_error("Could not initialize Integration networking");
    SOCKADDR_INET remote{}; remote.si_family = AF_INET; remote.Ipv4.sin_port = htons(static_cast<u_short>(port));
    if (port < 1 || port > 65535 || InetPtonA(AF_INET, host.c_str(), &remote.Ipv4.sin_addr) != 1)
        throw std::runtime_error("Enter the Ethernet IPv4 address of CatLive Integration");
    if (path.find_first_of("\r\n ") != std::string::npos || token.find_first_of("\r\n") != std::string::npos)
        throw std::runtime_error("Invalid Integration request");
    ULONG size = 16384; std::vector<unsigned char> storage(size);
    auto enumerate = [&] { return GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()), &size); };
    auto status = enumerate();
    if (status == ERROR_BUFFER_OVERFLOW && size <= 1024 * 1024) { storage.resize(size); status = enumerate(); }
    ULONG index = 0; SOCKADDR_INET source{}; unsigned prefix = 0; uint64_t metric = std::numeric_limits<uint64_t>::max();
    if (status == NO_ERROR) for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()); adapter; adapter = adapter->Next) {
        if (adapter->IfType != IF_TYPE_ETHERNET_CSMACD || adapter->OperStatus != IfOperStatusUp) continue;
        MIB_IF_ROW2 info{}; info.InterfaceIndex = adapter->IfIndex;
        if (GetIfEntry2(&info) != NO_ERROR || !info.InterfaceAndOperStatusFlags.HardwareInterface || info.MediaConnectState != MediaConnectStateConnected) continue;
        MIB_IPFORWARD_ROW2 route{}; SOCKADDR_INET local{};
        if (GetBestRoute2(nullptr, adapter->IfIndex, nullptr, &remote, 0, &route, &local) != NO_ERROR || local.si_family != AF_INET) continue;
        const auto cost = uint64_t(route.Metric) + adapter->Ipv4Metric;
        if (!index || route.DestinationPrefix.PrefixLength > prefix || (route.DestinationPrefix.PrefixLength == prefix && cost < metric)) {
            index = adapter->IfIndex; source = local; prefix = route.DestinationPrefix.PrefixLength; metric = cost;
        }
    }
    if (!index) throw std::runtime_error("CatLive Integration requires an Ethernet cable. Check the adapter and IP address.");
    struct Socket { SOCKET handle = INVALID_SOCKET; ~Socket() { if (handle != INVALID_SOCKET) closesocket(handle); } } socket;
    socket.handle = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket.handle == INVALID_SOCKET) throw std::runtime_error("Could not open Integration socket");
    const DWORD boundIndex = htonl(index);
    source.Ipv4.sin_port = 0;
    // Bind before connecting: neither the TCP handshake nor its HTTP payload
    // may leave through Wi-Fi, even when it has the preferred default route.
    if (setsockopt(socket.handle, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<const char*>(&boundIndex), sizeof(boundIndex)) != 0 ||
        bind(socket.handle, reinterpret_cast<const sockaddr*>(&source.Ipv4), sizeof(source.Ipv4)) != 0)
        throw std::runtime_error("Could not bind CatLive Integration to Ethernet");
    u_long nonblocking = 1;
    if (ioctlsocket(socket.handle, FIONBIO, &nonblocking) != 0) throw std::runtime_error("Could not configure Integration socket");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    auto ready = [&](bool reading) {
        const auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) throw std::runtime_error("CatLive Integration Ethernet connection timed out");
        timeval timeout{static_cast<long>(remaining / 1000000), static_cast<long>(remaining % 1000000)};
        fd_set active, errors; FD_ZERO(&active); FD_ZERO(&errors); FD_SET(socket.handle, &active); FD_SET(socket.handle, &errors);
        if (select(0, reading ? &active : nullptr, reading ? nullptr : &active, &errors, &timeout) <= 0 || FD_ISSET(socket.handle, &errors))
            throw std::runtime_error("CatLive Integration did not respond through Ethernet");
    };
    if (connect(socket.handle, reinterpret_cast<const sockaddr*>(&remote.Ipv4), sizeof(remote.Ipv4)) != 0) {
        if (WSAGetLastError() != WSAEWOULDBLOCK) throw std::runtime_error("Could not connect through Ethernet");
        ready(false); int error = 0, length = sizeof(error);
        if (getsockopt(socket.handle, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &length) != 0 || error)
            throw std::runtime_error("Could not connect through Ethernet");
    }
    const std::string payload = body ? *body : std::string();
    const std::string request = std::string(body ? "POST " : "GET ") + "/v1/" + path + " HTTP/1.1\r\nHost: " + host + ":" + std::to_string(port) +
        "\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + std::to_string(payload.size()) +
        (token.empty() ? "" : "\r\nX-CatLive-Token: " + token) + "\r\n\r\n" + payload;
    for (size_t offset = 0; offset < request.size();) {
        ready(false);
        const int sent = send(socket.handle, request.data() + offset, static_cast<int>(std::min(size_t(65536), request.size() - offset)), 0);
        if (sent < 0 && WSAGetLastError() == WSAEWOULDBLOCK) continue;
        if (sent <= 0) throw std::runtime_error("Integration Ethernet send failed");
        offset += static_cast<size_t>(sent);
    }
    std::string received; size_t headerEnd = std::string::npos, contentLength = 0; HTTPResponse result;
    for (;;) {
        ready(true); char buffer[32768]; const int count = recv(socket.handle, buffer, sizeof(buffer), 0);
        if (count < 0 && WSAGetLastError() == WSAEWOULDBLOCK) continue;
        if (count <= 0) throw std::runtime_error("Incomplete Integration response");
        received.append(buffer, static_cast<size_t>(count));
        if (received.size() > 2 * 1024 * 1024 + 16384) throw std::runtime_error("Integration response too large");
        if (headerEnd == std::string::npos) {
            const auto boundary = received.find("\r\n\r\n");
            if (boundary == std::string::npos) { if (received.size() > 16384) throw std::runtime_error("Integration headers too large"); continue; }
            if (boundary > 16384 || (received.compare(0, 9, "HTTP/1.1 ") && received.compare(0, 9, "HTTP/1.0 ")) || received.size() < 12)
                throw std::runtime_error("Invalid Integration HTTP response");
            for (size_t i = 9; i < 12; ++i) if (!std::isdigit(static_cast<unsigned char>(received[i]))) throw std::runtime_error("Invalid Integration status");
            result.status = std::stoi(received.substr(9, 3));
            bool lengthFound = false;
            for (size_t line = received.find("\r\n") + 2; line < boundary;) {
                const auto end = received.find("\r\n", line), colon = received.find(':', line);
                if (colon == std::string::npos || colon >= end) throw std::runtime_error("Invalid Integration header");
                auto name = received.substr(line, colon - line); std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
                if (name == "transfer-encoding") throw std::runtime_error("Unexpected Integration transfer encoding");
                if (name == "content-length") {
                    if (lengthFound) throw std::runtime_error("Duplicate Integration content length");
                    auto value = received.substr(colon + 1, end - colon - 1); const auto first = value.find_first_not_of(" \t"), last = value.find_last_not_of(" \t");
                    if (first == std::string::npos) throw std::runtime_error("Invalid Integration content length");
                    value = value.substr(first, last - first + 1);
                    if (value.size() > 7 || !std::all_of(value.begin(), value.end(), [](unsigned char c) { return std::isdigit(c); })) throw std::runtime_error("Invalid Integration content length");
                    contentLength = static_cast<size_t>(std::stoul(value)); lengthFound = true;
                }
                line = end + 2;
            }
            if (!lengthFound || contentLength > 2 * 1024 * 1024) throw std::runtime_error("Invalid Integration content length");
            headerEnd = boundary + 4;
        }
        if (received.size() - headerEnd > contentLength) throw std::runtime_error("Invalid Integration body size");
        if (received.size() - headerEnd == contentLength) { result.body = received.substr(headerEnd); return result; }
    }
}
}
