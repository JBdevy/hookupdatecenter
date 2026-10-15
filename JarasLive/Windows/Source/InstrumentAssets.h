#pragma once
#include "Common.h"
#include "ProjectCodec.h"
#include <BinaryData.h>
namespace catlive::instrumentAssets {
inline const Array<var> &catalog(){
    static const auto items=list(JSON::parse(String::fromUTF8(BinaryData::InstrumentCatalog_json,BinaryData::InstrumentCatalog_jsonSize)));
    return items;
}
inline bool validID(const String &id){return id.isNotEmpty()&&id.length()<120&&id.containsOnly("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_");}
inline File library(){return File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/Instruments");}
inline File resolve(const String &id,const File &project){
    if(!validID(id))throw std::runtime_error("Invalid instrument identity.");
    const auto local=project.getChildFile("Instruments/"+id+".sf2");
    return local.existsAsFile()?local:library().getChildFile(id+".sf2");
}
inline String name(const String &id){for(auto item:catalog())if(str(item,"id")==id)return str(item,"name");return id;}
inline std::vector<var> settings(const var &fx,bool includeBypassed=false){
    std::vector<var> result;
    for(auto item:list(get(fx,"inserted"))){
        auto key=item.toString(),kind=key;auto value=fx;
        for(auto instance:list(get(fx,"instances")))if("Native:"+str(instance,"id")==key||"Instance:"+str(instance,"id")==key){kind=str(instance,"kind");value=get(instance,"settings");break;}
        if(kind=="Instruments"&&str(value,"instrumentID").isNotEmpty()&&(includeBypassed||!flag(value,"instrumentBypassed")))result.push_back(value);
    }
    return result;
}
inline std::set<String> identities(const jaras::Project &project){
    std::set<String> result;
    auto collect=[&](const std::optional<std::string> &json){if(json)for(auto s:settings(JSON::parse(text(*json)),true))result.insert(str(s,"instrumentID"));};
    collect(project.masterFXJSON);
    for(const auto &song:project.songs)for(const auto &track:song.tracks){collect(track.fxJSON);for(const auto &clip:track.clips)collect(clip.fxJSON);}
    return result;
}
inline bool validBank(const File &file){
    if(file.getSize()<12||file.getSize()>512LL*1024*1024)return false;FileInputStream stream(file);char header[12]{};
    return stream.read(header,12)==12&&std::memcmp(header,"RIFF",4)==0&&std::memcmp(header+8,"sfbk",4)==0;
}
}
