#pragma once
#include "Common.h"
#include "ProjectCodec.h"
#include "ClickTempo.h"
#include "JLLyrics.h"
#include "MediaSource.h"
#include "MultitrackRegionData.h"
#include "TrackTree.h"
#include <BinaryData.h>
#include <iterator>
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
        // JUCE's JSON::parse accepts objects/arrays, not a top-level string.
        // Wrap every result so canonical names survive the JS/native boundary.
        var result;
        const auto parsed=JSON::parse(evaluate("JSON.stringify(["+name+"("+values.joinIntoString(",")+")])"),result);
        if(parsed.failed()||!result.isArray()||result.size()!=1)
            throw std::runtime_error("Could not read import rule result: "+utf8(name));
        return result[0];
    }
};
struct Source {
    File file;
    double duration = 0;
    std::optional<jlLyrics::Document> lyrics;
    std::optional<int> videoTrack;
};
inline int videoTeleprompter(const File &file) {
    auto name = file.getFileNameWithoutExtension().toLowerCase().trim();
    if (!name.startsWith("teleprompter")) return 0;
    name = name.substring(12).trimCharactersAtStart(" _-");
    if (name.isEmpty() || (name[0] != '1' && name[0] != '2') || (name.length() > 1 && CharacterFunctions::isDigit(name[1]))) return 0;
    return name[0] - '0';
}
inline constexpr auto movieExtensions = "mp4;mov;m4v;avi;mkv;webm;mpg;mpeg;wmv;ts";

struct Folder {
    File directory;
    std::vector<Source> files;
    std::optional<multitrackData::Document> regionData;
    std::shared_ptr<const multitrackData::Drawer> drawer;
};
struct Scan {std::vector<Folder> folders;StringArray warnings;var suggestions;};
inline std::shared_ptr<Scan> scan(const Array<File>& directories) {
    auto result=std::make_shared<Scan>();StringArray seen;Array<var> names;
    Array<File> candidates;
    for (const auto &directory : directories) {
        if (!directory.isDirectory() || directory.isSymbolicLink()) continue;
        const auto own = directory.findChildFiles(File::findFiles, false, ".jldata-*");
        auto children = directory.findChildFiles(File::findDirectories | File::ignoreHiddenFiles, false);
        std::sort(children.begin(), children.end(), [](const File& a, const File& b) { return a.getFileName().compareNatural(b.getFileName()) < 0; });
        bool expanded = false;
        if (own.isEmpty()) for (const auto &child : children)
            if (!child.isSymbolicLink() && !child.findChildFiles(File::findFiles, false, ".jldata-*").isEmpty()) {
                candidates.add(child);
                expanded = true;
            }
        if (!expanded) candidates.add(directory);
    }
    std::vector<Folder> scanned;
    for (const auto &directory : candidates) {
        if (!directory.isDirectory() || directory.isSymbolicLink()) continue;
        const auto manifests = directory.findChildFiles(File::findFiles, false, ".jldata-*");
        if (manifests.size() > 1) throw std::runtime_error("Multiple Multitrack manifests in " + utf8(directory.getFileName()));
        if (manifests.isEmpty()) { scanned.push_back({directory, {}, {}, {}}); continue; }
        const auto raw = multitrackData::manifestJSON(manifests.getFirst());
        if (num(raw, "version") != 2) {
            scanned.push_back({directory, {}, multitrackData::decode(raw), {}});
            continue;
        }
        auto drawer = std::make_shared<const multitrackData::Drawer>(multitrackData::decodeDrawer(raw));
        for (const auto &entry : drawer->entries) {
            const auto child = directory.getChildFile(entry.folder);
            if (!child.isDirectory() || child.isSymbolicLink()) throw std::runtime_error("Missing Multitrack song folder.");
            scanned.push_back({child, {}, entry.data, drawer});
        }
    }
    for (auto &folder : scanned) {
        const auto &directory = folder.directory;
        if (seen.contains(directory.getFullPathName(), true)) continue;
        seen.add(directory.getFullPathName());
        auto files=directory.findChildFiles(File::findFiles|File::ignoreHiddenFiles,false);
        std::sort(files.begin(),files.end(),[](const File&a,const File&b){return a.getFileName().compareNatural(b.getFileName())<0;});
        for(const auto& file:files) {
            if (file.isSymbolicLink()) continue;
            if (file.hasFileExtension("jllyrics") || (!folder.regionData && file.hasFileExtension(movieExtensions))) {
                folder.files.push_back({file, 0});
                continue;
            }
            if (!file.hasFileExtension("wav;wave;aif;aiff;mp3")) continue;
            // Ordering only needs filenames; opening decoders here delays the first screen.
            folder.files.push_back({file,0});names.add(file.getFileNameWithoutExtension());
        }
        if(folder.files.empty() && !folder.regionData)result->warnings.add(directory.getFileName()+": no supported media");
        else {names.add(directory.getFileName());result->folders.push_back(std::move(folder));}
    }
    if(result->folders.empty())throw std::runtime_error("No supported media was found in the selected folders.");
    Rules rules;result->suggestions=rules.call("suggestImportRemovals",{var(names)});return result;
}
inline bool prepareOverview(AudioFormatReader &reader, jaras::AudioClip &clip, double &peak) {
    if (reader.numChannels == 0 || reader.lengthInSamples <= 0) return false;
    const size_t bins = static_cast<size_t>(std::max(96., std::min(2048., clip.duration * 8)));
    clip.waveform.assign(bins, 0);
    clip.waveformChannels.assign(reader.numChannels, std::vector<double>(bins, 0));
    AudioBuffer<float> buffer(int(reader.numChannels), 65536);
    for (int64 at = 0; at < reader.lengthInSamples; at += 65536) {
        const int frames = static_cast<int>(std::min<int64>(65536, reader.lengthInSamples - at));
        if (!reader.read(&buffer, 0, frames, at, true, true)) return false;
        for (int frame = 0; frame < frames; ++frame) {
            const auto bin = std::min(bins - 1, static_cast<size_t>((at + frame) * bins / reader.lengthInSamples));
            for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
                const double amplitude = std::abs(buffer.getSample(channel, frame));
                if (!std::isfinite(amplitude)) continue;
                peak = std::max(peak, amplitude);
                clip.waveform[bin] = std::max(clip.waveform[bin], std::min(1., amplitude));
                auto &value = clip.waveformChannels[size_t(channel)][bin];
                value = std::max(value, std::min(1., amplitude));
            }
        }
    }
    return true;
}
inline void restoreMultitrack(const Folder &folder, jaras::Song &arrangement, jaras::Part &region,
                              const File &projectDirectory, const std::vector<Source> &supplemental, const std::map<ID, ID> *drawerMarkerIDs,
                              const std::map<ID, std::set<ID>> &renderedTracks, Array<File> &owned,
                              const std::function<void(String,double)> &progress) {
    const auto &data = *folder.regionData;
    const auto &snapshot = data.arrangement();
    const auto &original = data.region();
    const auto origin = region.startTime;
    const auto regionID = region.id;
    std::set<std::string> lyricsRoles;
    for (const auto &source : supplemental)
        if (source.lyrics) lyricsRoles.insert(source.lyrics->teleprompter == 2 ? "teleprompt2" : "teleprompt");

    std::map<ID, ID> targets, markers;
    for (const auto &track : snapshot.tracks) {
        const auto existing = std::find_if(arrangement.tracks.begin(), arrangement.tracks.end(), [&](const auto &candidate) {
            return candidate.id == track.id || (!jaras::fixedTrackName(track.role).empty() && candidate.role.id == track.role.id);
        });
        targets[track.id] = existing == arrangement.tracks.end() ? track.id : existing->id;
    }
    if (!arrangement.markers) arrangement.markers.emplace();
    if (drawerMarkerIDs) markers = *drawerMarkerIDs;
    else if (snapshot.markers) for (const auto &marker : *snapshot.markers) markers.emplace(marker.id, uuid());
    if (snapshot.markers) for (auto marker : *snapshot.markers) {
        marker.id = markers.at(marker.id); marker.position += origin; marker.regionOwnerID = regionID;
        if (marker.automaticSectionTargetID) {
            const auto target = markers.find(*marker.automaticSectionTargetID);
            marker.automaticSectionTargetID = target == markers.end() ? std::nullopt : std::optional<ID>(target->second);
            if (!marker.automaticSectionTargetID) marker.automaticSectionRepeatCount.reset();
        }
        arrangement.markers->push_back(std::move(marker));
    }
    region = original;
    region.id = regionID; region.startTime += origin; region.endTime += origin;
    const bool explicitPitch = original.pitchTrackIDs || original.pitchGroupIDs;
    if (!data.tunerUnbaked || explicitPitch) {
        region.pitchTrackIDs.emplace();
        region.pitchGroupIDs = std::vector<ID>{};
    } else {
        region.pitchTrackIDs.reset(); region.pitchGroupIDs.reset();
    }
    std::set<ID> restoredPitchTracks;
    if (data.tunerUnbaked && explicitPitch) for (const auto &track : snapshot.tracks) {
        if (const auto found = renderedTracks.find(track.id); found != renderedTracks.end() &&
            regionPitch::selected(snapshot, track, original))
            restoredPitchTracks.insert(found->second.begin(), found->second.end());
    }
    std::map<String, String> copiedMedia;
    std::map<ID, std::vector<jaras::AudioClip>> rawClips;
    std::set<ID> rawTracks;
    size_t count = 0, total = 0;
    for (const auto &track : snapshot.tracks) total += track.clips.size();
    for (const auto &track : snapshot.tracks) {
        for (auto item : track.clips) {
            ++count;
            if (progress) progress(text(item.name), double(count) / std::max<size_t>(1, total));
            if (!item.audioFile && lyricsRoles.count(track.role.id)) continue;
            if (item.audioFile) {
                const auto filename = text(item.audioFile->path).substring(7);
                auto destination = copiedMedia.find(filename);
                if (destination == copiedMedia.end()) {
                    const auto source = folder.directory.getChildFile(filename);
                    if (!source.existsAsFile() || source.isSymbolicLink()) continue;
                    const auto container = projectDirectory.getChildFile("Videos");
                    if (container.createDirectory().failed()) throw std::runtime_error("Could not create the Videos folder.");
                    const auto file = container.getNonexistentChildFile(source.getFileNameWithoutExtension(), source.getFileExtension(), false);
                    if (!source.copyFileTo(file)) throw std::runtime_error("Could not copy Multitrack media: " + utf8(filename));
                    owned.add(file);
                    destination = copiedMedia.emplace(filename, "Videos/" + file.getFileName()).first;
                }
                item.audioFile = jaras::AudioFile{utf8(destination->second), {}};
            }
            item.id = uuid(); item.startTime += origin; item.regionOwnerID = regionID;
            item.tempoRateReferences.erase(std::remove_if(item.tempoRateReferences.begin(), item.tempoRateReferences.end(),
                [&](auto &reference) {
                    const auto at = markers.find(reference.markerID);
                    if (at == markers.end()) return true;
                    reference.markerID = at->second;
                    return false;
                }), item.tempoRateReferences.end());
            rawClips[track.id].push_back(std::move(item));
        }
        if (rawClips.count(track.id) || !track.programChanges.empty() || lyricsRoles.count(track.role.id))
            rawTracks.insert(track.id);
    }
    for (auto track : snapshot.tracks) {
        const auto sourceID = track.id;
        if (!rawTracks.count(sourceID)) continue;
        const bool pitchTarget = region.pitchTrackIDs && rawClips.count(sourceID) &&
            regionPitch::selected(snapshot, track, original);
        track.id = targets.at(sourceID);
        if (pitchTarget) restoredPitchTracks.insert(track.id);
        track.clips = std::move(rawClips[sourceID]);
        for (auto &marker : track.programChanges) {
            marker.id = uuid();
            marker.position += origin;
        }
        const auto index = trackTree::index(arrangement, track.id);
        if (index < arrangement.tracks.size()) {
            auto &existing = arrangement.tracks[index];
            existing.clips.insert(existing.clips.end(), std::make_move_iterator(track.clips.begin()), std::make_move_iterator(track.clips.end()));
            existing.programChanges.insert(existing.programChanges.end(), track.programChanges.begin(), track.programChanges.end());
            continue;
        }
        auto outputs = track.outputPatches();
        const auto group = [](const auto &patch) { return patch.firstChannel == -2; };
        if (std::any_of(outputs.begin(), outputs.end(), group)) {
            outputs.erase(std::remove_if(outputs.begin(), outputs.end(), group), outputs.end());
            if (outputs.empty()) outputs.push_back({0, 2});
            track.outputs = std::move(outputs); track.patch.reset(); track.secondaryPatch.reset();
        }
        track.parentTrackID.reset(); track.audioFile.reset(); track.clickSound.reset();
        track.stereoLinkPartner.reset(); track.stereoLinkLeft = false; track.stereoLinkJSON.reset();
        if (track.routing) for (auto *routes : {&track.routing->receives, &track.routing->transmitters})
            for (auto &route : *routes) if (route)
                route = rawTracks.count(*route) ? std::optional<ID>(targets.at(*route)) : std::nullopt;
        jaras::automationTiming::map(track.automationJSON, [&](double time) { return origin + time; });
        auto at = arrangement.tracks.end();
        if (!jaras::fixedTrackName(track.role).empty()) {
            at = std::find_if(arrangement.tracks.begin(), arrangement.tracks.end(),
                [](const auto& item) { return jaras::fixedTrackName(item.role).empty(); });
        }
        arrangement.tracks.insert(at, std::move(track));
    }
    if (region.pitchTrackIDs)
        for (const auto &track : arrangement.tracks)
            if (restoredPitchTracks.count(track.id)) region.pitchTrackIDs->push_back(track.id);
    for (const auto &source : supplemental)
        if (source.lyrics) jlLyrics::insert(arrangement, *source.lyrics, region.startTime, regionID);
    arrangement.duration = std::max(arrangement.duration, origin + snapshot.duration);
}
inline jaras::Project build(const Scan& scan,const String& removal,jaras::Project project,const File& destination,
                           bool detectBPM,const std::function<void(String,double)>& progress,StringArray& warnings,Array<File>* importedFiles=nullptr) {
    for(const auto& file:destination.getParentDirectory().findChildFiles(File::findFiles,false,"*.jl"))
        if(file!=destination&&!ProjectCodec::isMacMetadata(file))throw std::runtime_error("Choose a separate folder for each CatLive project.");
    if(project.songs.empty())throw std::runtime_error("Missing arrangement.");
    Rules rules;Array<var> virtualFolders;std::map<String,std::vector<Source>> sources;
    std::map<String,std::vector<Source>> supplemental;
    std::map<String,const Folder*> multitracks;
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
        if (folder.regionData) multitracks.emplace(path, &folder);
        double audioEnd = 0, supplementalEnd = folder.regionData ? folder.regionData->arrangement().duration : 0;
        std::array<double, 3> videoDuration{};
        std::map<String, const multitrackData::RenderedStem *> renderedByName;
        std::map<ID, String> separatedTracks, trackNames;
        if (folder.regionData) {
            for (const auto &stem : folder.regionData->stems) renderedByName.emplace(stem.file, &stem);
            if (folder.drawer)
                for (const auto &track : folder.regionData->arrangement().tracks) trackNames.emplace(track.id, text(track.name));
        }
        for(auto source:folder.files){
            if (source.file.hasFileExtension("jllyrics")) {
                try {
                    source.lyrics = jlLyrics::read(source.file);
                    const auto &items = source.lyrics->items;
                    const double start = folder.regionData ? folder.regionData->region().startTime : 0;
                    if (std::any_of(items.begin(), items.end(), [&](const auto &clip) { return start + clip.startTime < 0; })) continue;
                    supplementalEnd = std::max(supplementalEnd, start + source.lyrics->end());
                    supplemental[path].push_back(std::move(source));
                } catch (const std::exception &) {}
                continue;
            }
            if (source.file.hasFileExtension(movieExtensions)) {
                const auto info = inspectMediaSource(source.file);
                if (!info.video || !std::isfinite(info.duration) || info.duration <= 0) continue;
                source.videoTrack = videoTeleprompter(source.file);
                source.duration = info.duration;
                auto &length = videoDuration[static_cast<size_t>(*source.videoTrack)];
                length += source.duration;
                supplementalEnd = std::max(supplementalEnd, length);
                supplemental[path].push_back(std::move(source));
                continue;
            }
            if(source.duration<=0){
                std::unique_ptr<AudioFormatReader> reader(metadataFormats.createReaderFor(source.file));
                if(!reader||reader->sampleRate<=0||reader->lengthInSamples<=0)continue;
                source.duration=reader->lengthInSamples/reader->sampleRate;
            }
            audioEnd = std::max(audioEnd, source.duration);
            const auto separated = renderedByName.find(source.file.getFileName());
            String name;
            if (separated != renderedByName.end()) {
                const auto &id = separated->second->track;
                if (const auto shared = separatedTracks.find(id); shared != separatedTracks.end()) {
                    sources[path + "/" + shared->second].push_back(source);
                    continue;
                }
                const auto candidate = clean(folder.drawer ? trackNames.at(id).replaceCharacter('/', '_') + ".wav"
                    : source.file.getFileName(), false);
                const auto ext = candidate.fromLastOccurrenceOf(".", true, false);
                name = candidate;
                for (int ordinal = 2; used.contains(name, true); ++ordinal)
                    name = candidate.dropLastCharacters(ext.length()) + " " + String(ordinal) + ext;
                separatedTracks.emplace(id, name);
            } else {
                name = clean(source.file.getFileName(), false);
            }
            if (name.isEmpty() || used.contains(name, true)) throw std::runtime_error("Cleaning creates duplicate or empty file names.");
            used.add(name);
            auto file = object();
            put(file, "name", name); put(file, "duration", source.duration); put(file, "peakDb", var()); files.add(file);
            sources[path + "/" + name].push_back(source);
        }
        if (supplementalEnd > audioEnd) {
            auto timing = object();
            put(timing, "name", text(uuid()) + ".wav");
            put(timing, "duration", supplementalEnd);
            put(timing, "peakDb", var());
            files.add(timing);
        }
        auto entry=object();put(entry,"path",path);put(entry,"files",var(files));virtualFolders.add(entry);
    }
    auto values=[](const var& value){return value.getArray()?*value.getArray():Array<var>{};};
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
        if(!folders.count(track.id)){keys["existing:"+String((int)i)]=i;auto key=rules.call("canonicalExistingTrackKey",{text(track.name)}).toString();keys.emplace(key,i);keys.emplace("custom:"+key,i);}
    }
    auto audit=rules.call("analyzeImport",{var(virtualFolders),var(layout)});
    auto songs=values(audit["songs"]);if(songs.isEmpty())throw std::runtime_error("No songs found.");
    std::set<String> audioKeys;
    for (const auto &song : songs) for (const auto &stem : values(song["files"]))
        if (sources.count(stem["filePath"].toString())) audioKeys.insert(stem["trackKey"].toString());
    for(const auto& channel:values(audit["tracks"])){auto key=channel["key"].toString();if(keys.count(key) || !audioKeys.count(key))continue;
        jaras::Track track;track.id=uuid();track.name=utf8(channel["name"].toString());auto group=channel["groupKey"].toString();
        track.role.id=track.name=="Click"?"click":track.name=="Guia"||track.name==utf8(String::fromUTF8("Regência"))?"guide":group=="sanfonas"?"accordion":text(track.name).startsWith("Baixo")?"bass":group=="teclados"?"keys":group=="percussivo"?"drums":group=="guitarras"?"guitar":"other";
        track.color=0x828282;keys[key]=arrangement.tracks.size();arrangement.tracks.push_back(track);
    }
    Array<File> owned;
    std::vector<ID> addedRegions;
    std::map<const multitrackData::Drawer *, std::pair<ID, double>> drawerPlacements;
    struct DrawerChild {
        ID parent;
        double cue;
        const multitrackData::Drawer::Entry *entry;
    };
    std::map<ID, DrawerChild> drawerChildren;
    std::map<ID, std::map<ID, ID>> drawerMarkerIDs;
    std::map<ID, std::map<ID, std::set<ID>>> renderedTracks;
    int count = 0, total = 0;
    for (const auto &[path, clips] : sources) total += (int)clips.size();
    auto media=destination.getParentDirectory().getChildFile("Stems");auto status=media.createDirectory();if(status.failed())throw std::runtime_error(utf8(status.getErrorMessage()));
    try {
        AudioFormatManager formats;registerAudioFormats(formats);const unsigned colors[]={0x53be8c,0xddad54,0x7a93dd,0xbf79b8,0x55acbe};int songIndex=0;
        double previousAuditEnd = 0, occupiedEnd = offset;
        for (const auto &song : songs) {
            const double start = song["start"], end = song["end"];
            const double gap = std::max(0., start - previousAuditEnd);
            previousAuditEnd = end;
            double origin = occupiedEnd + gap;
            const auto exported = multitracks.find(song["folderPath"].toString());
            const auto *folder = exported == multitracks.end() ? nullptr : exported->second;
            const auto *metadata = folder ? &*folder->regionData : nullptr;
            jaras::Part part;
            part.id = uuid(); part.name = utf8(song["name"].toString()); part.color = colors[songIndex++ % 5];
            if (folder && folder->drawer) {
                const auto &drawer = *folder->drawer;
                const auto child = std::find_if(drawer.entries.begin(), drawer.entries.end(), [&](const auto &entry) {
                    return entry.folder == folder->directory.getFileName();
                });
                if (child == drawer.entries.end()) throw std::runtime_error("Invalid Multitrack song folder.");
                auto placement = drawerPlacements.find(&drawer);
                if (placement == drawerPlacements.end()) {
                    jaras::Part root;
                    root.id = uuid(); root.name = utf8(drawer.name); root.startTime = origin - drawer.leadingOffset();
                    root.endTime = root.startTime + drawer.duration; root.color = drawer.color;
                    root.uppercaseName = drawer.uppercaseName; root.pitchSemitones = drawer.pitchSemitones;
                    placement = drawerPlacements.emplace(&drawer, std::make_pair(root.id, root.startTime)).first;
                    arrangement.parts.push_back(root);
                    auto &markers = drawerMarkerIDs[root.id];
                    for (const auto &entry : drawer.entries) {
                        if (entry.cueID) markers.emplace(*entry.cueID, uuid());
                        if (entry.data.arrangement().markers)
                            for (const auto &marker : *entry.data.arrangement().markers) markers.emplace(marker.id, uuid());
                    }
                    occupiedEnd = root.startTime + drawer.occupiedEnd();
                    arrangement.duration = std::max(arrangement.duration, occupiedEnd);
                }
                origin = placement->second.second + child->offset - child->data.region().startTime;
                drawerChildren.emplace(part.id, DrawerChild{placement->second.first, placement->second.second + child->cue, &*child});
            } else {
                occupiedEnd = origin + end - start;
            }
            part.startTime = origin; part.endTime = origin + end - start;
            arrangement.parts.push_back(part); addedRegions.push_back(part.id);
            std::map<String, const multitrackData::RenderedStem *> renderedFiles;
            if (metadata) for (const auto &stem : metadata->stems) renderedFiles.emplace(stem.file, &stem);
            for (const auto &stem : values(song["files"])) {
                const auto found = sources.find(stem["filePath"].toString());
                if (found == sources.end()) continue;
                for (const auto &source : found->second) {
                    const auto rendered = renderedFiles.find(source.file.getFileName());
                    const auto displayName = rendered != renderedFiles.end() ? source.file.getFileName() : stem["fileName"].toString();
                    const auto filename = File::createLegalFileName(displayName);
                    const auto extension = filename.fromLastOccurrenceOf(".", true, false);
                    const auto target = media.getNonexistentChildFile(filename.dropLastCharacters(extension.length()), extension, false);
                    if (!source.file.copyFileTo(target)) throw std::runtime_error("Could not copy audio: " + utf8(filename));
                    owned.add(target);
                    std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(target));
                    jaras::AudioClip clip;
                    clip.id = uuid(); clip.name = utf8(displayName); clip.startTime = part.startTime; clip.duration = source.duration;
                    clip.audioFile = jaras::AudioFile{utf8(target.getRelativePathFrom(destination.getParentDirectory()).replaceCharacter('\\', '/')), {}};
                    if (metadata) clip.startTime += metadata->region().startTime;
                    if (rendered != renderedFiles.end()) {
                        clip.renderedTempo = true; clip.regionOwnerID = part.id;
                        const auto &items = rendered->second->items;
                        if (items.size() == 1) {
                            if (folder->drawer) { clip.startTime += items.front().offset; clip.duration = items.front().duration; }
                            if (metadata->tunerUnbaked) clip.pitchSemitones = items.front().pitchSemitones;
                        }
                    }
                    double peak = 0;
                    if (!reader || !prepareOverview(*reader, clip, peak)) {
                        reader.reset(); target.deleteFile(); owned.removeFirstMatchingValue(target);
                    } else {
                        const auto name = stem["trackName"].toString();
                        if ((name == "Click" || name.startsWith("Click ") || name == String::fromUTF8("Regência") ||
                             name.startsWith(String::fromUTF8("Regência "))) && peak > 0) clip.gain = std::pow(10., -1./20) / peak;
                        const auto key = stem["trackKey"].toString();
                        if (!keys.count(key)) throw std::runtime_error("Missing imported track.");
                        arrangement.duration = std::max(arrangement.duration, clip.startTime + clip.duration);
                        auto &destinationTrack = arrangement.tracks[keys.at(key)];
                        if (rendered != renderedFiles.end())
                            renderedTracks[part.id][rendered->second->track].insert(destinationTrack.id);
                        destinationTrack.clips.push_back(std::move(clip));
                    }
                    if (progress) progress(displayName, double(++count) / total);
                }
            }
            arrangement.duration = std::max(arrangement.duration, part.endTime);
        }
        std::map<ID,ID> anchors;
        for(const auto& group:values(audit["groups"])){std::vector<size_t> members;for(const auto& channel:values(group["tracks"])){auto key=channel["key"].toString();if(keys.count(key)&&keys.at(key)>=originalCount&&!arrangement.tracks[keys.at(key)].clips.empty())members.push_back(keys.at(key));}if(members.empty())continue;
            auto target=rules.call("existingImportGroupDestination",{var(layout),group["key"]});auto folder=target["folderIndex"],anchor=target["anchorIndex"];
            unsigned color=(unsigned)group["colorHex"].toString().trimCharactersAtStart("#").getHexValue32();std::optional<ID> parent;
            if(!folder.isVoid()&&!folder.isUndefined()){auto& existing=arrangement.tracks.at((int)folder);parent=existing.id;color=existing.color.value_or(color);}
            else if(!anchor.isVoid()&&!anchor.isUndefined())color=arrangement.tracks.at((int)anchor).color.value_or(color);
            else {jaras::Track root;root.id=uuid();root.name=utf8(group["name"].toString());root.role.id="other";root.color=color;parent=root.id;arrangement.tracks.push_back(root);}
            auto soften=[](unsigned value){return value+(255-value)*28/100;};unsigned soft=(soften((color>>16)&255)<<16)|(soften((color>>8)&255)<<8)|soften(color&255);
            for(auto i:members){auto& track=arrangement.tracks[i];track.color=soft;track.parentTrackID=parent;if(parent)track.patch=jaras::OutputPatch{-2,2};else if(!anchor.isVoid()&&!anchor.isUndefined())anchors[track.id]=arrangement.tracks.at((int)anchor).id;}
        }
        std::vector<jaras::Track> ordered(arrangement.tracks.begin(),arrangement.tracks.begin()+originalCount),additions(arrangement.tracks.begin()+originalCount,arrangement.tracks.end());
        std::set<ID> populatedParents;
        for (const auto &track : additions) if (track.parentTrackID) populatedParents.insert(*track.parentTrackID);
        additions.erase(std::remove_if(additions.begin(), additions.end(), [&](const auto &track) {
            return track.clips.empty() && !populatedParents.count(track.id);
        }), additions.end());
        std::vector<jaras::Track> roots;for(const auto& track:additions)if(!track.parentTrackID&&!anchors.count(track.id))roots.push_back(track);
        if(originalCount==0)std::stable_partition(roots.begin(),roots.end(),[&](const auto& track){return rules.call("groupKeyFromFolderName",{text(track.name)}).toString()!="percussivo";});
        ordered.insert(ordered.end(),roots.begin(),roots.end());std::map<ID,ID> last;
        for(const auto& track:additions)if(anchors.count(track.id)){auto anchor=anchors.at(track.id);auto previous=last.count(anchor)?last.at(anchor):anchor;auto at=std::find_if(ordered.begin(),ordered.end(),[&](const auto&t){return t.id==previous;});ordered.insert(at==ordered.end()?at:std::next(at),track);last[anchor]=track.id;}
        std::map<ID,std::optional<ID>> parents;for(const auto& track:arrangement.tracks)parents[track.id]=track.parentTrackID;
        auto belongs=[&](const jaras::Track& track,const ID& parent){auto p=track.parentTrackID;std::set<ID> visited;while(p&&visited.insert(*p).second){if(*p==parent)return true;p=parents[*p];}return false;};
        for(const auto& track:additions)if(track.parentTrackID){auto at=std::find_if(ordered.begin(),ordered.end(),[&](const auto&t){return t.id==*track.parentTrackID;});if(at!=ordered.end()){++at;while(at!=ordered.end()&&belongs(*at,*track.parentTrackID))++at;}ordered.insert(at,track);}
        arrangement.tracks=std::move(ordered);
        const auto videoFolder = destination.getParentDirectory().getChildFile("Videos");
        for (int i = 0; i < songs.size(); ++i) {
            const auto region = std::find_if(arrangement.parts.begin(), arrangement.parts.end(),
                [&](const auto &candidate) { return candidate.id == addedRegions[static_cast<size_t>(i)]; });
            if (const auto exported = multitracks.find(songs[i]["folderPath"].toString()); exported != multitracks.end()) {
                const auto child = drawerChildren.find(region->id);
                const auto *ids = child == drawerChildren.end() ? nullptr : &drawerMarkerIDs.at(child->second.parent);
                restoreMultitrack(*exported->second, arrangement, *region, destination.getParentDirectory(),
                    supplemental[songs[i]["folderPath"].toString()], ids, renderedTracks[region->id], owned, progress);
                if (child != drawerChildren.end()) {
                    const auto &placement = child->second;
                    const auto parent = std::find_if(arrangement.parts.begin(), arrangement.parts.end(),
                        [&](const auto &part) { return part.id == placement.parent; });
                    if (parent == arrangement.parts.end()) throw std::runtime_error("Missing Multitrack drawer.");
                    region->parentRegionID = parent->id;
                    region->startTime = std::max(parent->startTime, region->startTime);
                    region->endTime = std::min(parent->endTime, region->endTime);
                    jaras::TimelineMarker cue;
                    cue.id = placement.entry->cueID ? ids->at(*placement.entry->cueID) : uuid();
                    cue.name = placement.entry->cueName.value_or(region->name); cue.position = placement.cue;
                    cue.color = placement.entry->cueColor.value_or(region->color.value_or(0x999999)); cue.unifiedRegionID = placement.parent;
                    cue.regionOwnerID = cue.sourceRegionID = region->id;
                    arrangement.markers->push_back(std::move(cue));
                }
                continue;
            }
            std::array<double, 3> position{region->startTime, region->startTime, region->startTime};
            for (const auto &source : supplemental[songs[i]["folderPath"].toString()]) {
                if (source.lyrics) {
                    jlLyrics::insert(arrangement, *source.lyrics, region->startTime, region->id);
                    continue;
                }
                if (!source.videoTrack) continue;
                const auto lane = *source.videoTrack;
                if (videoFolder.createDirectory().failed()) throw std::runtime_error("Could not create the Videos folder.");
                const auto target = videoFolder.getNonexistentChildFile(source.file.getFileNameWithoutExtension(),
                    source.file.getFileExtension(), false);
                if (!source.file.copyFileTo(target)) throw std::runtime_error("Could not copy video: " + utf8(source.file.getFileName()));
                owned.add(target);
                jaras::Track *channel = nullptr;
                if (lane != 0) channel = &jlLyrics::track(arrangement, lane);
                else {
                    auto row = std::find_if(arrangement.tracks.begin(), arrangement.tracks.end(), [](const auto &track) {
                        return !track.parentTrackID && track.name == "Video" && jaras::fixedTrackName(track.role).empty();
                    });
                    if (row == arrangement.tracks.end()) {
                        jaras::Track video; video.id = uuid(); video.role.id = "other"; video.name = "Video"; video.color = 0x828282;
                        auto before = std::find_if(arrangement.tracks.begin(), arrangement.tracks.end(), [&](const auto &track) {
                            return !track.parentTrackID && rules.call("groupKeyFromFolderName", {text(track.name)}).toString() == "interno";
                        });
                        if (before == arrangement.tracks.end())
                            before = std::find_if(arrangement.tracks.begin(), arrangement.tracks.end(), [](const auto &track) { return jaras::fixedTrackName(track.role).empty(); });
                        row = arrangement.tracks.insert(before, std::move(video));
                    }
                    channel = &*row;
                }
                auto &at = position[static_cast<size_t>(lane)];
                jaras::AudioClip clip;
                clip.id = uuid(); clip.name = utf8(source.file.getFileNameWithoutExtension());
                clip.startTime = at; clip.duration = source.duration; clip.regionOwnerID = region->id;
                clip.audioFile = jaras::AudioFile{utf8("Videos/" + target.getFileName()), {}};
                channel->clips.push_back(std::move(clip));
                at += source.duration;
                arrangement.duration = std::max(arrangement.duration, at);
            }
        }

        if(detectBPM)for(const auto& id:addedRegions){auto part=std::find_if(arrangement.parts.begin(),arrangement.parts.end(),[&](const auto&p){return p.id==id;});
            if (arrangement.markers && std::any_of(arrangement.markers->begin(), arrangement.markers->end(),
                [&](const auto &marker) { return marker.tempoBPM && marker.regionOwnerID == id; })) continue;
            if(progress)progress("Detecting BPM: "+text(part->name),1);
            auto markers=clickTempo::markers(arrangement,*part,[&](const jaras::AudioFile& file){return clickTempo::transients(destination.getParentDirectory().getChildFile(text(file.path)));});
            if(markers.empty())warnings.add(text(part->name)+": no valid Click found for BPM detection");else clickTempo::insert(arrangement,*part,markers);
        }
        project.updatedAt=utf8(Time::getCurrentTime().toISO8601(true));
        jaras::validate(project);if(importedFiles)*importedFiles=owned;return project;
    }catch(...){for(const auto& file:owned)file.deleteFile();throw;}
}
}
