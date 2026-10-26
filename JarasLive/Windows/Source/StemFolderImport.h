#pragma once
#include "Common.h"
#include "ProjectCodec.h"
#include "ClickTempo.h"
#include <BinaryData.h>
#include <quickjs.h>
namespace catlive::stemImport {
// The runtime has no filesystem/network bindings. Only validated metadata enters it.
class Rules {
    JSRuntime* runtime = JS_NewRuntime();
    JSContext* context = nullptr;
    String evaluate(const String& source) {
        auto value=JS_Eval(context,source.toRawUTF8(),source.getNumBytesAsUTF8(),"stem-import",JS_EVAL_TYPE_GLOBAL);
        if(JS_IsException(value)) {
            auto exception=JS_GetException(context);const char* message=JS_ToCString(context,exception);
            String error=message?String::fromUTF8(message):"Import rules failed";
            if(message)JS_FreeCString(context,message);JS_FreeValue(context,exception);JS_FreeValue(context,value);
            throw std::runtime_error(utf8(error));
        }
        const char* result=JS_ToCString(context,value);String answer=result?String::fromUTF8(result):String();
        if(result)JS_FreeCString(context,result);JS_FreeValue(context,value);return answer;
    }
public:
    Rules() {
        if(!runtime)throw std::runtime_error("Could not initialize import rules.");
        JS_SetMemoryLimit(runtime,64*1024*1024);JS_SetMaxStackSize(runtime,2*1024*1024);
        context=JS_NewContext(runtime);
        if(!context){JS_FreeRuntime(runtime);throw std::runtime_error("Could not initialize import rules.");}
        try {evaluate(String::fromUTF8(BinaryData::HookImportRules_js,BinaryData::HookImportRules_jsSize));}
        catch(...){JS_FreeContext(context);JS_FreeRuntime(runtime);throw;}
    }
    ~Rules(){JS_FreeContext(context);JS_FreeRuntime(runtime);}
    Rules(const Rules&)=delete;
    var call(const String& name,Array<var> args) {
        StringArray values;for(const auto& value:args)values.add(JSON::toString(value,true));
        return JSON::parse(evaluate("JSON.stringify("+name+"("+values.joinIntoString(",")+"))"));
    }
};
struct Source {File file;double duration=0;};
struct Folder {File directory;std::vector<Source> files;};
struct Scan {std::vector<Folder> folders;StringArray warnings;var suggestions;};
inline std::shared_ptr<Scan> scan(const Array<File>& directories) {
    auto result=std::make_shared<Scan>();StringArray seen;Array<var> names;
    for(const auto& directory:directories) {
        if(!directory.isDirectory()||directory.isSymbolicLink()||seen.contains(directory.getFullPathName(),true))continue;
        seen.add(directory.getFullPathName());Folder folder;folder.directory=directory;
        auto files=directory.findChildFiles(File::findFiles|File::ignoreHiddenFiles,false);
        std::sort(files.begin(),files.end(),[](const File&a,const File&b){return a.getFileName().compareNatural(b.getFileName())<0;});
        for(const auto& file:files) {
            if(file.isSymbolicLink()||!file.hasFileExtension("wav;wave;aif;aiff;mp3"))continue;
            // Ordering only needs filenames; opening decoders here delays the first screen.
            folder.files.push_back({file,0});names.add(file.getFileNameWithoutExtension());
        }
        if(folder.files.empty())result->warnings.add(directory.getFileName()+": no WAV, AIFF or MP3 files");
        else {names.add(directory.getFileName());result->folders.push_back(std::move(folder));}
    }
    if(result->folders.empty())throw std::runtime_error("No WAV, AIFF or MP3 files were found in the selected folders.");
    Rules rules;result->suggestions=rules.call("suggestImportRemovals",{var(names)});return result;
}
inline jaras::Project build(const Scan& scan,const String& removal,jaras::Project project,const File& destination,
                           bool detectBPM,const std::function<void(String,double)>& progress,StringArray& warnings,Array<File>* importedFiles=nullptr) {
    for(const auto& file:destination.getParentDirectory().findChildFiles(File::findFiles,false,"*.jl"))
        if(file!=destination&&!ProjectCodec::isMacMetadata(file))throw std::runtime_error("Choose a separate folder for each CatLive project.");
    if(project.songs.empty())throw std::runtime_error("Missing arrangement.");
    Rules rules;Array<var> virtualFolders;std::map<String,Source> sources;
    auto clean=[&](String name,bool directory){
        if(removal.trim().isEmpty())return name;
        auto result=rules.call("removalName",{name,removal,directory});
        if(!result.isObject())return name;
        if((bool)result["invalid"])throw std::runtime_error("Cleaning would produce an invalid name: "+utf8(name));
        return result["name"].toString();
    };
    AudioFormatManager metadataFormats;registerAudioFormats(metadataFormats);
    for(size_t i=0;i<scan.folders.size();++i){const auto& folder=scan.folders[i];
        String path="/"+String((int)i)+"/"+clean(folder.directory.getFileName(),true);Array<var> files;StringArray used;
        for(auto source:folder.files){
            if(source.duration<=0){
                std::unique_ptr<AudioFormatReader> reader(metadataFormats.createReaderFor(source.file));
                if(!reader||reader->sampleRate<=0||reader->lengthInSamples<=0){warnings.add(source.file.getFileName()+": could not read audio");continue;}
                source.duration=reader->lengthInSamples/reader->sampleRate;
            }
            String name=clean(source.file.getFileName(),false);
            if(name.isEmpty()||used.contains(name,true))throw std::runtime_error("Cleaning creates duplicate or empty file names.");
            used.add(name);auto file=object();put(file,"name",name);put(file,"duration",source.duration);put(file,"peakDb",var());files.add(file);sources[path+"/"+name]=source;
        }
        auto entry=object();put(entry,"path",path);put(entry,"files",var(files));virtualFolders.add(entry);
    }
    auto audit=rules.call("analyzeImport",{var(virtualFolders)});
    auto values=[](const var& value){return value.getArray()?*value.getArray():Array<var>{};};
    auto songs=values(audit["songs"]);if(songs.isEmpty())throw std::runtime_error("No songs found.");
    auto& arrangement=project.songs[0];const auto originalCount=arrangement.tracks.size();double offset=0;
    std::set<ID> folders;for(const auto& track:arrangement.tracks)if(track.parentTrackID)folders.insert(*track.parentTrackID);
    for(const auto& track:arrangement.tracks)if(!track.parentTrackID&&track.clips.empty()&&text(track.name).trim().startsWith("#")&&rules.call("groupKeyFromFolderName",{text(track.name)}).toString().isNotEmpty())folders.insert(track.id);
    for(const auto& part:arrangement.parts)offset=std::max(offset,part.endTime);
    for(const auto& track:arrangement.tracks)for(const auto& clip:track.clips)offset=std::max(offset,clip.startTime+clip.duration);
    std::map<String,size_t> keys;Array<var> layout;
    for(size_t i=0;i<originalCount;++i){const auto& track=arrangement.tracks[i];if(!jaras::fixedTrackName(track.role).empty())continue;
        auto entry=object();put(entry,"index",(int)i);put(entry,"name",text(track.name));put(entry,"isFolder",folders.count(track.id)>0);
        var parent;for(size_t j=0;j<originalCount;++j)if(track.parentTrackID==arrangement.tracks[j].id)parent=(int)j;
        put(entry,"parentIndex",parent);layout.add(entry);
        if(!folders.count(track.id)){auto key=rules.call("canonicalExistingTrackKey",{text(track.name)}).toString();keys.emplace(key,i);keys.emplace("custom:"+key,i);}
    }
    for(const auto& channel:values(audit["tracks"])){auto key=channel["key"].toString();if(keys.count(key))continue;
        jaras::Track track;track.id=uuid();track.name=utf8(channel["name"].toString());auto group=channel["groupKey"].toString();
        track.role.id=track.name=="Click"?"click":track.name=="Guia"||track.name==utf8(String::fromUTF8("Regência"))?"guide":group=="sanfonas"?"accordion":text(track.name).startsWith("Baixo")?"bass":group=="teclados"?"keys":group=="percussivo"?"drums":group=="guitarras"?"guitar":"other";
        track.color=0x828282;keys[key]=arrangement.tracks.size();arrangement.tracks.push_back(track);
    }
    Array<File> owned;std::vector<ID> addedRegions;int count=0,total=0;for(const auto& song:songs)total+=values(song["files"]).size();
    auto media=destination.getParentDirectory().getChildFile("Stems");auto status=media.createDirectory();if(status.failed())throw std::runtime_error(utf8(status.getErrorMessage()));
    try {
        AudioFormatManager formats;registerAudioFormats(formats);const unsigned colors[]={0x53be8c,0xddad54,0x7a93dd,0xbf79b8,0x55acbe};int songIndex=0;
        for(const auto& song:songs){jaras::Part part;part.id=uuid();part.name=utf8(song["name"].toString());part.startTime=(double)song["start"]+offset;part.endTime=(double)song["end"]+offset;part.color=colors[songIndex++%5];arrangement.parts.push_back(part);addedRegions.push_back(part.id);
            for(const auto& stem:values(song["files"])){auto found=sources.find(stem["filePath"].toString());if(found==sources.end())throw std::runtime_error("Missing imported audio.");
                auto filename=File::createLegalFileName(stem["fileName"].toString());
                auto extension=filename.fromLastOccurrenceOf(".",true,false);
                auto target=media.getNonexistentChildFile(filename.dropLastCharacters(extension.length()),extension,false);
                if(!found->second.file.copyFileTo(target))throw std::runtime_error("Could not copy audio: "+utf8(target.getFileName()));owned.add(target);
                std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(target));if(!reader)throw std::runtime_error("Could not decode imported audio.");
                jaras::AudioClip clip;clip.id=uuid();clip.name=utf8(stem["fileName"].toString());clip.startTime=part.startTime;clip.duration=found->second.duration;clip.audioFile=jaras::AudioFile{utf8(target.getRelativePathFrom(destination.getParentDirectory()).replaceCharacter('\\','/')),{}};
                const size_t bins=(size_t)std::max(96.,std::min(2048.,clip.duration*8));clip.waveform.assign(bins,0);clip.waveformChannels.assign(reader->numChannels,std::vector<double>(bins,0));
                AudioBuffer<float> buffer((int)reader->numChannels,65536);double peak=0;
                for(int64 at=0;at<reader->lengthInSamples;at+=65536){int frames=(int)std::min<int64>(65536,reader->lengthInSamples-at);
                    if(!reader->read(&buffer,0,frames,at,true,true))throw std::runtime_error("Could not read imported audio.");
                    for(int frame=0;frame<frames;++frame){size_t bin=std::min(bins-1,(size_t)((at+frame)*bins/reader->lengthInSamples));
                        for(int channel=0;channel<buffer.getNumChannels();++channel){double value=std::abs(buffer.getSample(channel,frame));if(!std::isfinite(value))value=0;peak=std::max(peak,value);value=std::min(1.,value);clip.waveform[bin]=std::max(clip.waveform[bin],value);clip.waveformChannels[channel][bin]=std::max(clip.waveformChannels[channel][bin],value);}
                    }
                }
                auto name=stem["trackName"].toString();if((name=="Click"||name.startsWith("Click ")||name==String::fromUTF8("Regência")||name.startsWith(String::fromUTF8("Regência ")))&&peak>0)clip.gain=std::pow(10.,-1./20)/peak;
                auto key=stem["trackKey"].toString();if(!keys.count(key))throw std::runtime_error("Missing imported track.");
                arrangement.duration=std::max(arrangement.duration,clip.startTime+clip.duration);arrangement.tracks[keys.at(key)].clips.push_back(std::move(clip));
                if(progress)progress(stem["fileName"].toString(),double(++count)/total);
            }
            arrangement.duration=std::max(arrangement.duration,part.endTime);
        }
        std::map<ID,ID> anchors;
        for(const auto& group:values(audit["groups"])){std::vector<size_t> members;for(const auto& channel:values(group["tracks"])){auto key=channel["key"].toString();if(keys.count(key)&&keys.at(key)>=originalCount)members.push_back(keys.at(key));}if(members.empty())continue;
            auto target=rules.call("existingImportGroupDestination",{var(layout),group["key"]});auto folder=target["folderIndex"],anchor=target["anchorIndex"];
            unsigned color=(unsigned)group["colorHex"].toString().trimCharactersAtStart("#").getHexValue32();std::optional<ID> parent;
            if(!folder.isVoid()&&!folder.isUndefined()){auto& existing=arrangement.tracks.at((int)folder);parent=existing.id;color=existing.color.value_or(color);}
            else if(!anchor.isVoid()&&!anchor.isUndefined())color=arrangement.tracks.at((int)anchor).color.value_or(color);
            else {jaras::Track root;root.id=uuid();root.name=utf8(group["name"].toString());root.role.id="other";root.color=color;parent=root.id;arrangement.tracks.push_back(root);}
            auto soften=[](unsigned value){return value+(255-value)*28/100;};unsigned soft=(soften((color>>16)&255)<<16)|(soften((color>>8)&255)<<8)|soften(color&255);
            for(auto i:members){auto& track=arrangement.tracks[i];track.color=soft;track.parentTrackID=parent;if(parent)track.patch=jaras::OutputPatch{-2,2};else if(!anchor.isVoid()&&!anchor.isUndefined())anchors[track.id]=arrangement.tracks.at((int)anchor).id;}
        }
        std::vector<jaras::Track> ordered(arrangement.tracks.begin(),arrangement.tracks.begin()+originalCount),additions(arrangement.tracks.begin()+originalCount,arrangement.tracks.end());
        std::vector<jaras::Track> roots;for(const auto& track:additions)if(!track.parentTrackID&&!anchors.count(track.id))roots.push_back(track);
        if(originalCount==0)std::stable_partition(roots.begin(),roots.end(),[&](const auto& track){return rules.call("groupKeyFromFolderName",{text(track.name)}).toString()!="percussivo";});
        ordered.insert(ordered.end(),roots.begin(),roots.end());std::map<ID,ID> last;
        for(const auto& track:additions)if(anchors.count(track.id)){auto anchor=anchors.at(track.id);auto previous=last.count(anchor)?last.at(anchor):anchor;auto at=std::find_if(ordered.begin(),ordered.end(),[&](const auto&t){return t.id==previous;});ordered.insert(at==ordered.end()?at:std::next(at),track);last[anchor]=track.id;}
        std::map<ID,std::optional<ID>> parents;for(const auto& track:arrangement.tracks)parents[track.id]=track.parentTrackID;
        auto belongs=[&](const jaras::Track& track,const ID& parent){auto p=track.parentTrackID;std::set<ID> visited;while(p&&visited.insert(*p).second){if(*p==parent)return true;p=parents[*p];}return false;};
        for(const auto& track:additions)if(track.parentTrackID){auto at=std::find_if(ordered.begin(),ordered.end(),[&](const auto&t){return t.id==*track.parentTrackID;});if(at!=ordered.end()){++at;while(at!=ordered.end()&&belongs(*at,*track.parentTrackID))++at;}ordered.insert(at,track);}
        arrangement.tracks=std::move(ordered);
        if(detectBPM)for(const auto& id:addedRegions){auto part=std::find_if(arrangement.parts.begin(),arrangement.parts.end(),[&](const auto&p){return p.id==id;});
            if(progress)progress("Detecting BPM: "+text(part->name),1);
            auto markers=clickTempo::markers(arrangement,*part,[&](const jaras::AudioFile& file){return clickTempo::transients(destination.getParentDirectory().getChildFile(text(file.path)));});
            if(markers.empty())warnings.add(text(part->name)+": no valid Click found for BPM detection");else clickTempo::insert(arrangement,*part,markers);
        }
        project.updatedAt=utf8(Time::getCurrentTime().toISO8601(true));
        jaras::validate(project);if(importedFiles)*importedFiles=owned;return project;
    }catch(...){for(const auto& file:owned)file.deleteFile();throw;}
}
}
