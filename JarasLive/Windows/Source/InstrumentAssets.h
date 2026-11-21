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
inline File installedFile(const String &id,const File &root=library()){
    if(!validID(id)||std::none_of(catalog().begin(),catalog().end(),[&](const var &entry){return str(entry,"id")==id;}))
        throw std::runtime_error("Invalid instrument identity.");
    return root.getChildFile(id+".sf2");
}
inline void uninstall(const String &id,const File &root=library()){
    const auto target=installedFile(id,root);
    // Never resolve through a project's Instruments folder when uninstalling.
    if(target.exists()&&!target.deleteFile())throw std::runtime_error("Could not uninstall the instrument.");
}
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
struct Download {
    std::atomic<bool> cancel{false};
    std::atomic<int> state{0};
    std::atomic<double> progress{0};
    String error, id;
    File target, temp;
    ~Download() {
        if (temp.existsAsFile())
            temp.deleteFile();
    }
};
inline ThreadPool &downloadWorkers() {
    static ThreadPool pool(1);
    return pool;
}
inline std::shared_ptr<Download> startDownload(var item) {
    // Both pickers run on the message thread and may reference the same install.
    static std::map<String, std::weak_ptr<Download>> pending;
    const auto id = str(item, "id");
    if (auto existing = pending[id].lock(); existing && existing->state.load() == 0 && !existing->cancel.load())
        return existing;
    auto current = std::make_shared<Download>();
    current->id = id;
    pending[id] = current;
    current->target = installedFile(current->id);
    current->target.getParentDirectory().createDirectory();
    current->temp =
        current->target.getSiblingFile(current->id + "-" + text(uuid()) + ".download");
    downloadWorkers().addJob([current, item] {
        try {
            const auto path = URL::addEscapeChars(str(item, "folder"), true) + "/" +
                              URL::addEscapeChars(str(item, "name") + ".sf2", true);
            auto stream = std::make_unique<WebInputStream>(
                URL("https://pub-1b271ca25cc347ce82f835a8125d6d93.r2.dev/" + path), false);
            stream->withConnectionTimeout(5000);
            stream->withNumRedirectsToFollow(3);
            if (!stream->connect(nullptr) || stream->getStatusCode() < 200 ||
                stream->getStatusCode() >= 300)
                throw std::runtime_error("Download failed.");
            const auto length = stream->getTotalLength();
            if (length > 512LL * 1024 * 1024)
                throw std::runtime_error("The instrument exceeds 512 MB.");
            {
                FileOutputStream output(current->temp);
                if (!output.openedOk())
                    throw std::runtime_error("Could not save the instrument.");
                std::array<char, 65536> buffer{};
                int64 total = 0;
                while (!stream->isExhausted()) {
                    if (current->cancel.load()) {
                        stream->cancel();
                        throw std::runtime_error("Download cancelled.");
                    }
                    const int count = stream->read(buffer.data(), (int)buffer.size());
                    if (count <= 0)
                        break;
                    total += count;
                    if (total > 512LL * 1024 * 1024 ||
                        !output.write(buffer.data(), (size_t)count))
                        throw std::runtime_error("Could not save the instrument.");
                    current->progress = length > 0 ? total / (double)length : 0;
                }
                output.flush();
                if (output.getStatus().failed() || length >= 0 && total != length ||
                    stream->isError())
                    throw std::runtime_error("Incomplete instrument download.");
            }
            if (!instrumentAssets::validBank(current->temp))
                throw std::runtime_error("The downloaded file is not an SF2 bank.");
            if (!current->temp.moveFileTo(current->target))
                throw std::runtime_error("Could not install the instrument.");
            current->progress = 1;
            current->state.store(1, std::memory_order_release);
        } catch (const std::exception &e) {
            current->error = String::fromUTF8(e.what());
            current->state.store(-1, std::memory_order_release);
        }
    });
    return current;
}
}
