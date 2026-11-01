#pragma once
#include "Common.h"
namespace catlive {
// This worker owns all network I/O. The presentation timer only replaces one
// latest snapshot; a slow receiver cannot queue old cues or block playback.
class IntegrationClient final : private Thread {
public:
    IntegrationClient():Thread("CatLive Integration") { startThread(Thread::Priority::normal); }
    ~IntegrationClient() override { signalThreadShouldExit(); notify(); stopThread(4000); }
    void configure(var value) { const ScopedLock lock(mutex); if(JSON::toString(config)==JSON::toString(value))return;config=value.clone();state=object();stateClock=0;++revision;notify(); }
    void update(double position,bool playing,int deck,int column,uint64 jump) {
        auto value=object();put(value,"position",position);put(value,"playing",playing);put(value,"deck",deck);put(value,"column",column);put(value,"jump",(int64)jump);
        const ScopedLock lock(mutex);state=std::move(value);stateClock=Time::getMillisecondCounterHiRes();
    }
    String status() { const ScopedLock lock(mutex);return failure; }
    bool connected(){const ScopedLock lock(mutex);return token.isNotEmpty();}
    static var request(const var& config,const String& path,const var& body={},const String& token={}) {
        const auto host=str(config,"host").trim();const int port=(int)num(config,"port",48726);
        if(host.isEmpty()||host.containsAnyOf("/\\?#@ \r\n\t")||port<1||port>65535)throw std::runtime_error("Endereço do CatLive Integration inválido.");
        URL url("http://"+host+":"+String(port)+"/v1/"+path);if(body.isObject())url=url.withPOSTData(JSON::toString(body,true));
        int status=0;auto stream=url.createInputStream(URL::InputStreamOptions(URL::ParameterHandling::inAddress).withHttpRequestCmd(body.isObject()?"POST":"GET")
            .withConnectionTimeoutMs(1000).withNumRedirectsToFollow(0).withStatusCode(&status)
            .withExtraHeaders("Content-Type: application/json\r\nCache-Control: no-cache\r\n"+(token.isNotEmpty()?"X-CatLive-Token: "+token+"\r\n":String())));
        if(!stream)throw std::runtime_error("CatLive Integration não respondeu. Confira o IP e o cabo.");
        MemoryOutputStream bytes;std::array<char,4096> buffer{};
        while(!stream->isExhausted()){auto read=stream->read(buffer.data(),(int)buffer.size());if(read<=0)break;if(bytes.getDataSize()+read>2*1024*1024)throw std::runtime_error("Resposta Integration grande demais.");bytes.write(buffer.data(),(size_t)read);}
        auto value=JSON::parse(bytes.toUTF8());
        if(status<200||status>=300)throw std::runtime_error(utf8(str(value,"error","CatLive Integration HTTP "+String(status))));
        if(!value.isObject())throw std::runtime_error("Resposta inválida do CatLive Integration.");return value;
    }
    String create(const var& plan,const std::function<bool()>& cancelled) {
        var current;String auth;
        for(int i=0;i<30;++i){{const ScopedLock lock(mutex);current=config.clone();auth=token;}if(auth.isNotEmpty())break;if(cancelled())throw std::runtime_error("Operação cancelada.");Thread::sleep(100);}
        if(auth.isEmpty())throw std::runtime_error("Conecte o CatLive Integration primeiro.");
        const auto id=Uuid().toDashedString();auto body=object();put(body,"requestId",id);put(body,"plan",plan);
        request(current,"resolume/create",body,auth);
        const auto deadline=Time::getMillisecondCounterHiRes()+600000;
        while(Time::getMillisecondCounterHiRes()<deadline && !cancelled()) {
            auto job=request(current,"job",{},auth);if(str(job,"requestId")!=id)throw std::runtime_error("A operação do Integration mudou.");
            if(str(job,"state")=="done")return str(job,"file");if(str(job,"state")=="failed")throw std::runtime_error(utf8(str(job,"message")));
            Thread::sleep(300);
        }throw std::runtime_error("Criação não confirmada pelo CatLive Integration.");
    }
private:
    CriticalSection mutex;var config=object(),state=object();String token,failure;uint64 revision=0;double stateClock=0;
    void run() override {
        var current;String auth;uint64 version=~uint64(0),sequence=0;double retry=0;
        while(!threadShouldExit()) {
            var next,snapshot;uint64 nextVersion;double snapshotClock;
            {const ScopedLock lock(mutex);next=config.clone();snapshot=state.clone();nextVersion=revision;snapshotClock=stateClock;}
            if(version!=nextVersion) {
                if(auth.isNotEmpty())try{request(current,"disconnect",object(),auth);}catch(...){}
                current=next;version=nextVersion;auth.clear();sequence=0;retry=0;
                const ScopedLock lock(mutex);token.clear();failure.clear();
            }
            if(!flag(current,"enabled")){wait(100);continue;}
            if(Time::getMillisecondCounterHiRes()<retry){wait(50);continue;}
            try {
                if(auth.isEmpty()) {
                    auto body=object();put(body,"protocol",1);put(body,"name",str(current,"name"));put(body,"resolume",flag(current,"resolume"));put(body,"mtc",flag(current,"mtc"));
                    put(body,"oscPort",(int)num(current,"oscPort",7000));put(body,"webPort",(int)num(current,"webPort",8080));put(body,"midiOutput",str(current,"midiOutput"));
                    auto result=request(current,"connect",body);auth=str(result,"token");if(num(result,"protocol")!=1||auth.length()!=64)throw std::runtime_error("Atualize o CatLive Integration.");
                    const ScopedLock lock(mutex);token=auth;
                }
                if(snapshot.getDynamicObject()->getProperties().size()) {
                    const double age=std::max(0.0,(Time::getMillisecondCounterHiRes()-snapshotClock)/1000.0);
                    if(flag(snapshot,"playing"))put(snapshot,"position",num(snapshot,"position")+std::min(age,0.5));
                    if(age>=0.5)put(snapshot,"playing",false);
                    put(snapshot,"sequence",(int64)++sequence);request(current,"state",snapshot,auth);
                }
                {const ScopedLock lock(mutex);failure.clear();}
            }catch(const std::exception& e){auth.clear();retry=Time::getMillisecondCounterHiRes()+1000;const ScopedLock lock(mutex);token.clear();failure=String::fromUTF8(e.what());}
            wait(35);
        }
        if(auth.isNotEmpty())try{request(current,"disconnect",object(),auth);}catch(...){}
    }
};
}
