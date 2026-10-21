#pragma once
#include "RemoteCipher.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <deque>
namespace catlive::remote {
// Socket ownership, ciphers and frame assembly stay on this worker. The UI only
// drains bounded events and submits immutable packets; audio never touches it.
class Transport final : private Thread {
  public:
    struct Event {
        enum Type { connected, packetReceived, disconnected } type;
        ID client;
        String name;
        uint8_t kind = 0;
        var body;
        MemoryBlock binding;
    };
    Transport() : Thread("CatLive Remote") {}
    ~Transport() override { stop(); }
    int start(String name, const String &address = "127.0.0.1", int requestedPort = 0) {
        stop();
        displayName = std::move(name);
        listener = std::make_unique<StreamingSocket>();
        if (!listener->createListener(requestedPort, address)) {
            listener.reset();
            throw std::runtime_error("Não foi possível iniciar o Remote nesta porta.");
        }
        const auto port = listener->getBoundPort();
        startThread();
        return port;
    }
    void stop() {
        signalThreadShouldExit();
        notify();
        stopThread(-1);
        listener.reset();
        clients.clear();
        const ScopedLock lock(mutex);
        pending.clear();
        outgoing.clear();
        queuedBytes = 0;
        active.clear();
        connections.clear();
    }
    ID connectTo(const String &address, int port, const String &localAddress = {}, ULONG interfaceIndex = 0) {
        const ScopedLock lock(mutex);
        if (connections.size() >= 8) return {};
        const auto id=uuid(); connections.push_back({id,address,port,localAddress,interfaceIndex}); notify(); return id;
    }
    bool running() const { return isThreadRunning(); }
    std::vector<Event> events() {
        const ScopedLock lock(mutex);
        std::vector<Event> result;
        result.swap(pending);
        return result;
    }
    std::set<ID> peers() const {
        const ScopedLock lock(mutex);
        return active;
    }
    bool send(const ID &client, const Bytes &packet) {
        if (packet.empty() || packet.size() > maximumPacket)
            return false;
        const ScopedLock lock(mutex);
        if (!active.count(client) || queuedBytes + packet.size() > maximumFrame * 8 ||
            outgoing.size() >= 256)
            return false;
        outgoing.push_back({client, packet, false});
        queuedBytes += packet.size();
        notify();
        return true;
    }
    void disconnect(const ID &client) {
        const ScopedLock lock(mutex);
        if (outgoing.size() < 256)
            outgoing.push_back({client, {}, true});
        notify();
    }

  private:
    struct Client {
        Client(std::unique_ptr<StreamingSocket> value, const String &name, Cipher::Role role=Cipher::host)
            : socket(std::move(value)), cipher(role, name) {
            u_long nonblocking = 1;
            require(ioctlsocket((SOCKET)socket->getRawSocketHandle(), FIONBIO, &nonblocking) == 0);
            push(Frames::encode(cipher.hello()));
        }
        ID id = uuid();
        String name;
        std::unique_ptr<StreamingSocket> socket;
        Cipher cipher;
        Frames frames;
        std::deque<Bytes> writes;
        size_t writeOffset = 0, pendingBytes = 0;
        double created = Time::getMillisecondCounterHiRes(), writeProgress = created,
               rateStarted = created;
        int messages = 0;
        bool hello = false, ready = false, closed = false;
        void push(Bytes bytes) {
            require(pendingBytes + bytes.size() <= maximumFrame * 4);
            if (writes.empty())
                writeProgress = Time::getMillisecondCounterHiRes();
            pendingBytes += bytes.size();
            writes.push_back(std::move(bytes));
        }
    };
    struct Outgoing {
        ID client;
        Bytes packet;
        bool close;
    };
    struct Connection { ID id; String address; int port; String localAddress; ULONG interfaceIndex=0; };
    std::vector<Connection> connections;
    String displayName;
    std::unique_ptr<StreamingSocket> listener;
    std::vector<std::unique_ptr<Client>> clients;
    mutable CriticalSection mutex;
    std::vector<Event> pending;
    std::vector<Outgoing> outgoing;
    std::set<ID> active;
    size_t queuedBytes = 0;
    std::deque<double> invitations;
    void post(Event event) {
        const ScopedLock lock(mutex);
        require(pending.size() < 512);
        pending.push_back(std::move(event));
    }
    void received(Client &client, const Bytes &data) {
        if (!client.hello) {
            client.name = client.cipher.accept(data);
            client.hello = true;
            client.push(Frames::encode(client.cipher.seal({0})));
            return;
        }
        const auto plain = client.cipher.open(data);
        if (!client.ready) {
            require(plain == Bytes{0});
            client.ready = true;
            {
                const ScopedLock lock(mutex);
                active.insert(client.id);
            }
            post({Event::connected, client.id, client.name, 0, {}, client.cipher.sessionBinding});
            return;
        }
        require(plain.size() >= 6 && plain[0] == 1 && plain[1] == 0x4a && plain[2] == 0x4c &&
                plain[3] == 2);
        const uint8_t kind = plain[4];
        require(kind == 1 || kind == 3 || kind == 5 || kind == 8);
        const size_t maximum = kind == 8 ? 524292 : kind == 1 ? 8192 : kind == 3 ? 64 : 256;
        require(plain.size() - 1 <= maximum);
        const auto now = Time::getMillisecondCounterHiRes();
        if (now - client.rateStarted >= 1000) {
            client.rateStarted = now;
            client.messages = 0;
        }
        require(++client.messages <= 160);
        var value;
        const auto *json = reinterpret_cast<const char *>(plain.data() + 5);
        const int jsonSize = (int)plain.size() - 5;
        require(std::memchr(json, 0, (size_t)jsonSize) == nullptr &&
                CharPointer_UTF8::isValidString(json, jsonSize));
        // JUCE's document parser accepts objects/arrays, whereas an ACK is a
        // JSON integer in the Mac protocol. Parse a single wrapped value so
        // scalar acknowledgements retain strict syntax/trailing-data checks.
        var wrapper;
        require(JSON::parse("[" + String::fromUTF8(json, jsonSize) + "]", wrapper).wasOk() &&
                wrapper.isArray() && wrapper.size() == 1);
        value = wrapper[0];
        require(kind == 3 ? (value.isInt() || value.isInt64()) && (int64)value >= 0
                          : value.isObject());
        post({Event::packetReceived, client.id, {}, kind, value});
    }
    void poll(Client &client) {
        const auto now = Time::getMillisecondCounterHiRes();
        if ((!client.ready && now - client.created > 15000) ||
            (!client.writes.empty() && now - client.writeProgress > 15000)) {
            client.closed = true;
            return;
        }
        for (int count = 0; count < 4 && client.socket->waitUntilReady(true, 0) > 0; ++count) {
            std::array<uint8_t, 65536> bytes{};
            const int size = client.socket->read(bytes.data(), (int)bytes.size(), false);
            if (size <= 0) {
                client.closed = true;
                return;
            }
            for (const auto &frame : client.frames.receive(bytes.data(), (size_t)size))
                received(client, frame);
        }
        if (!client.writes.empty() && client.socket->waitUntilReady(false, 0) > 0) {
            auto &bytes = client.writes.front();
            const int length = (int)std::min(size_t(65536), bytes.size() - client.writeOffset);
            const int sent = client.socket->write(bytes.data() + client.writeOffset, length);
            if (sent < 0) {
                if (WSAGetLastError() != WSAEWOULDBLOCK)
                    client.closed = true;
                return;
            }
            if (sent > 0) {
                client.writeProgress = now;
                client.writeOffset += (size_t)sent;
                client.pendingBytes -= (size_t)sent;
                if (client.writeOffset == bytes.size()) {
                    client.writeOffset = 0;
                    client.writes.pop_front();
                }
            }
        }
    }
    void run() override {
        invitations.clear();
        while (!threadShouldExit()) {
            if (listener->waitUntilReady(true, 0) > 0) {
                std::unique_ptr<StreamingSocket> socket(listener->waitForNextConnection());
                const auto now = Time::getMillisecondCounterHiRes();
                while (!invitations.empty() && now - invitations.front() > 60000)
                    invitations.pop_front();
                if (socket && clients.size() < 15 && invitations.size() < 30) {
                    invitations.push_back(now);
                    try {
                        clients.push_back(std::make_unique<Client>(std::move(socket), displayName));
                    } catch (...) {
                    }
                }
            }
            std::vector<Connection> connects;
            { const ScopedLock lock(mutex); connects.swap(connections); }
            for(const auto &request:connects) {
                try {
                    auto socket=std::make_unique<StreamingSocket>();
                    if(!socket->connect(request.address,request.port,1000)) { post({Event::disconnected,request.id,{}}); continue; }
                    if (request.interfaceIndex) {
                        // Check before exchanging any application data. A system
                        // route choosing Wi-Fi must not turn into a Sync session.
                        sockaddr_in local{}; int size = sizeof(local);
                        char address[INET_ADDRSTRLEN]{};
                        const auto handle = static_cast<SOCKET>(socket->getRawSocketHandle());
                        const DWORD index = htonl(request.interfaceIndex);
                        if (getsockname(handle, reinterpret_cast<sockaddr *>(&local), &size) != 0 ||
                            !InetNtopA(AF_INET, &local.sin_addr, address, sizeof(address)) || request.localAddress != address ||
                            setsockopt(handle, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<const char *>(&index), sizeof(index)) != 0) {
                            post({Event::disconnected,request.id,{}}); continue;
                        }
                    }
                    auto client=std::make_unique<Client>(std::move(socket),displayName,Cipher::client);
                    client->id=request.id; clients.push_back(std::move(client));
                } catch(...) { post({Event::disconnected,request.id,{}}); }
            }
            std::vector<Outgoing> messages;
            {
                const ScopedLock lock(mutex);
                messages.swap(outgoing);
                queuedBytes = 0;
            }
            for (auto &message : messages)
                for (auto &client : clients)
                    if (client->id == message.client) {
                        if (message.close)
                            client->closed = true;
                        else if (client->ready && !client->closed)
                            try {
                                message.packet.insert(message.packet.begin(), 1);
                                client->push(Frames::encode(client->cipher.seal(message.packet)));
                            } catch (...) {
                                client->closed = true;
                            }
                        break;
                    }
            for (auto &client : clients)
                if (!client->closed)
                    try {
                        poll(*client);
                    } catch (...) {
                        client->closed = true;
                    }
            clients.erase(std::remove_if(clients.begin(), clients.end(),
                                         [&](const auto &client) {
                                             if (!client->closed)
                                                 return false;
                                             const ScopedLock lock(mutex);
                                             active.erase(client->id);
                                             if (pending.size() >= 512)
                                                 pending.clear();
                                             pending.push_back(
                                                 {Event::disconnected, client->id, client->name});
                                             return true;
                                         }),
                          clients.end());
            wait(clients.empty() ? 30 : 5);
        }
        clients.clear();
    }
};
} // namespace catlive::remote
