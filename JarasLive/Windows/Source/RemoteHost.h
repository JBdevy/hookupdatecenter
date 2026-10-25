#pragma once
#include "RemoteProtocol.h"
#include "RemoteTransport.h"
#include "RemoteDiscovery.h"
#include "Appearance.h"
#include "ProjectSync.h"
namespace catlive::remote {
class Host final : private Timer {
  public:
    explicit Host(Appearance &value) : sync(value), preferences(value) {}
    ProjectSync sync;
    ~Host() override { stop(); }
    std::function<var(int)> presentation;
    std::function<bool(const Command &)> perform;
    std::function<Bytes(const Command &)> image;
    String error;
    int port = 0;
    bool enabled() const { return transport.running(); }
    DWORD discoveryStatus() const { return advertising ? discovery.status() : ERROR_CANCELLED; }
    void setHostName(String name) {
        name = name.trim();
        if (name.isEmpty()) name = SystemStats::getComputerName();
        if (name == hostName) return;
        hostName = name;
        if (enabled()) start(advertising);
    }
    void start(bool discover = true) {
        stop();
        error.clear();
        const auto name = hostName.isEmpty() ? SystemStats::getComputerName() : hostName;
        try {
            port = transport.start(name, discover ? "0.0.0.0" : "127.0.0.1");
            if (discover)
                discovery.start(name, port);
            advertising = discover;
            startTimerHz(30);
            if (discover) sync.start();
        } catch (...) {
            stop();
            throw;
        }
    }
    void stop() {
        sync.stop();
        stopTimer();
        discovery.stop();
        transport.stop();
        for(auto &entry:clients)releaseVinhetas(entry.second);
        clients.clear();
        port = 0;
        advertising = false;
    }
    String status() const {
        if (!error.isEmpty())
            return error;
        if (!enabled())
            return "Remote desativado";
        if (advertising && discovery.status() == DNS_REQUEST_PENDING)
            return String::fromUTF8("Anunciando na rede…");
        if (advertising && discovery.status() != ERROR_SUCCESS &&
            discovery.status() != DNS_REQUEST_PENDING)
            return "Falha ao anunciar na rede (" + String((int)discovery.status()) + ")";
        if (clients.empty())
            return String::fromUTF8("Aguardando conexão…");
        return String((int)clients.size()) + " dispositivo(s) conectado(s)";
    }
    String peerNames() const {
        StringArray names;
        for (const auto &entry : clients)
            names.add(entry.second.name);
        return names.joinIntoString(", ");
    }
    String pin(bool notices) const {
        return preferences.value(notices ? "jaras.remote.noticesPIN" : "jaras.remote.directorPIN")
            .toString();
    }
    bool savePIN(bool notices, const String &value) {
        if (!pinValid(value))
            return false;
        if (preferences.set(notices ? "jaras.remote.noticesPIN" : "jaras.remote.directorPIN", value)
                .failed())
            return false;
        for (auto &entry : clients) {
            auto &client = entry.second;
            if (client.mode == (notices ? "notices" : "director")) {
                releaseVinhetas(client);
                client.mode.clear();
                client.ack.reset();
                client.panel = 0;
            }
            accessStatus(entry.first, client);
        }
        return true;
    }
    // Also called explicitly by the loopback test; all state stays on the UI thread.
    void update() {
        for (const auto &event : transport.events()) {
            if (event.type == Transport::Event::disconnected) {
                if(auto found=clients.find(event.client);found!=clients.end())releaseVinhetas(found->second);
                clients.erase(event.client);
                continue;
            }
            if (event.type == Transport::Event::connected) {
                Client client;
                client.name = event.name;
                clients[event.client] = client;
                accessStatus(event.client, client);
                continue;
            }
            const auto found = clients.find(event.client);
            if (found == clients.end())
                continue;
            auto &client = found->second;
            try {
                if (event.kind == 5) {
                    releaseVinhetas(client);
                    const auto mode = event.body["mode"], value = event.body["pin"];
                    require(
                        mode.isString() && value.isString() &&
                        StringArray{"director", "observer", "notices"}.contains(mode.toString()) &&
                        pinValid(value.toString()));
                    const auto now = Time::getMillisecondCounterHiRes();
                    while (!failedPINs.empty() && now - failedPINs.front() > 60000)
                        failedPINs.pop_front();
                    const auto expected =
                        mode == var("observer") ? String() : pin(mode == var("notices"));
                    if (expected.isNotEmpty() &&
                        (failedPINs.size() >= 30 || value.toString() != expected)) {
                        failedPINs.push_back(now);
                        client.mode.clear();
                        client.ack.reset();
                        accessStatus(event.client, client, "Senha incorreta.");
                        if (++client.failures >= 5)
                            transport.disconnect(event.client);
                        continue;
                    }
                    client.mode = mode.toString();
                    client.panel = 0;
                    client.ack.reset();
                    client.failures = 0;
                    accessStatus(event.client, client);
                } else if (event.kind == 3) {
                    if (client.ack && *client.ack == (uint64)(int64)event.body)
                        client.ack.reset();
                } else if (event.kind == 1) {
                    const auto command = Command::decode(event.body);
                    if (!command.allowed(client.mode))
                        continue;
                    if (command.action == "remotePanel") {
                        client.panel = (int)command.value;
                        client.ack.reset();
                    } else if (command.action == "requestImage") {
                        if (image) {
                            const auto data = image(command);
                            if (!data.empty())
                                transport.send(event.client, data);
                        }
                    } else {
                        bool accepted = false;
                        try {
                            if(command.action=="vinhetasDown"){
                                if(client.heldVinhetas.size()>=128||client.heldVinhetas.count(command.target))continue;
                                accepted=perform&&perform(command);
                                if(accepted)client.heldVinhetas.emplace(command.target,command);
                            } else if(command.action=="vinhetasUp"){
                                if(client.heldVinhetas.erase(command.target)==0)continue;
                                accepted=perform&&perform(command);
                            } else accepted = perform && perform(command);
                        } catch (const std::exception &) {
                        }
                        if (command.action == "noticeSend" && command.receipt.value_or(false)) {
                            auto receipt = object();
                            put(receipt, "commandID", wireID(command.id));
                            put(receipt, "project", wireID(command.project));
                            put(receipt, "accepted", accepted);
                            transport.send(event.client, packet(7, receipt));
                        }
                    }
                }
            } catch (...) {
                transport.disconnect(event.client);
            }
        }
        const auto now = Time::getMillisecondCounterHiRes();
        if (now - lastPublish < 100 || !presentation)
            return;
        lastPublish = now;
        std::map<int, var> snapshots;
        for (auto &entry : clients) {
            auto &client = entry.second;
            if (client.mode.isEmpty())
                continue;
            if (client.ack) {
                if (now - client.sentAt > 15000)
                    transport.disconnect(entry.first);
                continue;
            }
            try {
                auto at = snapshots.find(client.panel);
                if (at == snapshots.end())
                    at = snapshots.emplace(client.panel, presentation(client.panel)).first;
                if (!at->second.isObject())
                    continue;
                auto value = at->second.clone();
                if (client.mode != "director") {
                    put(value, "projectTabs", var()); put(value, "projects", var()); put(value,"vinhetas",var());
                }
                const auto current = ++sequence;
                put(value, "sequence", (int64)current);
                if (transport.send(entry.first, packet(2, value))) {
                    client.ack = current;
                    client.sentAt = now;
                } else
                    transport.disconnect(entry.first);
            } catch (const std::exception &) {
                error = "Projeto excede o limite do Remote.";
                transport.disconnect(entry.first);
            }
        }
    }

  private:
    struct Client {
        String name, mode;
        std::map<ID,Command> heldVinhetas;
        std::optional<uint64> ack;
        double sentAt = 0;
        int panel = 0, failures = 0;
    };
    void releaseVinhetas(Client &client) {
        auto held=std::move(client.heldVinhetas);client.heldVinhetas.clear();
        for(auto &entry:held){auto command=entry.second;command.action="vinhetasUp";command.pad=-1;command.preset=-1;command.value=0;if(perform)perform(command);}
    }
    Appearance &preferences;
    String hostName;
    Transport transport;
    Discovery discovery;
    std::map<ID, Client> clients;
    std::deque<double> failedPINs;
    bool advertising = false;
    double lastPublish = 0;
    uint64 sequence = 0;
    void timerCallback() override { update(); }
    void accessStatus(const ID &id, const Client &client, const String &message = {}) {
        auto status = object();
        if (client.mode.isNotEmpty())
            put(status, "mode", client.mode);
        put(status, "requiresPIN", pin(false).isNotEmpty());
        put(status, "noticesRequiresPIN", pin(true).isNotEmpty());
        if (message.isNotEmpty())
            put(status, "error", message);
        transport.send(id, packet(6, status));
    }
};
} // namespace catlive::remote
