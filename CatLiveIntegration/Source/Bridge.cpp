#include "Bridge.h"
#include "httplib.h"
#include <algorithm>
#include <cmath>
#include <mutex>
#include <thread>
namespace integration {
static double elapsed(Clock::time_point from,Clock::time_point to=Clock::now()) { return std::chrono::duration<double>(to-from).count(); }
bool State::fresh(Clock::time_point now) const { return received!=Clock::time_point{} && elapsed(received,now)<stateTimeout; }
double State::at(Clock::time_point now) const { return position+(playing?std::clamp(elapsed(received,now),0.0,stateTimeout):0); }
State State::parse(const JSON& v,Clock::time_point now) {
    State s; s.sequence=v.at("sequence").get<uint64_t>(); s.position=v.at("position").get<double>();
    s.playing=v.at("playing").get<bool>(); s.deck=v.value("deck",0); s.column=v.value("column",0); s.jump=v.value("jump",uint64_t(0)); s.received=now;
    if(!std::isfinite(s.position)||s.position<0||s.position>=86400||s.deck<0||s.deck>1000||s.column<0||s.column>10000||(s.deck==0)!=(s.column==0)||s.sequence>9007199254740991ULL) throw std::runtime_error("Invalid transport state");
    return s;
}
struct Bridge::Impl {
    explicit Impl(std::filesystem::path directory):directory(std::move(directory)){}
    std::filesystem::path directory;
    mutable std::mutex mutex; std::mutex midiMutex;
    std::unique_ptr<httplib::Server> server;
    std::thread listener,mtcWorker,oscWorker,jobWorker;
    std::atomic<bool> stopping{true},cancelJob{false};
    MIDIOutput midi;
    std::string address,token,peer,clientName,message="Stopped",lastRequest;
    bool resolume=false,mtc=false,connected=false;
    int oscPort=7000,webPort=8080,port=defaultPort;
    uint64_t generation=0;
    State state;
    Clock::time_point heartbeat{};
    JSON job=JSON::object();
    JSON info() const {
        JSON ports=JSON::array(); for(auto& p:midiPorts()) ports.push_back({{"id",p.id},{"name",p.name}});
        return {{"name","CatLive Integration"},{"version","1.26"},{"protocol",protocolVersion},{"midiOutputs",ports},{"features",JSON::array({"resolume-create","grandma2-create"})}};
    }
    JSON status() const {
        std::lock_guard lock(mutex);
        return {{"running",!stopping.load()},{"connected",connected && elapsed(heartbeat)<leaseTimeout},
                {"address",address},{"port",port},{"client",clientName},{"message",message},{"job",job}};
    }
    static void response(httplib::Response& res,const JSON& value,int status=200) {
        res.status=status; res.set_header("Cache-Control","no-store"); res.set_content(value.dump(),"application/json");
    }
    // Called with mutex held, so authentication and mutation are one transaction.
    bool authorizedLocked(const httplib::Request& req,httplib::Response& res) {
        if(stopping||!connected||token.empty()||req.remote_addr!=peer||req.get_header_value("X-CatLive-Token")!=token||elapsed(heartbeat)>=leaseTimeout) {
            response(res,{{"error","Connection expired. Reconnect CatLive."}},401); return false;
        }
        return true;
    }
    void routes() {
        server->set_payload_max_length(2*1024*1024);
        server->set_read_timeout(2,0); server->set_write_timeout(2,0); server->set_keep_alive_timeout(2);
        server->new_task_queue=[] { return new httplib::ThreadPool(4,4,32); };
        server->set_pre_routing_handler([](const httplib::Request& req,httplib::Response& res) {
            if(req.has_header("Origin")) { response(res,{{"error","Desktop clients only"}},403); return httplib::Server::HandlerResponse::Handled; }
            return httplib::Server::HandlerResponse::Unhandled;
        });
        server->set_exception_handler([](const httplib::Request&,httplib::Response& res,std::exception_ptr error) {
            try { if(error) std::rethrow_exception(error); } catch(const std::exception& e) { response(res,{{"error",e.what()}},400); } catch(...) { response(res,{{"error","Invalid request"}},400); }
        });
        server->Get("/v1/info",[this](const auto&,auto& res){response(res,info());});
        server->Post("/v1/connect",[this](const auto& req,auto& res) {
            auto value=JSON::parse(req.body);
            if(value.at("protocol").template get<int>()!=protocolVersion) throw std::runtime_error("Update CatLive and CatLive Integration to compatible versions");
            auto name=value.at("name").template get<std::string>(); if(name.size()>512) throw std::runtime_error("Invalid name");
            int osc=value.value("oscPort",7000),web=value.value("webPort",8080);
            if(osc<1||osc>65535||web<1||web>65535||web==port) throw std::runtime_error("Invalid Resolume ports");
            const bool enableMTC=value.value("mtc",false);
            std::lock_guard lock(mutex);
            if(connected && elapsed(heartbeat)<leaseTimeout && (req.remote_addr!=peer || req.get_header_value("X-CatLive-Token")!=token)) {response(res,{{"error","Another CatLive is connected"}},409);return;}
            if(job.value("state","")=="running") {response(res,{{"error","File creation is still running"}},409);return;}
            { std::lock_guard midiLock(midiMutex); midi.close(); if(enableMTC) midi.open(value.value("midiOutput",std::string())); }
            token=secureToken(); lastRequest.clear();job=JSON::object();peer=req.remote_addr; clientName=name; heartbeat=Clock::now();
            state={}; ++generation; connected=true; resolume=value.value("resolume",false); mtc=enableMTC; oscPort=osc; webPort=web;
            message="Connected · "+name;
            auto result=info(); result["token"]=token; response(res,result);
        });
        server->Post("/v1/state",[this](const auto& req,auto& res) {
            auto next=State::parse(JSON::parse(req.body),Clock::now());
            std::lock_guard lock(mutex);
            if(!authorizedLocked(req,res)) return;
            if(next.sequence>state.sequence) {state=next;heartbeat=next.received;}
            response(res,{{"sequence",state.sequence}});
        });
        server->Post("/v1/disconnect",[this](const auto& req,auto& res) {
            std::lock_guard lock(mutex);
            if(!authorizedLocked(req,res)) return;
            connected=false;token.clear();state={};++generation;message="Waiting for CatLive";
            cancelJob=true; response(res,{{"ok",true}});
        });
        server->Get("/v1/job",[this](const auto& req,auto& res) {
            std::lock_guard lock(mutex);
            if(!authorizedLocked(req,res)) return;
            response(res,job);
        });
        auto registerCreate=[this](const std::string& path,bool grandma) {
        server->Post(path,[this,grandma](const auto& req,auto& res) {
            auto value=JSON::parse(req.body); auto plan=grandma?validateGrandMA2Plan(value.at("plan")):validatePlan(value.at("plan"));
            auto request=value.at("requestId").template get<std::string>();
            if(request.empty()||request.size()>128) throw std::runtime_error("Invalid operation ID");
            std::lock_guard lock(mutex);
            if(!authorizedLocked(req,res)) return;
            if(request==lastRequest) {response(res,job,202);return;}
            if(job.value("state","")=="running") {response(res,{{"error","File creation already running"}},409);return;}
            if(state.playing && state.fresh(Clock::now())) {response(res,{{"error","Stop playback before creating files"}},409);return;}
            if(jobWorker.joinable()) jobWorker.join();
            auto parent=directory/(grandma?"grandMA2":"Resolume");
            std::filesystem::create_directories(parent);
            std::string stem=plan.at("name"); for(char& c:stem) if((unsigned char)c<32||std::string("/\\:*?\"<>|").find(c)!=std::string::npos)c='_';
            if(stem.size()>100) {size_t end=100;while(end>0 && (static_cast<unsigned char>(stem[end])&0xc0)==0x80)--end;stem.resize(end);}
            if(stem.empty())stem="CatLive";
            auto destination=parent/std::filesystem::u8path(stem+"-"+secureToken().substr(0,12)+(grandma?"":".avc"));
            lastRequest=request;cancelJob=false;
            job={{"requestId",request},{"state","running"},{"message",grandma?"Creating grandMA2 macros":"Creating composition"},{"file",destination.u8string()}};
            int web=webPort;
            jobWorker=std::thread([this,plan,destination,web,grandma] {
                std::string error;
                try {
                    if(grandma)createGrandMA2(plan,destination,cancelJob);
                    else createComposition(plan,destination,web,cancelJob,[this](std::string text){std::lock_guard lock(mutex);job["message"]=text;});
                }
                catch(const std::exception& e) {error=e.what();}
                std::lock_guard lock(mutex);job["state"]=error.empty()?"done":"failed";job["message"]=error.empty()?"Files saved on this computer":error;
            });
            response(res,job,202);
        });
        };
        registerCreate("/v1/resolume/create",false);
        registerCreate("/v1/grandma2/create",true);
    }
    void timecodeLoop() {
        TimecodeClock clock;
        bool activeBefore=false; uint64_t lastGeneration=0,lastJump=0; double expected=0;
        int piece=0; std::array<int,8> parts{}; auto previous=Clock::now(),next=previous;
        while(!stopping) {
            next+=std::chrono::nanoseconds(8333333);auto now=Clock::now();
            const bool delayed=now-next>std::chrono::milliseconds(17);
            if(delayed){next=now+std::chrono::nanoseconds(8333333);piece=0;}
            State current; bool enabled,leased; uint64_t gen;
            {std::lock_guard lock(mutex);current=state;enabled=mtc;leased=connected;gen=generation;}
            bool fresh=current.fresh(now)&&leased,active=enabled&&fresh&&current.playing;
            double position=current.at(now);
            const bool seek=delayed||gen!=lastGeneration||current.jump!=lastJump||std::abs(position-expected)>0.15;
            if(enabled && fresh && (active||seek||activeBefore)) {
                const int frames=int(std::llround(position*30))%2592000;
                int frame=frames%30,sec=frames/30%60,min=frames/1800%60,hour=frames/108000%24;
                std::lock_guard lock(midiMutex);
                if(seek || active!=activeBefore) {midi.send({0xf0,0x7f,0x7f,0x01,0x01,uint8_t(hour|0x60),uint8_t(min),uint8_t(sec),uint8_t(frame),0xf7});piece=0;}
                if(active) {
                    if(piece==0)parts={frame&15,frame>>4,sec&15,sec>>4,min&15,min>>4,hour&15,(hour>>4)|6};
                    midi.send({0xf1,uint8_t((piece<<4)|parts[piece])});piece=(piece+1)%8;
                }
            }
            activeBefore=active;lastGeneration=gen;lastJump=current.jump;previous=now;
            expected=position+(active?0.008333:0);
            clock.waitUntil(next);
        }
    }
    void oscLoop() {
        int lastDeck=0,lastColumn=0,lastPort=7000,lastSpeed=-1;uint64_t genBefore=0,jumpBefore=0;
        std::string pressed,pending; auto pressAt=Clock::now(),releaseAt=pressAt; bool wasEnabled=false;
        while(!stopping) {
            State current; bool enabled,leased,busy;int port;uint64_t gen;
            {std::lock_guard lock(mutex);current=state;enabled=resolume;leased=connected;port=oscPort;gen=generation;busy=job.value("state","")=="running";if(busy&&elapsed(heartbeat)>=leaseTimeout)cancelJob=true;}
            auto now=Clock::now(); bool usable=enabled&&leased&&current.fresh(now)&&!busy;
            if(!pressed.empty() && (now>=releaseAt || gen!=genBefore || !usable)) {sendOSC(lastPort,pressed,0);pressed.clear();}
            if(gen!=genBefore || !usable) {pending.clear();lastDeck=lastColumn=0;}
            if(usable) {
                int speed=current.playing?1:0;
                if(lastSpeed!=speed || gen!=genBefore) {sendOSC(port,"/composition/speed",speed,true);lastSpeed=speed;}
                if(current.deck && (current.deck!=lastDeck||current.column!=lastColumn||current.jump!=jumpBefore)) {
                    if(!pressed.empty()){sendOSC(lastPort,pressed,0);pressed.clear();}
                    const bool deckChange=current.deck!=lastDeck;
                    if(deckChange)sendOSC(port,"/composition/decks/"+std::to_string(current.deck)+"/select",1);
                    pending="/composition/columns/"+std::to_string(current.column)+"/connect";
                    pressAt=now+(deckChange?std::chrono::milliseconds(70):std::chrono::milliseconds(0));
                    lastDeck=current.deck;lastColumn=current.column;
                }
                if(!pending.empty() && now>=pressAt) {sendOSC(port,pending,1);pressed=pending;pending.clear();releaseAt=now+std::chrono::milliseconds(45);}
            } else if(wasEnabled && lastSpeed!=0) {sendOSC(lastPort,"/composition/speed",0,true);lastSpeed=0;}
            wasEnabled=enabled;lastPort=port;genBefore=gen;jumpBefore=current.jump;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        if(!pressed.empty())sendOSC(lastPort,pressed,0);
        if(wasEnabled)sendOSC(lastPort,"/composition/speed",0,true);
    }
};
Bridge::Bridge(std::filesystem::path directory):impl(std::make_unique<Impl>(std::move(directory))){}
Bridge::~Bridge(){stop();}
void Bridge::start(const std::string& address,int port) {
    stop(); if(address.empty()||address=="0.0.0.0"||port<1||port>65535)throw std::runtime_error("Choose an Ethernet adapter");
    impl->server=std::make_unique<httplib::Server>();impl->address=address;impl->port=port;impl->routes();
    if(!impl->server->bind_to_port(address,port)){impl->server.reset();throw std::runtime_error("Could not open the selected adapter or port");}
    impl->stopping=false;impl->message="Waiting for CatLive";
    impl->listener=std::thread([this]{impl->server->listen_after_bind();});
    impl->mtcWorker=std::thread([this]{impl->timecodeLoop();});impl->oscWorker=std::thread([this]{impl->oscLoop();});
}
void Bridge::stop() {
    impl->stopping=true;impl->cancelJob=true;
    if(impl->server)impl->server->stop();
    for(auto thread:{&impl->listener,&impl->mtcWorker,&impl->oscWorker,&impl->jobWorker}) if(thread->joinable())thread->join();
    impl->server.reset();impl->midi.close();
    std::lock_guard lock(impl->mutex);impl->connected=false;impl->token.clear();impl->state={};++impl->generation;impl->message="Stopped";
}
JSON Bridge::status()const{return impl->status();}
}
