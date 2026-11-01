#include "Bridge.h"
#include "httplib.h"
#include <thread>
#include <set>
namespace integration {
JSON validatePlan(const JSON& input) {
    JSON plan={{"name",input.at("name").get<std::string>()},{"decks",JSON::array()}};
    if(plan["name"].get<std::string>().empty()||plan["name"].get<std::string>().size()>512||!input.at("decks").is_array()||input["decks"].empty()||input["decks"].size()>1000)throw std::runtime_error("Invalid Resolume map");
    std::set<int> decks;
    for(const auto& deck:input["decks"]) {
        int number=deck.at("number").get<int>();auto name=deck.at("name").get<std::string>();
        if(number<1||number>1000||!decks.insert(number).second||name.size()>512||!deck.at("columns").is_array()||deck["columns"].empty()||deck["columns"].size()>10000)throw std::runtime_error("Invalid Resolume deck");
        JSON columns=JSON::array();std::set<int> indices;
        for(const auto& column:deck["columns"]) {int index=column.at("number").get<int>();auto title=column.at("name").get<std::string>();if(index<1||index>10000||title.size()>512||!indices.insert(index).second)throw std::runtime_error("Invalid Resolume column");columns.push_back({{"number",index},{"name",title}});}
        plan["decks"].push_back({{"number",number},{"name",name},{"columns",columns}});
    }
    return plan;
}
namespace {
struct HTTPFailure:std::runtime_error {int status;HTTPFailure(int status):std::runtime_error("Resolume HTTP "+std::to_string(status)),status(status){}};
struct Unconfirmed:std::runtime_error {Unconfirmed():std::runtime_error("Resolume did not confirm the request") {}};
std::string name(const JSON& v){return v.contains("name")&&v["name"].is_object()?v["name"].value("value",std::string()):std::string();}
const JSON& array(const JSON& v,const char* key){static const JSON empty=JSON::array();return v.contains(key)&&v[key].is_array()?v[key]:empty;}
std::string fileURI(const std::filesystem::path& path) {
    std::string value=path.generic_u8string(),result="file://";if(value.empty()||value.front()!='/')result+='/';
    const char* hex="0123456789ABCDEF";
    for(unsigned char c:value)if(std::isalnum(c)||c=='/'||c==':'||c=='-'||c=='_'||c=='.'||c=='~')result+=char(c);else{result+='%';result+=hex[c>>4];result+=hex[c&15];}
    return result;
}
class Creator {
    httplib::Client client;
    const std::atomic<bool>& cancelled;
    std::function<void(std::string)> progress;
    void check(){if(cancelled)throw std::runtime_error("Operation cancelled");}
    void sleep(int millis){for(int i=0;i<millis;i+=20){check();std::this_thread::sleep_for(std::chrono::milliseconds(20));}}
    JSON call(std::string path,std::string method="GET",const JSON& value=JSON(),std::string raw={}) {
        check();httplib::Request request;request.path="/api/v1"+path;request.method=method;
        request.headers={{"Content-Type",raw.empty()?"application/json":"text/plain"},{"Cache-Control","no-cache"}};
        if(!raw.empty())request.body=raw;else if(!value.is_null())request.body=value.dump();
        auto response=client.send(request);check();if(!response)throw Unconfirmed();
        if(response->status<200||response->status>=300)throw HTTPFailure(response->status);
        if(response->body.empty())return JSON::object();auto result=JSON::parse(response->body,nullptr,false);
        if(result.is_discarded()||!result.is_object())return JSON::object();return result;
    }
    JSON wait(const std::function<bool(const JSON&)>& predicate,int seconds=15) {
        auto deadline=Clock::now()+std::chrono::seconds(seconds);
        while(Clock::now()<deadline) {check();try{auto state=call("/composition");if(predicate(state))return state;}catch(const HTTPFailure& e){if(e.status!=404&&e.status!=412)throw;}catch(const Unconfirmed&){}sleep(180);}
        throw std::runtime_error("Resolume did not confirm the operation. Check its composition before trying again.");
    }
    JSON mutate(const std::string& path,const std::string& method,const JSON& body,const std::function<bool(const JSON&)>& predicate) {
        for(int attempt=0;attempt<4;++attempt) {
            try{call(path,method,body);}
            catch(const HTTPFailure& e){if(e.status!=412||attempt==3)throw;sleep(400);auto state=call("/composition");if(predicate(state))return state;continue;}
            catch(const Unconfirmed&){return wait(predicate,30);}
            return wait(predicate);
        }
        throw std::runtime_error("Resolume is busy");
    }
    JSON select(int index) {
        return mutate("/composition/decks/"+std::to_string(index)+"/select","POST",JSON(),[index](const JSON& v){const auto& decks=array(v,"decks");return decks.size()>=size_t(index)&&decks[index-1].contains("selected")&&decks[index-1]["selected"].value("value",false);});
    }
public:
    Creator(int port,const std::atomic<bool>& cancelled,std::function<void(std::string)> progress):client("127.0.0.1",port),cancelled(cancelled),progress(std::move(progress)) {
        client.set_payload_max_length(32*1024*1024);client.set_connection_timeout(1,0);client.set_read_timeout(2,0);client.set_write_timeout(2,0);client.set_keep_alive(true);client.set_follow_location(false);
    }
    void create(const JSON& plan,const std::filesystem::path& destination) {
        if(std::filesystem::exists(destination))throw std::runtime_error("Destination already exists");
        auto product=call("/product");auto productName=product.value("name",std::string());
        std::transform(productName.begin(),productName.end(),productName.begin(),[](unsigned char c){return char(std::tolower(c));});
        if(productName.find("arena")==std::string::npos||product.value("major",0)<7||(product.value("major",0)==7&&product.value("minor",0)<22))throw std::runtime_error("Automatic composition creation requires Resolume Arena 7.22 or later");
        auto composition=call("/composition");const auto decks=array(composition,"decks");
        if(decks.empty())throw std::runtime_error("Open a new empty composition in Resolume first");
        for(auto& d:decks) {auto title=name(d);std::transform(title.begin(),title.end(),title.begin(),[](unsigned char c){return char(std::tolower(c));});if(!title.empty()&&title!="empty"&&!(title.rfind("empty ",0)==0&&std::all_of(title.begin()+6,title.end(),[](unsigned char c){return std::isdigit(c); })))throw std::runtime_error("Open a new empty composition in Resolume first");}
        // Validate every inactive deck as well before the first destructive mutation.
        for(int i=1;i<=int(decks.size());++i) {composition=select(i);for(const auto& layer:array(composition,"layers"))for(const auto& clip:array(layer,"clips"))
            if((clip.contains("audio")&&!clip["audio"].is_null())||(clip.contains("video")&&!clip["video"].is_null())||(clip.contains("connected")&&clip["connected"].value("value",std::string("Empty"))!="Empty"))throw std::runtime_error("The Resolume composition contains media. Open a new empty composition first.");}
        int count=0;for(auto& deck:plan["decks"])count=std::max(count,deck["number"].get<int>());
        while(array(composition,"decks").size()>1){auto before=array(composition,"decks").size();composition=mutate("/composition/decks/"+std::to_string(before),"DELETE",JSON(),[before](const JSON& v){return array(v,"decks").size()==before-1;});}
        while(array(composition,"decks").size()<size_t(count)){auto before=array(composition,"decks").size();composition=mutate("/composition/decks/add","POST",JSON(),[before](const JSON& v){return array(v,"decks").size()==before+1;});}
        JSON deckNames=JSON::array();std::vector<std::string> names;
        for(int i=1;i<=count;++i){std::string title="Reserved "+std::to_string(i);for(auto& deck:plan["decks"])if(deck["number"]==i)title=deck["name"];names.push_back(title);deckNames.push_back({{"id",array(composition,"decks")[i-1].at("id")},{"name",{{"value",title}}}});}
        composition=mutate("/composition","PUT",{{"name",{{"value",plan["name"]}}},{"decks",deckNames}},[&](const JSON& v){if(name(v)!=plan["name"]||array(v,"decks").size()!=names.size())return false;for(size_t i=0;i<names.size();++i)if(name(array(v,"decks")[i])!=names[i])return false;return true;});
        for(int i=1;i<=count;++i) {
            progress("Deck "+std::to_string(i)+" / "+std::to_string(count));composition=select(i);JSON columns=JSON::array();int total=1;
            for(auto& d:plan["decks"])if(d["number"]==i)columns=d["columns"];
            for(auto& col:columns)total=std::max(total,col["number"].get<int>());
            if(array(composition,"columns").size()<size_t(total))composition=mutate("/composition/grow-to","POST",{{"column_count",total}},[total](const JSON& v){return array(v,"columns").size()>=size_t(total);});
            while(array(composition,"columns").size()>size_t(total)){auto before=array(composition,"columns").size();composition=mutate("/composition/columns/"+std::to_string(before),"DELETE",JSON(),[before](const JSON& v){return array(v,"columns").size()==before-1;});}
            for(auto& col:columns){int n=col["number"];std::string title=col["name"];composition=mutate("/composition/columns/"+std::to_string(n),"PUT",{{"name",{{"value",title}}}},[n,title](const JSON& v){return array(v,"columns").size()>=size_t(n)&&name(array(v,"columns")[n-1])==title;});}
        }
        select(1);progress("Saving composition on this computer");
        try{call("/composition/save","POST",JSON(),fileURI(destination));}catch(const Unconfirmed&){}
        auto deadline=Clock::now()+std::chrono::seconds(30);
        while(Clock::now()<deadline){check();std::error_code error;auto size=std::filesystem::file_size(destination,error);if(!error&&size>0)return;sleep(180);}
        throw std::runtime_error("Resolume did not confirm saving the .avc file");
    }
};
}
void createComposition(const JSON& plan,const std::filesystem::path& file,int port,const std::atomic<bool>& cancelled,const std::function<void(std::string)>& progress){Creator(port,cancelled,progress).create(validatePlan(plan),file);}
}
