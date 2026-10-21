#pragma once
#include "RemoteProtocol.h"
#include "RemoteTransport.h"
#include "ProjectSyncDiscovery.h"
#include "ProjectSyncEthernet.h"
#include "Appearance.h"
#include "../../Core/ProjectSync/ProjectSync.hpp"
namespace catlive::remote {
class ProjectSync final : private Timer {
public:
    explicit ProjectSync(Appearance &prefs):preferences(prefs) {
        node=preferences.value("catlive.sync.node").toString();
        if(!validID(var(node))) { node=Uuid().toDashedString().toUpperCase(); preferences.set("catlive.sync.node",node); }
        peerID=preferences.value("catlive.sync.peer").toString(); peerName=preferences.value("catlive.sync.name").toString();
        role=preferences.value("catlive.sync.role","A").toString(); secret=preferences.value("catlive.sync.token").toString();
        independent=(bool)preferences.value("catlive.sync.independent",false);
        ethernet.select(preferences.value("catlive.sync.adapter").toString());
        status=peerID.isEmpty()?String::fromUTF8("Não pareado"):independent?String::fromUTF8("Independente · sincronize novamente"):"Aguardando computador pareado";
    }
    ~ProjectSync() override { stop(); }
    std::function<var()> snapshot;
    struct ApplyResult { String problem; bool applied = false; };
    std::function<ApplyResult(const var &,double,const ID &)> apply;
    std::function<String()> audioIdentity;
    std::function<void()> resetApplied;
    std::function<void(String,std::function<void(bool)>)> confirm;
    String status,role="A",peerName;
    bool following=false;
    bool enabled() const { return transport.running(); }
    std::vector<SyncEthernet::Interface> adapters() const {return ethernet.adapters();}
    String selectedAdapter() const {return preferences.value("catlive.sync.adapter").toString();}
    void chooseAdapter(const String &id) {preferences.set("catlive.sync.adapter",id);ethernet.select(id);}
    bool preparing() const { return ethernet.busy(); }
    bool paired() const { return peerID.isNotEmpty(); }
    std::vector<SyncDiscovery::Peer> peers() const {
        auto result=browser.peers(); result.erase(std::remove_if(result.begin(),result.end(),[&](const auto &p){return p.id==node;}),result.end()); return result;
    }
    void start() {
        if(requested) return;
        requested=true; ethernet.start(); startTimerHz(20);
        status="Conecte os computadores por cabo Ethernet";
    }
    void stop() {
        if(auto link=activeLink()) send(*link,"release");
        failover(String::fromUTF8("Remote desativado · controle independente"));
        requested=false; stopTimer(); ethernet.stop(); browser.stop(); transport.stop(); links.clear(); active.clear(); bound={};
    }
    void search() { ethernet.prepare(); if(enabled()) browser.search(); else status=requested?"Conecte os computadores por cabo Ethernet":"Ative o Remote para buscar computadores"; }
    void request(const SyncDiscovery::Peer &peer,const String &requestedRole) {
        if(!enabled() || following || (requestedRole!="A" && requestedRole!="B")) return;
        const auto id=transport.connectTo(peer.address,peer.port,bound.address,bound.index); if(id.empty()) return;
        auto link=std::make_shared<Link>(); link->id=id; link->desiredRole=requestedRole; link->request=Uuid().toDashedString().toUpperCase(); links[id]=link;
        status=String::fromUTF8("Aguardando aceitação em ")+peer.name;
    }
    void resume() {
        auto link=activeLink(); if(!link || !link->authenticated) { status="Aguardando computador pareado"; return; }
        link->request=Uuid().toDashedString().toUpperCase(); link->resuming=true;
        auto m=message("resume"); put(m,"request",link->request); send(*link,m); status=String::fromUTF8("Aguardando confirmação para sincronizar");
    }
private:
    struct Link {
        ID id; String node,name,peerNonce,nonce=Uuid().toDashedString().toUpperCase(),desiredRole,request;
        MemoryBlock binding;
        bool authenticated=false,ready=false,prompting=false,resuming=false;
        double lastRx=Time::getMillisecondCounterHiRes()/1000.,latency=.005;
        uint64 sequence=0;
    };
    Appearance &preferences; Transport transport; SyncDiscovery browser;
    SyncEthernet ethernet; SyncEthernet::Interface bound; bool requested=false;
    String node,peerID,secret,leaderDevice,lastProblem;
    bool independent=false;
    std::map<ID,std::shared_ptr<Link>> links; ID active;
    uint64 sequence=0; double lastPing=0,lastConnect=0;
    std::shared_ptr<int> life=std::make_shared<int>(0);
    std::shared_ptr<Link> activeLink() { auto it=links.find(active); return it==links.end()?nullptr:it->second; }
    var message(const String &type) const { auto m=object(); put(m,"version",1);put(m,"type",type);put(m,"node",node);return m; }
    void send(Link &link,const var &m) { transport.send(link.id,packet(8,m)); }
    void send(Link &link,const char *type) { send(link,message(type)); }
    String proof(const Link &link) const {
        if(link.node.isEmpty() || link.peerNonce.isEmpty()) return {};
        StringArray ids{node,link.node}, nonces{link.nonce,link.peerNonce}; ids.sort(false);nonces.sort(false);
        const auto binding=String::toHexString(link.binding.getData(),(int)link.binding.getSize(),0).toLowerCase();
        const auto text=String("CatLive Project Sync 1|")+ids.joinIntoString("|")+"|"+nonces.joinIntoString("|")+"|"+binding;
        const auto digest=hmac((const uint8_t*)secret.toRawUTF8(),secret.getNumBytesAsUTF8(),(const uint8_t*)text.toRawUTF8(),text.getNumBytesAsUTF8());
        return Base64::toBase64(digest.data(),digest.size());
    }
    void savePair(const Link &link,const String &localRole,const String &token) {
        peerID=link.node;peerName=link.name;role=localRole;secret=token;independent=false;
        preferences.set("catlive.sync.peer",peerID);preferences.set("catlive.sync.name",peerName);
        preferences.set("catlive.sync.role",role);preferences.set("catlive.sync.token",secret);
        preferences.set("catlive.sync.independent",false); leaderDevice=audioIdentity?audioIdentity():String();
    }
    void authenticated(Link &link) {
        if(!active.empty() && active!=link.id) transport.disconnect(active);
        active=link.id;link.authenticated=true;link.lastRx=Time::getMillisecondCounterHiRes()/1000.;
        status=independent?String::fromUTF8("Independente · sincronize novamente"):String::fromUTF8("Pareado · PC ")+role;
        if(role=="B" && !independent) send(link,"ready");
    }
    void setFollowing(bool value) { following=value; jaras::projectSync::following=value; }
    void failover(const String &reason) {
        auto link=activeLink(); if(following || (link && link->ready)) {independent=true;preferences.set("catlive.sync.independent",true);}
        setFollowing(false); if(link) link->ready=false; status=reason;
    }
    static bool valid(const var &m) {
        if(!m.isObject() || (int)m["version"]!=1 || !validID(m["node"])) return false;
        const auto type=m["type"].toString();
        if(!StringArray{"hello","auth","pair","accepted","rejected","resume","resumed","ready","state","ping","pong","release","error"}.contains(type)) return false;
        for(const auto *key:{"name","role","request","nonce","proof","token","error"}) if(m.hasProperty(key) && (!m[key].isString() || m[key].toString().getNumBytesAsUTF8()>1024)) return false;
        for(const auto *key:{"time","echo"}) if(m.hasProperty(key) && (!std::isfinite((double)m[key]) || (double)m[key]<0)) return false;
        if(m.hasProperty("role") && m["role"].toString()!="A" && m["role"].toString()!="B") return false;
        return true;
    }
    void prompt(const std::shared_ptr<Link> &link,const String &text,std::function<void(bool)> callback) {
        if(link->prompting || !confirm) { callback(false);return; }
        link->prompting=true; std::weak_ptr<int> alive=life;
        confirm(text,[alive,link,callback=std::move(callback)](bool ok){if(alive.expired())return;link->prompting=false;callback(ok);});
    }
    void received(const var &m,const std::shared_ptr<Link> &link) {
        if(!valid(m) || m["node"].toString()==node) return;
        const auto type=m["type"].toString(), remote=m["node"].toString().toUpperCase();
        if(type=="hello") {
            if(link->node.isNotEmpty() || !validID(m["nonce"])) return;
            link->node=remote;link->peerNonce=m["nonce"].toString().toUpperCase();link->name=m["name"].toString().substring(0,128);
            if(link->desiredRole.isNotEmpty()) { auto out=message("pair");put(out,"role",link->desiredRole);put(out,"request",link->request);send(*link,out); }
            else if(peerID==remote && secret.isNotEmpty()) { auto out=message("auth");put(out,"role",role);put(out,"proof",proof(*link));put(out,"independent",independent);send(*link,out); }
            return;
        }
        if(link->node!=remote) return;
        if(type=="pair" && !following && validID(m["request"]) && StringArray{"A","B"}.contains(m["role"].toString())) {
            const auto local=m["role"].toString()=="A"?String("B"):String("A"), request=m["request"].toString();
            prompt(link,link->name+String::fromUTF8(" solicita o pareamento. Este computador será o PC ")+local+".",[this,link,local,request](bool ok){
                if(!links.count(link->id))return;
                auto out=message(ok?"accepted":"rejected");put(out,"request",request);
                if(ok) { const auto token=Uuid().toDashedString().toUpperCase()+Uuid().toDashedString().toUpperCase();savePair(*link,local,token);put(out,"role",local);put(out,"token",token); }
                send(*link,out);if(ok)authenticated(*link);
            });return;
        }
        if(type=="accepted" && link->request.isNotEmpty() && m["request"].toString()==link->request && link->desiredRole.isNotEmpty() && m["role"].toString()!=link->desiredRole && m["token"].toString().length()>=64) {
            savePair(*link,link->desiredRole,m["token"].toString());link->desiredRole.clear();link->request.clear();authenticated(*link);return;
        }
        if(type=="rejected" && m["request"].toString()==link->request) {status="Pareamento recusado";link->request.clear();return;}
        if(type=="auth" && peerID==remote && m["role"].toString()!=role && secret.isNotEmpty()) {
            const auto expected=proof(*link).toStdString(), actual=m["proof"].toString().toStdString();
            unsigned diff=expected.size()==actual.size()?0:1;
            if(!diff) for(size_t i=0;i<expected.size();++i) diff|=(unsigned char)expected[i]^(unsigned char)actual[i];
            if(diff || expected.empty())return;
            authenticated(*link);if((bool)m["independent"])status=String::fromUTF8("Computador pareado independente · sincronize novamente");return;
        }
        if(!link->authenticated || active!=link->id || peerID!=remote) return;
        link->lastRx=Time::getMillisecondCounterHiRes()/1000.;
        if(type=="resume" && validID(m["request"])) {
            const auto request=m["request"].toString();
            prompt(link,link->name+" deseja sincronizar novamente os projetos.",[this,link,request](bool ok){
                if(!ok || active!=link->id)return;
                independent=false;preferences.set("catlive.sync.independent",false);if(resetApplied)resetApplied();leaderDevice=audioIdentity?audioIdentity():String();
                auto out=message("resumed");put(out,"request",request);send(*link,out);if(role=="B")send(*link,"ready");
            });
        } else if(type=="resumed" && link->resuming && m["request"].toString()==link->request) {
            link->resuming=false;link->request.clear();independent=false;preferences.set("catlive.sync.independent",false);if(resetApplied)resetApplied();leaderDevice=audioIdentity?audioIdentity():String();if(role=="B")send(*link,"ready");
        } else if(type=="ready" && role=="A" && !independent) {link->ready=true;leaderDevice=audioIdentity?audioIdentity():String();status=String::fromUTF8("PC A · sincronizando");
        } else if(type=="ping") {auto out=message("pong");put(out,"echo",m["time"]);send(*link,out);
        } else if(type=="pong" && m.hasProperty("echo")) {const auto rtt=Time::getMillisecondCounterHiRes()/1000.-(double)m["echo"];if(rtt>=0 && rtt<1)link->latency=std::min(.25,rtt/2);
        } else if(type=="release") failover(String::fromUTF8("PC A indisponível · controle independente"));
        else if(type=="error") status=m["error"].toString();
        else if(type=="state" && role=="B" && !independent && m["tabs"].isArray() && m["tabs"].size()<=64 && (int64)m["sequence"]>0 && (uint64)(int64)m["sequence"]>link->sequence) {
            link->sequence=(uint64)(int64)m["sequence"];
            const auto result=apply?apply(m,link->latency,link->id):ApplyResult{String::fromUTF8("Abra este projeto também no PC B"),false};
            const auto &problem=result.problem;
            if(result.applied) setFollowing(true);
            if(problem.isEmpty()) {setFollowing(true);status=String::fromUTF8("PC B · seguindo o PC A");lastProblem.clear();}
            else {status=problem;if(lastProblem!=problem){lastProblem=problem;auto out=message("error");put(out,"error",problem);send(*link,out);}}
        }
    }
    void timerCallback() override {
        const auto wired=ethernet.currentInterface();
        if(wired!=bound) {
            failover(String::fromUTF8("Cabo Ethernet desconectado · controle independente"));
            browser.stop(); transport.stop(); links.clear(); active.clear(); bound=wired;
            if(bound.index && bound.address.isNotEmpty()) { try {
                const int port=transport.start(SystemStats::getComputerName(),bound.address);
                browser.start(bound.index,bound.address,node,SystemStats::getComputerName(),port);
                status=independent?String::fromUTF8("Independente · sincronize novamente"):"Buscando computadores pelo cabo Ethernet";
            } catch(const std::exception &e) {status=String::fromUTF8(e.what());} }
            else status="Conecte os computadores por cabo Ethernet";
        }
        if(ethernet.busy()) {status=String::fromUTF8("Preparando conexão pelo cabo Ethernet…");return;}
        if(ethernet.preparationError().isNotEmpty())status=ethernet.preparationError();
        if(!enabled())return;
        if(browser.lastError())status=String::fromUTF8("Não foi possível buscar pelo cabo Ethernet (")+String(browser.lastError())+").";
        for(const auto &event:transport.events()) {
            if(event.type==Transport::Event::connected) {
                auto &link=links[event.client];if(!link)link=std::make_shared<Link>();link->id=event.client;link->binding=event.binding;
                auto out=message("hello");put(out,"name",SystemStats::getComputerName());put(out,"role",role);put(out,"nonce",link->nonce);put(out,"independent",independent);send(*link,out);
            } else if(event.type==Transport::Event::disconnected) {
                if(active==event.client){failover(String::fromUTF8("Conexão perdida · controle independente"));active.clear();}links.erase(event.client);
            } else if(event.kind==8) {
                auto it=links.find(event.client);if(it!=links.end())try{received(event.body,it->second);}catch(...){transport.disconnect(event.client);}
            }
        }
        const auto now=Time::getMillisecondCounterHiRes()/1000.;
        for(const auto &entry:links) if(!entry.second->authenticated && !entry.second->prompting && now-entry.second->lastRx>45)transport.disconnect(entry.first);
        auto link=activeLink();
        if(!link || !link->authenticated) {
            if(peerID.isNotEmpty() && now-lastConnect>4 && node.compare(peerID)<0 && links.empty())for(const auto &peer:peers())if(peer.id==peerID){lastConnect=now;const auto id=transport.connectTo(peer.address,peer.port,bound.address,bound.index);if(!id.empty()){auto next=std::make_shared<Link>();next->id=id;links[id]=next;}break;}
            return;
        }
        if(now-link->lastRx>1.5){failover(String::fromUTF8("Conexão perdida · controle independente"));transport.disconnect(link->id);return;}
        if(now-lastPing>.4){lastPing=now;auto out=message("ping");put(out,"time",now);send(*link,out);}
        if(role!="A" || !link->ready || independent)return;
        const auto currentDevice=audioIdentity?audioIdentity():String();
        if(currentDevice.isEmpty() || currentDevice!=leaderDevice){send(*link,"release");failover(String::fromUTF8("Interface de áudio indisponível · PC B independente"));return;}
        if(!snapshot)return;auto out=snapshot();
        if(!out.isObject() || !validID(out["active"])) {status="Salve o projeto uma vez para habilitar o Project Sync";return;}
        put(out,"version",1);put(out,"type","state");put(out,"node",node);put(out,"sequence",(int64)++sequence);put(out,"time",now);send(*link,out);
    }
};
}
