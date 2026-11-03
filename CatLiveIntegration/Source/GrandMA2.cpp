#include "Bridge.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <set>
#include <sstream>

namespace integration {
namespace {
std::string label(const std::string& text, const std::string& fallback="Marcador") {
    std::string result; bool space=false;
    for (unsigned char c:text) {
        if ((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-') {
            if (space&&!result.empty()) result+=' ';
            result+=char(c);space=false;
        } else space=true;
    }
    if (result.empty()) return fallback;
    if (result.size()>96) result.resize(96);
    while (!result.empty()&&result.back()==' ')result.pop_back();
    return result;
}
std::string lower(std::string text) { for(char& c:text)if(c>='A'&&c<='Z')c+=32;return text; }
std::string stem(const std::string& name) {
    auto result=label(name,"Projeto CatLive"), key=lower(result);
    if(key=="con"||key=="prn"||key=="aux"||key=="nul"||(key.size()==4&&(key.substr(0,3)=="com"||key.substr(0,3)=="lpt")&&key[3]>='1'&&key[3]<='9'))result="_"+result;
    return result;
}
std::string xml(const std::string& text) {
    std::string out;for(char c:text)switch(c){case '&':out+="&amp;";break;case '<':out+="&lt;";break;case '>':out+="&gt;";break;case '"':out+="&quot;";break;case '\'':out+="&apos;";break;default:out+=c;}
    return out;
}
std::string header(const std::string& show,const std::string& type) {
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<?xml-stylesheet type=\"text/xsl\" href=\"styles/"+type+"@sheet.xsl\"?>\r\n"
        "<MA xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"http://schemas.malighting.de/grandma2/xml/MA\" "
        "xsi:schemaLocation=\"http://schemas.malighting.de/grandma2/xml/MA http://schemas.malighting.de/grandma2/xml/3.9.61/MA.xsd\" "
        "major_vers=\"3\" minor_vers=\"9\" stream_vers=\"61\">\r\n  <Info showfile=\""+xml(show)+"\" />\r\n";
}
std::string macro(const std::string& show,const std::string& name,const std::vector<std::string>& commands) {
    auto out=header(show,"macro")+"  <Macro index=\"0\" name=\""+xml(label(name))+"\">\r\n";
    for(size_t i=0;i<commands.size();++i)out+="    <Macroline index=\""+std::to_string(i)+"\">\r\n      <text>"+xml(commands[i])+"</text>\r\n    </Macroline>\r\n";
    return out+"  </Macro>\r\n</MA>\r\n";
}
std::string trigger(double seconds) {
    auto t=std::llround(std::round(seconds*30)/30*100);
    std::ostringstream out;out<<t/360000<<'H'<<t/6000%60<<'M'<<t/100%60<<'.'<<std::setfill('0')<<std::setw(2)<<t%100<<'S';return out.str();
}
int integer(const JSON& value,int minimum,int maximum) {
    if(!value.is_number_integer())throw std::runtime_error("Invalid grandMA2 numbering");
    auto n=value.get<int64_t>();if(n<minimum||n>maximum)throw std::runtime_error("Invalid grandMA2 numbering");return int(n);
}
double position(const JSON& value) {
    auto n=value.get<double>();if(!std::isfinite(n)||n<0||n>86400)throw std::runtime_error("Invalid grandMA2 timecode position");return n;
}
void write(const std::filesystem::path& file,const std::string& content) {
    std::ofstream out(file,std::ios::binary);out.write(content.data(),std::streamsize(content.size()));out.close();
    if(!out)throw std::runtime_error("Could not save grandMA2 files");
}
}

JSON validateGrandMA2Plan(const JSON& input) {
    JSON plan=input;
    auto name=plan.at("name").get<std::string>();if(name.size()>512)throw std::runtime_error("Invalid project name");plan["name"]=label(name,"Projeto CatLive");
    const auto& settings=plan.at("settings");
    for(auto key:{"sequence","page","executor","timecode"})integer(settings.at(key),1,9999);
    integer(settings.at("slot"),1,8);
    auto& regions=plan.at("regions");if(!regions.is_array()||regions.empty()||regions.size()>9999)throw std::runtime_error("Select at least one song for grandMA2");
    size_t totalCues=0,selected=0;std::set<std::string> ids;std::set<int> offsets;
    for(auto& region:regions) {
        auto id=region.at("id").get<std::string>();if(id.empty()||id.size()>128||!ids.insert(id).second)throw std::runtime_error("Invalid grandMA2 region ID");
        auto offset=integer(region.at("offset"),0,9998);if(!offsets.insert(offset).second)throw std::runtime_error("Duplicate grandMA2 destinations");
        for(auto key:{"sequence","executor","timecode"})if(settings.at(key).get<int>()+offset>9999)throw std::runtime_error("grandMA2 destination exceeds 9999");
        auto start=position(region.at("start")),end=position(region.at("end"));if(end<=start)throw std::runtime_error("Invalid grandMA2 region duration");
        auto title=region.at("name").get<std::string>();if(title.size()>512)throw std::runtime_error("Invalid song name");region["name"]=label(title,"Musica");
        selected+=region.at("selected").get<bool>()?1:0;
        auto& cues=region.at("cues");if(!cues.is_array()||cues.empty()||cues.size()>9999||(totalCues+=cues.size())>100000)throw std::runtime_error("Invalid grandMA2 cues");
        double previous=start;
        for(size_t i=0;i<cues.size();++i) {
            auto time=position(cues[i].at("position"));
            if(time<previous||time>=end||(i==0&&std::abs(time-start)>0.000001))throw std::runtime_error("grandMA2 cue outside its song");
            auto title=cues[i].at("name").get<std::string>();if(title.size()>512)throw std::runtime_error("Invalid cue name");cues[i]["name"]=label(title);previous=time;
        }
    }
    if(!selected)throw std::runtime_error("Select at least one song for grandMA2");
    if(selected*regions.size()+totalCues>2000000)throw std::runtime_error("Select fewer songs for this grandMA2 export");
    return plan;
}

void createGrandMA2(const JSON& input,const std::filesystem::path& directory,const std::atomic<bool>& cancelled) {
    auto plan=validateGrandMA2Plan(input);const auto& regions=plan["regions"];const auto& settings=plan["settings"];
    std::vector<std::string> stems,baseNames;std::set<std::string> used,reserved;
    for(const auto& r:regions){baseNames.push_back(stem(r["name"]));reserved.insert(lower(baseNames.back()));}
    for(auto base:baseNames){auto name=base;int count=2;while(used.count(lower(name))||(name!=base&&reserved.count(lower(name))))name=base+"-"+std::to_string(count++);used.insert(lower(name));stems.push_back(name);}
    std::vector<std::pair<std::filesystem::path,std::string>> files;
    std::vector<std::string> allCommands{"SelectDrive 1"};
    std::string csv="Music,Sequence,Page,Executor,Timecode,Slot,Cue,Name,Timecode 30 FPS\r\n";
    for(size_t i=0;i<regions.size();++i) {
        if(cancelled)throw std::runtime_error("Operation cancelled");
        const auto& r=regions[i];if(!r["selected"].get<bool>())continue;
        auto number=[&](const char* key){return std::to_string(settings[key].get<int>()+r["offset"].get<int>());};
        auto seq=number("sequence"),tc=number("timecode"),executor=number("executor"),page=std::to_string(settings["page"].get<int>()),slot=std::to_string(settings["slot"].get<int>());
        std::string name=r["name"];
        std::vector<std::string> commands{"SelectDrive 1","ClearAll"};
        struct Event{int64_t frame;int cue;std::string name;};std::vector<Event> events;int index=1;double end=0;
        for(const auto& c:r["cues"]) {
            auto cue=std::to_string(index),title=c["name"].get<std::string>();auto time=c["position"].get<double>();
            auto prefix="Sequence "+seq+" Cue "+cue;
            commands.push_back("Store "+prefix+" /nc");commands.push_back("Label "+prefix+" \""+title+"\"");
            commands.push_back("Assign "+prefix+" /Trig=Timecode /TrigTime="+trigger(time));
            events.push_back({std::llround(time*30),index++,title});
            const auto frame=std::llround(time*30);std::ostringstream clock;clock<<std::setfill('0')<<std::setw(2)<<frame/108000<<':'<<std::setw(2)<<frame/1800%60<<':'<<std::setw(2)<<frame/30%60<<':'<<std::setw(2)<<frame%30;
            csv+='"'+name+'"'+","+seq+","+page+","+executor+","+tc+","+slot+","+cue+",\""+title+"\","+clock.str()+"\r\n";
        }
        for(auto command:{"Label Sequence "+seq+" \""+name+"\"","Assign Sequence "+seq+" At Executor "+page+"."+executor+" /o",
            "Import \""+stems[i]+"-timecode\" At Timecode "+tc,"Assign Timecode "+tc+" /Slot="+slot,
            "Assign TimecodeSlot "+slot+" /PreRoll=0","Assign TimecodeSlot "+slot+" /AfterRoll=0",
            "Assign Timecode "+tc+" /AutoStart=On","Assign Timecode "+tc+" /StatusCall=On",
            "Assign Timecode "+tc+" /SwitchOff=\"Keep Playbacks\"","Label Timecode "+tc+" \""+name+"\"","Go Timecode "+tc})commands.push_back(command);
        allCommands.insert(allCommands.end(),commands.begin()+1,commands.end());
        files.push_back({std::filesystem::path("macros")/(stems[i]+"-macro.xml"),macro(name,name,commands)});
        for(const auto& other:regions){end=std::max(end,other["end"].get<double>());if(other["id"]!=r["id"])events.push_back({std::llround(other["start"].get<double>()*30),0,{}});}
        std::stable_sort(events.begin(),events.end(),[](auto& a,auto& b){return a.frame==b.frame?a.cue<b.cue:a.frame<b.frame;});
        auto length=std::max(int64_t(std::ceil(end*30)),events.back().frame+30);
        auto out=header(name,"timecode")+"  <Timecode index=\""+std::to_string(std::stoi(tc)-1)+"\" name=\""+xml(name)+"\" slot=\"TC Slot "+slot+"\" frame_format=\"30 FPS\" lenght=\""+std::to_string(length)+"\" offset=\"0\">\r\n"
            "    <Track index=\"0\" active=\"true\" expanded=\"true\">\r\n      <Object name=\"Executor "+page+"."+executor+"\">\r\n        <No>30</No><No>1</No><No>"+page+"</No><No>"+executor+"</No>\r\n      </Object>\r\n      <SubTrack index=\"0\">\r\n";
        for(size_t j=0;j<events.size();++j){const auto& e=events[j];out+="        <Event index=\""+std::to_string(j)+"\" time=\""+std::to_string(e.frame)+"\" command=\"";
            if(e.cue==0)out+="Off\" pressed=\"true\" />\r\n";
            else out+="Goto\" pressed=\"true\" step=\""+std::to_string(e.cue)+"\">\r\n          <Cue name=\""+xml(e.name)+"\"><No>"+page+"</No><No>"+executor+"</No><No>"+std::to_string(e.cue)+"</No></Cue>\r\n        </Event>\r\n";
        }
        out+="      </SubTrack>\r\n      <SubTrack index=\"1\" fader_command=\"Master\"><Event index=\"0\" fader_level=\"1\" /></SubTrack>\r\n    </Track>\r\n  </Timecode>\r\n</MA>\r\n";
        files.push_back({std::filesystem::path("import")/(stems[i]+"-timecode.xml"),out});
    }
    auto installer=stem("00-Importar tudo - "+plan["name"].get<std::string>());int suffix=2;auto unique=installer;
    while(used.count(lower(unique)))unique=installer+"-"+std::to_string(suffix++);
    files.push_back({std::filesystem::path("macros")/(unique+"-macro.xml"),macro(plan["name"],"Importar tudo - "+plan["name"].get<std::string>(),allCommands)});
    files.push_back({"Mapa grandMA2.csv",csv});
    files.push_back({"LEIA-ME.txt","CatLive Integration - grandMA2\r\nCopie as pastas macros e import para o diretorio de importacao do grandMA2.\r\nImporte o macro "+unique+"-macro.xml e execute uma vez.\r\nUse a saida MIDI escolhida no CatLive Integration como entrada no grandMA2, a 30 FPS, TC Slot "+std::to_string(settings["slot"].get<int>())+".\r\n"});
    // Publish a complete new folder only. Existing show files are never replaced.
    if(std::filesystem::exists(directory))throw std::runtime_error("grandMA2 destination already exists");
    auto temporary=directory;temporary+=".partial-"+secureToken().substr(0,12);
    try {
        std::filesystem::create_directories(temporary/"macros");std::filesystem::create_directories(temporary/"import");
        for(const auto& file:files){if(cancelled)throw std::runtime_error("Operation cancelled");write(temporary/file.first,file.second);}
        if(cancelled)throw std::runtime_error("Operation cancelled");
        std::filesystem::rename(temporary,directory);
    } catch(...) {std::error_code ignored;std::filesystem::remove_all(temporary,ignored);throw;}
}
}
