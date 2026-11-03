#include "Bridge.h"
#include "httplib.h"
#include <fstream>
#include <thread>
using namespace integration;
void require(bool,const char*);
static std::string read(const std::filesystem::path& path){std::ifstream f(path);return {std::istreambuf_iterator<char>(f),{}};}
void testGrandMA2() {
    const auto directory=std::filesystem::temp_directory_path()/("catlive-ma-test-"+secureToken().substr(0,12));
    JSON settings={{"sequence",10},{"page",2},{"executor",20},{"timecode",30},{"slot",2}};
    auto region=[](const char* id,const char* name,double start,int offset,bool selected){return JSON{{"id",id},{"name",name},{"start",start},{"end",start+10},{"offset",offset},{"selected",selected},{"cues",JSON::array({{{"name","Inicio"},{"position",start}},{{"name","Verse"},{"position",start+2}}})}};};
    JSON plan={{"name","Show"},{"settings",settings},{"regions",JSON::array({region("a","Song",0,0,true),region("b","Song",20,4,true),region("c","Song-2",40,8,false)})}};
    std::atomic<bool> cancelled{false};
    createGrandMA2(plan,directory/"local",cancelled);
    auto macro=read(directory/"local/macros/Song-macro.xml");
    require(macro.find("Sequence 10 Cue 2")!=std::string::npos,"Selected region macro contains cues");
    require(macro.find("/SwitchOff=&quot;Keep Playbacks&quot;")!=std::string::npos,"Keep playback semantics");
    require(macro.find("Executor 2.20")!=std::string::npos,"Page and executor use saved assignment");
    auto tc=read(directory/"local/import/Song-timecode.xml");
    require(tc.find("time=\"1200\" command=\"Off\"")!=std::string::npos,"Unselected regions still switch other songs off");
    require(tc.find("time=\"60\" command=\"Goto\"")!=std::string::npos,"Cue time uses 30 FPS");
    require(std::filesystem::exists(directory/"local/macros/Song-3-macro.xml"),"Duplicate name does not steal reserved song filename");
    require(!std::filesystem::exists(directory/"local/macros/Song-2-macro.xml"),"Partial export omits unselected songs");
    bool rejected=false;try{createGrandMA2(plan,directory/"local",cancelled);}catch(...){rejected=true;}require(rejected,"Never replace an existing export");
    cancelled=true;rejected=false;try{createGrandMA2(plan,directory/"cancelled",cancelled);}catch(...){rejected=true;}require(rejected&&!std::filesystem::exists(directory/"cancelled"),"Cancelled export never publishes partial files");
    auto invalid=plan;invalid["regions"][0]["cues"][0]["position"]=-1;
    rejected=false;try{validateGrandMA2Plan(invalid);}catch(...){rejected=true;}require(rejected,"Reject invalid cue timing");
    invalid=plan;invalid["regions"][1]["offset"]=0;rejected=false;try{validateGrandMA2Plan(invalid);}catch(...){rejected=true;}require(rejected,"Reject duplicate destination");
    httplib::Server probe;int port=probe.bind_to_any_port("127.0.0.1");probe.stop();Bridge bridge(directory/"remote");bridge.start("127.0.0.1",port);
    httplib::Client client("127.0.0.1",port);client.set_read_timeout(2,0);
    auto response=client.Post("/v1/connect",JSON{{"protocol",1},{"name","Mac"},{"mtc",false},{"resolume",false}}.dump(),"application/json");
    require(response&&response->status==200,"Connect for grandMA2 creation");
    const auto token=JSON::parse(response->body)["token"].get<std::string>();httplib::Headers headers={{"X-CatLive-Token",token}};
    auto post=[&](const char* path,const JSON& body){return client.Post(path,headers,body.dump(),"application/json");};
    require(post("/v1/state",{{"sequence",1},{"position",0},{"playing",true}})->status==200,"Playing state accepted");
    JSON request={{"requestId","grandma-job"},{"plan",plan}};
    require(post("/v1/grandma2/create",request)->status==409,"Cannot create macros during playback");
    require(post("/v1/state",{{"sequence",2},{"position",0},{"playing",false}})->status==200,"Stopped state accepted");
    require(post("/v1/grandma2/create",request)->status==202,"Receiver accepts grandMA2 plan");
    JSON job;for(int i=0;i<100;++i){auto r=client.Get("/v1/job",headers);require(bool(r),"Read job");job=JSON::parse(r->body);if(job.value("state","")!="running")break;std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    require(job.value("state","")=="done","Remote macro creation completes");
    auto folder=std::filesystem::u8path(job.at("file").get<std::string>());
    require(folder.parent_path()==directory/"remote/grandMA2","Receiver controls destination directory");
    require(std::filesystem::exists(folder/"macros/00-Importar tudo - Show-macro.xml"),"Receiver writes installer macro");
    auto again=post("/v1/grandma2/create",request);require(again&&JSON::parse(again->body)["file"]==job["file"],"Network retry cannot duplicate an export");
    bridge.stop();std::filesystem::remove_all(directory);
}
