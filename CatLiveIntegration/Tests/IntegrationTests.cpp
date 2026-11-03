#include "Bridge.h"
#include "httplib.h"
#include <iostream>
#include <fstream>
#include <thread>
#include <limits>
using namespace integration;
void require(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
void testOSC();
void testGrandMA2();
#ifdef __APPLE__
void testMIDI();
#endif
int main(int argc,char** argv){try{
    auto directory=std::filesystem::temp_directory_path()/std::filesystem::u8path("catlive-integration-test-"+secureToken().substr(0,10));
    if(argc==4 && std::string(argv[1])=="--serve") {Bridge bridge(directory);bridge.start(argv[2],std::stoi(argv[3]));std::cout<<"READY"<<std::endl;std::string line;std::getline(std::cin,line);return 0;}
    auto now=Clock::now();auto state=State::parse({{"sequence",1},{"position",12.5},{"playing",true},{"deck",1},{"column",2}},now);
    require(std::abs(state.at(now+std::chrono::milliseconds(100))-12.6)<1e-6,"MTC must interpolate local monotonic time");
    require(!state.fresh(now+std::chrono::milliseconds(501)),"Disconnected transport must expire");
    require(state.at(now+std::chrono::seconds(5))<=13.0,"Lost connection must not advance indefinitely");
    bool rejected=false;try{State::parse({{"sequence",2},{"position",1},{"playing",true},{"deck",1},{"column",0}},now);}catch(...){rejected=true;}require(rejected,"Reject partial cues");
    Bridge bridge(directory);httplib::Server probe;int port=probe.bind_to_any_port("127.0.0.1");probe.stop();bridge.start("127.0.0.1",port);
    httplib::Client client("127.0.0.1",port);client.set_read_timeout(2,0);
    auto post=[&](const char* path,const JSON& body,const std::string& token=""){return client.Post(path,{{"X-CatLive-Token",token}},body.dump(),"application/json");};
    auto info=client.Get("/v1/info");require(info&&JSON::parse(info->body)["protocol"]==1,"Receiver identity");
    auto connected=post("/v1/connect",{{"protocol",1},{"name","Show test"},{"resolume",false},{"mtc",false}});
    require(connected&&connected->status==200,"First client connects");auto token=JSON::parse(connected->body)["token"].get<std::string>();require(token.size()==64,"Random session token");
    auto other=post("/v1/connect",{{"protocol",1},{"name","Other"}});require(other&&other->status==409,"Only one sender owns this receiver");
    JSON payload={{"sequence",2},{"position",30},{"playing",true},{"deck",1},{"column",1}};
    require(post("/v1/state",payload,"bad")->status==401,"Reject unknown token");
    require(post("/v1/state",payload,token)->status==200,"Accept state");payload["sequence"]=1;payload["position"]=0;
    auto old=post("/v1/state",payload,token);require(JSON::parse(old->body)["sequence"]==2,"Ignore stale packets");
    require(post("/v1/disconnect",{},token)->status==200,"Disconnect accepted");require(post("/v1/state",payload,token)->status==401,"Old session revoked");
    bridge.stop();bridge.start("127.0.0.1",port);require(!bridge.status()["connected"].get<bool>(),"Restart cannot replay previous show");bridge.stop();
    // Real HTTP fixture models the local Arena API and confirms saved content.
    httplib::Server arena;JSON composition={{"name",{{"value","Untitled"}}},{"decks",JSON::array({{{"id",1},{"name",{{"value","Empty"}}},{"selected",{{"value",true}}}}})},{"layers",JSON::array({{{"clips",JSON::array({{{"audio",nullptr},{"video",nullptr},{"connected",{{"value","Empty"}}}}})}}})},{"columns",JSON::array({{{"name",{{"value",""}}}}})}};
    auto reply=[](auto& response,const JSON& value){response.set_content(value.dump(),"application/json");};
    arena.Get("/api/v1/product",[&](auto&,auto& r){reply(r,{{"name","Arena"},{"major",7},{"minor",22}});});
    arena.Get("/api/v1/composition",[&](auto&,auto& r){reply(r,composition);});
    arena.Post("/api/v1/composition/decks/1/select",[&](auto&,auto& r){reply(r,composition);});
    arena.Put("/api/v1/composition",[&](auto& req,auto& r){auto v=JSON::parse(req.body);composition["name"]=v["name"];composition["decks"][0]["name"]=v["decks"][0]["name"];reply(r,composition);});
    arena.Put("/api/v1/composition/columns/1",[&](auto& req,auto& r){composition["columns"][0]=JSON::parse(req.body);reply(r,composition);});
    std::filesystem::create_directories(directory);auto file=directory/"Test.avc";
    arena.Post("/api/v1/composition/save",[&](auto& req,auto& r){require(req.body.rfind("file:///",0)==0,"Receiver saves via local file URI");std::ofstream(file)<<composition.dump();reply(r,JSON::object());});
    int apiPort=arena.bind_to_any_port("127.0.0.1");std::thread api([&]{arena.listen_after_bind();});
    std::atomic<bool> cancelled{false};
    try {JSON plan={{"name","Test show"},{"decks",JSON::array({{{"number",1},{"name","Song"},{"columns",JSON::array({{{"number",1},{"name","Inicio"}}})}}})}};
        createComposition(plan,file,apiPort,cancelled,[](auto){});require(std::filesystem::file_size(file)>0,"Composition saved on receiver");
        rejected=false;try{createComposition(plan,directory/"Other.avc",apiPort,cancelled,[](auto){});}catch(...){rejected=true;}require(rejected,"Existing composition must be protected");
    } catch(...){arena.stop();api.join();throw;}
    arena.stop();api.join();std::filesystem::remove_all(directory);
    testOSC();
    testGrandMA2();
#ifdef __APPLE__
    testMIDI();
#endif
    std::cout<<"INTEGRATION_OSC_MIDI_CONNECTION_OWNERSHIP_STALE_STATE_TIMEOUT_AND_LOCAL_COMPOSITION_OK\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
