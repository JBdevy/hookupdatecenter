#pragma once
#include "StoredProjectZIP.h"
#include "VinhetasAudio.h"

namespace catlive::vinhetasPackage {
using packageZIP::require;
inline void validate(const var &library) {
    require(library.isObject() && list(get(library,"presets")).size()==6 &&
            list(get(library,"padMappings")).size()==16 && list(get(library,"presetMappings")).size()==6,
            "Invalid pad library.");
    require(num(library,"selectedPreset")>=0 && num(library,"selectedPreset")<6);
    const auto channel=get(library,"midiChannel");
    require(channel.isVoid()||(num(library,"midiChannel")>=1&&num(library,"midiChannel")<=16));
    for(const auto &bank:list(get(library,"presets"))){
        require(bank.isObject()&&get(bank,"name").isString()&&list(get(bank,"pads")).size()==16);
        for(const auto &pad:list(get(bank,"pads")))require(pad.isObject()&&get(pad,"name").isString()&&
            std::isfinite(num(pad,"volume"))&&num(pad,"volume")>=0&&num(pad,"volume")<=4);
    }
}
inline var portable(var value) {
    value=value.clone();if(num(value,"midiChannel")==0)value.getDynamicObject()->removeProperty("midiChannel");
    for(const auto key:{"padMappings","presetMappings"})for(auto mapping:list(get(value,key)))if(mapping.isObject()){
        put(mapping,"kind","midi");put(mapping,"label","MIDI");put(mapping,"channel",jlimit(0,15,(int)num(mapping,"channel")-1));
    }
    for(auto bank:list(get(value,"presets")))for(auto pad:list(get(bank,"pads")))if(str(pad,"audioFile").isEmpty())pad.getDynamicObject()->removeProperty("audioFile");
    return value;
}
inline var windows(var value) {
    value=value.clone();if(get(value,"midiChannel").isVoid())put(value,"midiChannel",0);
    for(const auto key:{"padMappings","presetMappings"})for(auto mapping:list(get(value,key)))if(mapping.isObject())put(mapping,"channel",jlimit(0,15,(int)num(mapping,"channel"))+1);
    return value;
}
inline void exportFile(const var &state,const File &media,const File &archive) {
    auto library=portable(state);validate(library);require(archive.hasFileExtension("zipfx"));
    std::map<String,File> sources;std::map<String,String> names;std::vector<packageZIP::Record> records;
    uint64 total=0;
    for(auto bank:list(get(library,"presets")))for(auto pad:list(get(bank,"pads"))){
        const auto name=str(pad,"audioFile");if(name.isEmpty())continue;
        const auto source=File::isAbsolutePath(name)?File(name):media.getChildFile(name);
        require(source.existsAsFile()&&!source.isSymbolicLink()&&source.hasFileExtension("wav;wave;aif;aiff;mp3"),"A pad audio file is missing.");
        auto &entry=names[source.getFullPathName()];if(entry.isEmpty()){
            entry="Audio/"+Uuid().toString()+source.getFileExtension().toLowerCase();
            records.push_back(packageZIP::fingerprint(entry,source));sources[entry]=source;total+=records.back().bytes;
        }
        put(pad,"audioFile",entry);
    }
    require(total<=8ULL*1024*1024*1024,"The pad library exceeds 8 GB.");
    auto manifest=object();put(manifest,"format","catlive-zipfx");put(manifest,"version",1);put(manifest,"library",library);
    Array<var> inventory;for(const auto &r:records){auto record=object();put(record,"path",r.path);put(record,"bytes",(int64)r.bytes);put(record,"sha256",r.sha256);inventory.add(record);}put(manifest,"files",inventory);
    TemporaryFile temporary(archive);
    {packageZIP::Writer zip(temporary.getFile());const auto json=JSON::toString(manifest);require(json.getNumBytesAsUTF8()<=2*1024*1024);zip.add("manifest.json",MemoryBlock(json.toRawUTF8(),json.getNumBytesAsUTF8()));
     for(const auto &record:records){FileInputStream input(sources[record.path]);require(!input.failedToOpen());zip.add(record,input);}zip.finish();}
    require(temporary.overwriteTargetFileWithTemporary(),"Cannot save .zipfx package.");
}
inline var prepareImport(const File &archive,const File &staging) {
    require(archive.hasFileExtension("zipfx")&&archive.existsAsFile()&&!archive.isSymbolicLink());
    packageZIP::Reader zip(archive);require(zip.entries.size()<=97&&zip.totalBytes<=8ULL*1024*1024*1024);
    const auto data=zip.data("manifest.json",2*1024*1024);const auto manifest=JSON::parse(String::fromUTF8((const char*)data.getData(),(int)data.getSize()));
    require(str(manifest,"format")=="catlive-zipfx"&&num(manifest,"version")==1,"Unsupported pad package.");
    auto library=get(manifest,"library").clone();validate(library);
    std::set<String> refs;for(const auto &bank:list(get(library,"presets")))for(const auto &pad:list(get(bank,"pads")))if(str(pad,"audioFile").isNotEmpty())refs.insert(str(pad,"audioFile"));
    std::map<String,packageZIP::Record> records;
    for(const auto &entry:list(get(manifest,"files"))){
        const auto path=str(entry,"path");packageZIP::validatePath(path);
        const auto pieces=StringArray::fromTokens(path,"/","");require(pieces.size()==2&&pieces[0]=="Audio"&&staging.getChildFile(pieces[1]).hasFileExtension("wav;wave;aif;aiff;mp3"));
        require(refs.count(path)&&!records.count(path)&&zip.entries.count(path)&&num(entry,"bytes")>=0);
        packageZIP::Record record{path,str(entry,"sha256"),(uint64)num(entry,"bytes")};require(record.bytes==zip.entries.at(path).size);records[path]=record;
    }
    require(records.size()==refs.size()&&zip.entries.size()==refs.size()+1,"Incomplete pad package.");
    require(!staging.exists()&&staging.createDirectory().wasOk());
    std::map<String,String> mapped;
    try{
        for(const auto &[path,record]:records){const auto name=Uuid().toString()+staging.getChildFile(path).getFileExtension().toLowerCase();const auto target=staging.getChildFile(name);
            zip.extract(record,target);const auto error=VinhetasAudio::importError(target);require(error.isEmpty(),error.toRawUTF8());mapped[path]=name;}
        for(auto bank:list(get(library,"presets")))for(auto pad:list(get(bank,"pads")))if(str(pad,"audioFile").isNotEmpty())put(pad,"audioFile",mapped.at(str(pad,"audioFile")));
    }catch(...){staging.deleteRecursively();throw;}
    return windows(library);
}
}
