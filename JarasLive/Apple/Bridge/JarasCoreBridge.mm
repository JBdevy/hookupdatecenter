#import "JarasCoreBridge.h"
#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Import/TrackTaxonomy.hpp"
#include <memory>
#include <map>
#include <set>
#include <stdexcept>
using namespace jaras;
static std::string str(id value) { if (![value isKindOfClass:NSString.class]) throw std::invalid_argument("Expected text"); return [value UTF8String]; }
static NSString* text(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static NSArray* array(id value) { if (![value isKindOfClass:NSArray.class]) throw std::invalid_argument("Expected array"); return value; }
static NSDictionary* object(id value) { if (![value isKindOfClass:NSDictionary.class]) throw std::invalid_argument("Expected object"); return value; }
static double number(id value) { if (![value isKindOfClass:NSNumber.class]) throw std::invalid_argument("Expected number"); return [value doubleValue]; }
static bool clipFXBypass(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) throw std::invalid_argument("Expected boolean");
    return [value boolValue];
}
static std::string readClipText(id value) {
    if (![value isKindOfClass:NSString.class]) throw std::invalid_argument("Expected text");
    NSData* utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) throw std::invalid_argument("Invalid text encoding");
    std::string result((const char*)utf8.bytes, utf8.length);
    validateClipText(result); return result;
}
static NSString* clipTextJSON(const std::string& value) {
    NSString* result = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    if (!result) throw std::invalid_argument("Invalid text encoding");
    return result;
}
static id optionalID(const std::optional<ID>& value) { return value ? (id)text(*value) : NSNull.null; }
static NSDictionary* patchJSON(const OutputPatch& p) { return @{@"firstChannel":@(p.firstChannel), @"channelCount":@(p.channelCount)}; }
static OutputPatch readPatch(id value) { NSDictionary* p=object(value); return {(int)number(p[@"firstChannel"]), (int)number(p[@"channelCount"])}; }
static NSArray* patchesJSON(const std::vector<OutputPatch>& patches) {
    NSMutableArray* result=[NSMutableArray new]; for (const auto& patch : patches) [result addObject:patchJSON(patch)]; return result;
}
static std::vector<OutputPatch> readPatches(id value) {
    std::vector<OutputPatch> result; for (id patch in array(value)) result.push_back(readPatch(patch)); return result;
}
static NSDictionary* timecodeJSON(const TimecodeSettings& tc) { return @{@"mode":text(tc.mode),@"frameRate":@(tc.frameRate),@"offset":@(tc.offset),@"regionRelative":@(tc.regionRelative),@"midiDestination":@(tc.midiDestination)}; }
static TimecodeSettings readTimecode(id value) { NSDictionary* d=object(value); return {str(d[@"mode"]),number(d[@"frameRate"]),number(d[@"offset"]),bool([d[@"regionRelative"] boolValue]),(int)number(d[@"midiDestination"])}; }
static std::string readClipFX(id value) {
    NSDictionary* settings = object(value);
    for (NSString* key in @[@"instrumentID", @"instrumentParameters", @"instrumentBypassed"])
        if (settings[key]) throw std::invalid_argument("Items cannot contain instruments");
    NSSet* effects = [NSSet setWithArray:@[@"EQ", @"Compressor", @"Pitch", @"Delay", @"Reverb"]];
    NSMutableSet* inserted = [NSMutableSet new];
    for (id effect in array(settings[@"inserted"])) {
        if (![effect isKindOfClass:NSString.class] || ![effects containsObject:effect] || [inserted containsObject:effect])
            throw std::invalid_argument("Invalid item FX selection");
        [inserted addObject:effect];
    }
    NSData* data = [NSJSONSerialization dataWithJSONObject:settings options:0 error:nil];
    if (!data) throw std::invalid_argument("Invalid item FX data");
    auto json = str([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    validateClipFXJSON(json); return json;
}
static TrackRouting readRouting(id value) {
    NSDictionary *d=object(value);TrackRouting r;r.receives.clear();r.transmitters.clear();
    for(id raw in array(d[@"receives"]))r.receives.push_back(raw==NSNull.null?std::nullopt:std::optional<ID>(str(raw)));
    for(id raw in array(d[@"transmitters"]))r.transmitters.push_back(raw==NSNull.null?std::nullopt:std::optional<ID>(str(raw)));
    return r;
}
static NSDictionary *routingJSON(const TrackRouting& r) {
    NSMutableArray *receives=[NSMutableArray new],*transmitters=[NSMutableArray new];
    for(const auto& id:r.receives)[receives addObject:optionalID(id)];
    for(const auto& id:r.transmitters)[transmitters addObject:optionalID(id)];
    return @{@"receives":receives,@"transmitters":transmitters};
}
static NSDictionary* trackJSON(const Track& t, bool includeWaveforms = true) {
    NSMutableDictionary* d = [@{@"id":text(t.id), @"name":text(t.name), @"role":text(t.role.id), @"volume":@(t.volume), @"pan":@(t.pan), @"mute":@(t.mute), @"solo":@(t.solo), @"output":@(t.output)} mutableCopy];
    NSMutableArray* clips=[NSMutableArray new];
    for (const auto& clip:t.clips) {
        NSMutableArray* peaks=[NSMutableArray new];
        if(includeWaveforms) for(double peak:clip.waveform) [peaks addObject:@(peak)];
        NSMutableDictionary* item=[@{@"id":text(clip.id),@"name":text(clip.name),@"startTime":@(clip.startTime),@"duration":@(clip.duration),@"sourceOffset":@(clip.sourceOffset),@"playbackRate":@(clip.playbackRate),@"waveform":peaks} mutableCopy];
        if(clip.audioFile) { NSMutableDictionary* file=[@{@"path":text(clip.audioFile->path)} mutableCopy]; if(clip.audioFile->sha256) file[@"sha256"]=text(*clip.audioFile->sha256); item[@"audioFile"]=file; }
        if(clip.loopStart) item[@"loopStart"]=@(*clip.loopStart);
        if(clip.loopLength) item[@"loopLength"]=@(*clip.loopLength);
        if(clip.recordingLane) item[@"recordingLane"]=@(*clip.recordingLane);
        if(clip.text) item[@"text"]=clipTextJSON(*clip.text);
        if(clip.gain) item[@"gain"]=@(*clip.gain);
        if(clip.fxBypassed) item[@"fxBypassed"]=@(*clip.fxBypassed);
        if(clip.timecodeStartOffset) item[@"timecodeStartOffset"]=@(*clip.timecodeStartOffset);
        if(clip.timecodeEndOffset) item[@"timecodeEndOffset"]=@(*clip.timecodeEndOffset);
        if(clip.fxJSON) item[@"fx"]=[NSJSONSerialization JSONObjectWithData:[text(*clip.fxJSON) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if(!includeWaveforms) item[@"waveformChannels"]=@[];
        else if(!clip.waveformChannels.empty()) {
            NSMutableArray* channels=[NSMutableArray new];
            for(const auto& channel:clip.waveformChannels) { NSMutableArray* values=[NSMutableArray new]; for(double peak:channel) [values addObject:@(peak)]; [channels addObject:values]; }
            item[@"waveformChannels"]=channels;
        }
        if(clip.muted) item[@"muted"]=@YES;
        [clips addObject:item];
    }
    d[@"clips"]=clips;
    if(t.parentTrackID) d[@"parentTrackID"]=text(*t.parentTrackID);
    if(t.midiInput) d[@"midiInput"]=@(*t.midiInput);
    if(t.inputPatch) d[@"inputPatch"]=patchJSON(*t.inputPatch);
    if(t.timecode) d[@"timecode"]=timecodeJSON(*t.timecode);
    if(t.fxJSON) d[@"fx"]=[NSJSONSerialization JSONObjectWithData:[text(*t.fxJSON) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if(t.recordingFormat) d[@"recordingFormat"]=text(*t.recordingFormat);
    if(t.color) d[@"color"]=@(*t.color);
    if(t.patch) d[@"patch"]=patchJSON(*t.patch);
    if(t.routing) d[@"routing"]=routingJSON(*t.routing);
    if(t.secondaryPatch) d[@"secondaryPatch"]=patchJSON(*t.secondaryPatch);
    if(t.outputs) d[@"outputs"]=patchesJSON(*t.outputs);
    if (t.audioFile) { NSMutableDictionary* file = [@{@"path":text(t.audioFile->path)} mutableCopy]; if (t.audioFile->sha256) file[@"sha256"] = text(*t.audioFile->sha256); d[@"audioFile"] = file; }
    return d;
}
static NSDictionary* regionSetlistJSON(const RegionSetlist& state) {
    NSMutableArray* lists=[NSMutableArray new];
    for(const auto& list:state.playlists) {
        NSMutableArray* ids=[NSMutableArray new]; for(const auto& id:list.regionIds) [ids addObject:text(id)];
        [lists addObject:@{@"id":text(list.id),@"name":text(list.name),@"songId":text(list.songId),@"regionIds":ids}];
    }
    NSMutableDictionary* result=[@{@"playlists":lists,@"autoAdvance":@(state.autoAdvance)} mutableCopy];
    if(state.prepareWithoutPlayback) result[@"prepareWithoutPlayback"]=@(*state.prepareWithoutPlayback);
    if(state.stopAtRegionEnd) result[@"stopAtRegionEnd"]=@(*state.stopAtRegionEnd);
    if(state.selectedId) result[@"selectedId"]=text(*state.selectedId);
    if(state.blocks) {
        NSMutableArray* blocks=[NSMutableArray new];
        for(const auto& block:*state.blocks) {
            NSMutableDictionary* value=[@{@"id":text(block.id),@"songId":text(block.songId),@"name":text(block.name),@"color":@(block.color)} mutableCopy];
            if(block.symbol) value[@"symbol"]=@(*block.symbol);
            if(block.playlistId) value[@"playlistId"]=text(*block.playlistId);
            if(block.beforeRegionId) value[@"beforeRegionId"]=text(*block.beforeRegionId);
            [blocks addObject:value];
        }
        result[@"blocks"]=blocks;
    }
    return result;
}
static RegionSetlist readRegionSetlist(NSDictionary* d) {
    RegionSetlist state; state.autoAdvance=number(d[@"autoAdvance"])!=0;
    if(d[@"prepareWithoutPlayback"] && d[@"prepareWithoutPlayback"]!=NSNull.null) state.prepareWithoutPlayback=clipFXBypass(d[@"prepareWithoutPlayback"]);
    if(d[@"stopAtRegionEnd"] && d[@"stopAtRegionEnd"]!=NSNull.null) state.stopAtRegionEnd=clipFXBypass(d[@"stopAtRegionEnd"]);
    if(d[@"blocks"] && d[@"blocks"]!=NSNull.null) {
        state.blocks=std::vector<SetlistBlock>{};
        for(id raw in array(d[@"blocks"])) {
            NSDictionary* value=object(raw); SetlistBlock block;
            if(value[@"symbol"] && value[@"symbol"] != NSNull.null) block.symbol = number(value[@"symbol"]) != 0;
            block.id=str(value[@"id"]); block.songId=str(value[@"songId"]); block.name=str(value[@"name"]); block.color=(unsigned)number(value[@"color"]);
            if(value[@"playlistId"] && value[@"playlistId"]!=NSNull.null) block.playlistId=str(value[@"playlistId"]);
            if(value[@"beforeRegionId"] && value[@"beforeRegionId"]!=NSNull.null) block.beforeRegionId=str(value[@"beforeRegionId"]);
            state.blocks->push_back(std::move(block));
        }
    }
    if(d[@"selectedId"] && d[@"selectedId"]!=NSNull.null) state.selectedId=str(d[@"selectedId"]);
    for(id raw in array(d[@"playlists"])) {
        NSDictionary* p=object(raw); RegionPlaylist list; list.id=str(p[@"id"]); list.name=str(p[@"name"]); list.songId=str(p[@"songId"]);
        for(id region in array(p[@"regionIds"])) list.regionIds.push_back(str(region));
        state.playlists.push_back(std::move(list));
    }
    return state;
}
static NSDictionary* projectJSON(const Project& p, bool includeWaveforms = true) {
    NSMutableArray *songs = [NSMutableArray new], *setlists = [NSMutableArray new];
    for (const auto& s : p.songs) {
        NSMutableArray *tracks = [NSMutableArray new], *parts = [NSMutableArray new];
        for (const auto& t : s.tracks) [tracks addObject:trackJSON(t,includeWaveforms)];
        for (const auto& part : s.parts) {
            NSMutableDictionary* region = [@{@"id":text(part.id),@"name":text(part.name),@"startTime":@(part.startTime),@"endTime":@(part.endTime)} mutableCopy];
            if (part.color) region[@"color"] = @(*part.color);
            if (part.uppercaseName) region[@"uppercaseName"] = @(*part.uppercaseName);
            if (part.parentRegionID) region[@"parentRegionID"] = text(*part.parentRegionID);
            if (part.pitchSemitones) region[@"pitchSemitones"] = @(*part.pitchSemitones);
            if (part.pitchTrackIDs) { NSMutableArray* ids = [NSMutableArray new]; for (const auto& id : *part.pitchTrackIDs) [ids addObject:text(id)]; region[@"pitchTrackIDs"] = ids; }
            if (part.pitchGroupIDs) { NSMutableArray* ids = [NSMutableArray new]; for (const auto& id : *part.pitchGroupIDs) [ids addObject:text(id)]; region[@"pitchGroupIDs"] = ids; }
            [parts addObject:region];
        }
        NSMutableDictionary* song=[@{@"id":text(s.id),@"name":text(s.name),@"duration":@(s.duration),@"bpm":@(s.bpm),@"beatsPerBar":@(s.beatsPerBar),@"beatUnit":@(s.beatUnit),@"tracks":tracks,@"parts":parts} mutableCopy];
        if (s.markers) {
            NSMutableArray* markers=[NSMutableArray new];
            for (const auto& marker:*s.markers) {
                NSMutableDictionary* value = [@{@"id":text(marker.id),@"name":text(marker.name),@"position":@(marker.position),@"color":@(marker.color)} mutableCopy];
                if (marker.unifiedRegionID) value[@"unifiedRegionID"] = text(*marker.unifiedRegionID);
                if (marker.sourceRegionID) value[@"sourceRegionID"] = text(*marker.sourceRegionID);
                [markers addObject:value];
            }
            song[@"markers"]=markers;
        }
        [songs addObject:song];
    }
    for (const auto& s : p.setlists) { NSMutableArray* ids = [NSMutableArray new]; for (const auto& id : s.songIds) [ids addObject:text(id)]; [setlists addObject:@{@"id":text(s.id),@"name":text(s.name),@"songIds":ids}]; }
    NSMutableDictionary* result=[@{@"id":text(p.id),@"name":text(p.name),@"projectFormatVersion":@(p.projectFormatVersion),@"minimumJarasVersion":text(p.minimumJarasVersion),@"createdAt":text(p.createdAt),@"updatedAt":text(p.updatedAt),@"songs":songs,@"setlists":setlists} mutableCopy];
    if(p.masterVolume != 1) result[@"masterVolume"]=@(p.masterVolume);
    if(p.masterMute) result[@"masterMute"]=@YES;
    if(p.masterFXJSON) result[@"masterFX"]=[NSJSONSerialization JSONObjectWithData:[text(*p.masterFXJSON) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if(p.masterPatch) result[@"masterPatch"]=patchJSON(*p.masterPatch);
    if(p.masterSecondaryPatch) result[@"masterSecondaryPatch"]=patchJSON(*p.masterSecondaryPatch);
    if(p.masterOutputs) result[@"masterOutputs"]=patchesJSON(*p.masterOutputs);
    if(p.regionSetlist) result[@"regionSetlist"]=regionSetlistJSON(*p.regionSetlist);
    return result;
}
static Track readTrack(NSDictionary* td) {
 Track t; if(td[@"routing"] && td[@"routing"]!=NSNull.null)t.routing=readRouting(td[@"routing"]);t.id=str(td[@"id"]); t.name=str(td[@"name"]); t.role={str(td[@"role"])}; t.volume=number(td[@"volume"]); t.pan=number(td[@"pan"]); t.mute=number(td[@"mute"])!=0; t.solo=number(td[@"solo"])!=0; t.output=number(td[@"output"]);
            if (td[@"audioFile"] && td[@"audioFile"] != NSNull.null) { NSDictionary* f=object(td[@"audioFile"]); AudioFile file; file.path=str(f[@"path"]); if (f[@"sha256"] && f[@"sha256"]!=NSNull.null) file.sha256=str(f[@"sha256"]); t.audioFile=file; }
            for (id rawClip in array(td[@"clips"])) { NSDictionary* cd=object(rawClip); AudioClip clip; clip.id=str(cd[@"id"]); clip.name=str(cd[@"name"]); clip.startTime=number(cd[@"startTime"]); clip.duration=number(cd[@"duration"]); clip.sourceOffset=number(cd[@"sourceOffset"]); clip.playbackRate=cd[@"playbackRate"] && cd[@"playbackRate"]!=NSNull.null ? number(cd[@"playbackRate"]) : 1; for(id peak in array(cd[@"waveform"])) clip.waveform.push_back(number(peak)); if(cd[@"audioFile"] && cd[@"audioFile"]!=NSNull.null) { NSDictionary* f=object(cd[@"audioFile"]); AudioFile file; file.path=str(f[@"path"]); if(f[@"sha256"] && f[@"sha256"]!=NSNull.null) file.sha256=str(f[@"sha256"]); clip.audioFile=file; } if(cd[@"text"] && cd[@"text"]!=NSNull.null) clip.text=readClipText(cd[@"text"]); if(cd[@"gain"] && cd[@"gain"]!=NSNull.null) clip.gain=number(cd[@"gain"]); if(cd[@"fxBypassed"] && cd[@"fxBypassed"]!=NSNull.null) clip.fxBypassed=clipFXBypass(cd[@"fxBypassed"]); if(cd[@"timecodeStartOffset"] && cd[@"timecodeStartOffset"]!=NSNull.null) clip.timecodeStartOffset=number(cd[@"timecodeStartOffset"]); if(cd[@"timecodeEndOffset"] && cd[@"timecodeEndOffset"]!=NSNull.null) clip.timecodeEndOffset=number(cd[@"timecodeEndOffset"]); if(cd[@"fx"] && cd[@"fx"]!=NSNull.null) clip.fxJSON=readClipFX(cd[@"fx"]); for(id channel in array(cd[@"waveformChannels"] ?: @[])) { std::vector<double> values; for(id peak in array(channel)) values.push_back(number(peak)); clip.waveformChannels.push_back(std::move(values)); } if(cd[@"loopStart"] && cd[@"loopStart"]!=NSNull.null) clip.loopStart=number(cd[@"loopStart"]); if(cd[@"loopLength"] && cd[@"loopLength"]!=NSNull.null) clip.loopLength=number(cd[@"loopLength"]); if(cd[@"recordingLane"] && cd[@"recordingLane"]!=NSNull.null) clip.recordingLane=(int)number(cd[@"recordingLane"]); clip.muted=[cd[@"muted"] respondsToSelector:@selector(boolValue)] && [cd[@"muted"] boolValue]; t.clips.push_back(std::move(clip)); }
            if(td[@"timecode"] && td[@"timecode"]!=NSNull.null) t.timecode=readTimecode(td[@"timecode"]);
            if(td[@"fx"] && td[@"fx"]!=NSNull.null) t.fxJSON=str([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object(td[@"fx"]) options:0 error:nil] encoding:NSUTF8StringEncoding]);
            if(td[@"inputPatch"] && td[@"inputPatch"] != NSNull.null) t.inputPatch=readPatch(td[@"inputPatch"]);
            if(td[@"recordingFormat"] && td[@"recordingFormat"] != NSNull.null) t.recordingFormat=str(td[@"recordingFormat"]);
            if(td[@"color"] && td[@"color"] != NSNull.null) t.color=(unsigned)number(td[@"color"]);
            if(td[@"parentTrackID"] && td[@"parentTrackID"] != NSNull.null) t.parentTrackID=str(td[@"parentTrackID"]);
            if(td[@"midiInput"] && td[@"midiInput"] != NSNull.null) t.midiInput=int(number(td[@"midiInput"]));
            if(td[@"secondaryPatch"] && td[@"secondaryPatch"]!=NSNull.null) t.secondaryPatch=readPatch(td[@"secondaryPatch"]);
            if(td[@"patch"] && td[@"patch"] != NSNull.null) t.patch=readPatch(td[@"patch"]);
            if(td[@"outputs"] && td[@"outputs"] != NSNull.null) t.outputs=readPatches(td[@"outputs"]);
    return t;
}
static Project readProject(NSDictionary* d) {
    Project p; p.id=str(d[@"id"]); p.name=str(d[@"name"]); p.projectFormatVersion=number(d[@"projectFormatVersion"]); p.minimumJarasVersion=str(d[@"minimumJarasVersion"]); p.createdAt=str(d[@"createdAt"]); p.updatedAt=str(d[@"updatedAt"]);
    for (id rawSong in array(d[@"songs"])) {
        NSDictionary* sd=object(rawSong); Song s; s.id=str(sd[@"id"]); s.name=str(sd[@"name"]); s.duration=number(sd[@"duration"]); s.bpm=number(sd[@"bpm"]); s.beatsPerBar=sd[@"beatsPerBar"] ? number(sd[@"beatsPerBar"]) : 4; s.beatUnit=sd[@"beatUnit"] ? number(sd[@"beatUnit"]) : 4;
        for (id rawTrack in array(sd[@"tracks"])) s.tracks.push_back(readTrack(object(rawTrack)));
        for (id rawPart in array(sd[@"parts"])) { NSDictionary* part=object(rawPart); s.parts.push_back({str(part[@"id"]),str(part[@"name"]),number(part[@"startTime"]),number(part[@"endTime"])}); if (part[@"color"] && part[@"color"] != NSNull.null) { double color = number(part[@"color"]); if (color < 0 || color > 0xFFFFFF || color != (unsigned)color) throw std::invalid_argument("Invalid region color"); s.parts.back().color = (unsigned)color; } if (part[@"uppercaseName"] && part[@"uppercaseName"] != NSNull.null) s.parts.back().uppercaseName = [part[@"uppercaseName"] boolValue]; if (part[@"parentRegionID"] && part[@"parentRegionID"] != NSNull.null) s.parts.back().parentRegionID = str(part[@"parentRegionID"]); if (part[@"pitchSemitones"] && part[@"pitchSemitones"] != NSNull.null) { double value = number(part[@"pitchSemitones"]); if (value != std::round(value) || value < -6 || value > 6) throw std::invalid_argument("Invalid region pitch"); s.parts.back().pitchSemitones = (int)value; } for (NSString* key in @[@"pitchTrackIDs", @"pitchGroupIDs"]) if (part[key] && part[key] != NSNull.null) { std::vector<ID> ids; for (id value in array(part[key])) ids.push_back(str(value)); if ([key isEqualToString:@"pitchTrackIDs"]) s.parts.back().pitchTrackIDs = std::move(ids); else s.parts.back().pitchGroupIDs = std::move(ids); } }
        if (sd[@"markers"] && sd[@"markers"] != NSNull.null) {
            s.markers.emplace();
            for (id raw in array(sd[@"markers"])) {
                NSDictionary* marker=object(raw);
                s.markers->push_back({str(marker[@"id"]),str(marker[@"name"]),number(marker[@"position"]),(unsigned)number(marker[@"color"])});
                if (marker[@"unifiedRegionID"] && marker[@"unifiedRegionID"] != NSNull.null) s.markers->back().unifiedRegionID = str(marker[@"unifiedRegionID"]);
                if (marker[@"sourceRegionID"] && marker[@"sourceRegionID"] != NSNull.null) s.markers->back().sourceRegionID = str(marker[@"sourceRegionID"]);
            }
        }
        p.songs.push_back(std::move(s));
    }
    for (id rawSet in array(d[@"setlists"])) { NSDictionary* sd=object(rawSet); Setlist s; s.id=str(sd[@"id"]); s.name=str(sd[@"name"]); for (id songId in array(sd[@"songIds"])) s.songIds.push_back(str(songId)); p.setlists.push_back(std::move(s)); }
    if(d[@"masterVolume"] && d[@"masterVolume"] != NSNull.null) p.masterVolume=number(d[@"masterVolume"]);
    p.masterMute=[d[@"masterMute"] respondsToSelector:@selector(boolValue)] && [d[@"masterMute"] boolValue];
    if(d[@"masterFX"] && d[@"masterFX"]!=NSNull.null) p.masterFXJSON=str([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:object(d[@"masterFX"]) options:0 error:nil] encoding:NSUTF8StringEncoding]);
    if(d[@"masterPatch"] && d[@"masterPatch"] != NSNull.null) p.masterPatch=readPatch(d[@"masterPatch"]);
    if(d[@"masterOutputs"] && d[@"masterOutputs"] != NSNull.null) p.masterOutputs=readPatches(d[@"masterOutputs"]);
    if(d[@"masterSecondaryPatch"] && d[@"masterSecondaryPatch"] != NSNull.null) p.masterSecondaryPatch=readPatch(d[@"masterSecondaryPatch"]);
    if(d[@"regionSetlist"] && d[@"regionSetlist"]!=NSNull.null) p.regionSetlist=readRegionSetlist(object(d[@"regionSetlist"]));
    return p;
}
static void report(NSError** error, const std::exception& e) { if (error) *error = [NSError errorWithDomain:@"JarasLiveCore" code:1 userInfo:@{NSLocalizedDescriptionKey:text(e.what())}]; }
@implementation JarasCoreBridge { std::unique_ptr<Engine> _engine; TrackTaxonomy _taxonomy; }
- (instancetype)init { if ((self=[super init])) _engine=std::make_unique<Engine>(); return self; }
- (BOOL)applyProjectEditData:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
    try { _engine->applyProjectEdit(readProject(object(decoded))); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)applyProjectMetadataEditData:(NSData*)data preservingWaveforms:(NSArray<NSString*>*)identifiers error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if(!decoded) return NO;
    try {
        std::map<ID,const AudioClip*> existing;
        for(const auto& song:_engine->project().songs) for(const auto& track:song.tracks) for(const auto& clip:track.clips) existing.emplace(clip.id,&clip);
        std::set<ID> pending;
        for(id identifier:array(identifiers)) {
            const auto key=str(identifier);
            if(!pending.insert(key).second || existing.find(key)==existing.end()) throw std::invalid_argument("Unknown or duplicate preserved waveform ID");
        }
        Project project=readProject(object(decoded));
        for(auto& song:project.songs) for(auto& track:song.tracks) for(auto& clip:track.clips) {
            if(!pending.erase(clip.id)) continue;
            if(!clip.waveform.empty() || !clip.waveformChannels.empty()) throw std::invalid_argument("Preserved waveform data must be omitted");
            const auto previous=existing.at(clip.id);
            clip.waveform=previous->waveform; clip.waveformChannels=previous->waveformChannels;
        }
        if(!pending.empty()) throw std::invalid_argument("Preserved waveform item is missing from the edit");
        _engine->applyProjectEdit(std::move(project)); return YES;
    } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)loadProjectData:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
    try { _engine->loadProject(readProject(object(decoded))); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)executeCommand:(NSString*)command target:(NSString*)target value:(double)value error:(NSError**)error {
    static const std::map<std::string,CommandKind> commands={{"ignoreNext",CommandKind::ignoreNext},{"tempo",CommandKind::tempo},{"beatsPerBar",CommandKind::beatsPerBar},{"beatUnit",CommandKind::beatUnit},{"selectRegion",CommandKind::selectRegion},{"queueRegion",CommandKind::queueRegion},{"clipMute",CommandKind::clipMute},{"clipGain",CommandKind::clipGain},{"pause",CommandKind::pause},{"play",CommandKind::play},{"stop",CommandKind::stop},{"next",CommandKind::next},{"previous",CommandKind::previous},{"queue",CommandKind::queue},{"select",CommandKind::select},{"toggleLoop",CommandKind::toggleLoop},{"seek",CommandKind::seek},{"editSeek",CommandKind::editSeek},{"subPlay",CommandKind::subPlay},{"subStop",CommandKind::subStop},{"subSeek",CommandKind::subSeek},{"stopAll",CommandKind::stopAll},{"volume",CommandKind::volume},{"pan",CommandKind::pan},{"mute",CommandKind::mute},{"solo",CommandKind::solo}};
    try { auto found=commands.find(str(command)); if(found==commands.end()) throw std::invalid_argument("Unknown command"); _engine->execute({found->second,target?str(target):"",value}); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (NSData*)snapshotWithError:(NSError**)error {
    NSData* playback=[self playbackSnapshotWithError:error]; if(!playback) return nil;
    NSMutableDictionary* data=[[NSJSONSerialization JSONObjectWithData:playback options:0 error:error] mutableCopy];
    data[@"project"]=projectJSON(_engine->project());
    return [NSJSONSerialization dataWithJSONObject:data options:0 error:error];
}
- (NSData*)metadataSnapshotWithError:(NSError**)error {
    NSData* playback=[self playbackSnapshotWithError:error]; if(!playback) return nil;
    NSMutableDictionary* data=[[NSJSONSerialization JSONObjectWithData:playback options:0 error:error] mutableCopy];
    data[@"project"]=projectJSON(_engine->project(),false);
    return [NSJSONSerialization dataWithJSONObject:data options:0 error:error];
}
- (NSData*)playbackSnapshotWithError:(NSError**)error {
    const auto& t=_engine->transport();
    NSDictionary* transport=@{@"ignoreNextAfter":t.ignoreNextAfter ? (id)@(*t.ignoreNextAfter) : NSNull.null,@"ignoreNextEnd":t.ignoreNextEnd ? (id)@(*t.ignoreNextEnd) : NSNull.null,@"ignoreNextRegionId":optionalID(t.ignoreNextRegionId),@"subPlayPromotion":@(t.subPlayPromotion),@"regionId":optionalID(t.regionId),@"queuedRegionId":optionalID(t.queuedRegionId),@"queueStartedAt":@(t.queueStartedAt),@"paused":@(t.paused),@"playing":@(t.playing),@"songId":optionalID(t.songId),@"position":@(t.position),@"editPosition":@(t.editPosition),@"queue":@{@"songId":optionalID(t.queue.songId)},@"loop":@{@"enabled":@(t.loop.enabled)},@"subPlay":@{@"playing":@(t.subPlay.playing),@"position":@(t.subPlay.position)}};
    return [NSJSONSerialization dataWithJSONObject:@{@"transport":transport,@"nextSongId":optionalID(_engine->nextSongId())} options:0 error:error];
}
- (BOOL)configureRegionSetlistData:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if(!decoded) return NO;
    try { _engine->configureRegionSetlist(readRegionSetlist(object(decoded))); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)addTrackWithId:(NSString*)identifier name:(NSString*)name role:(NSString*)role error:(NSError**)error {
    try { _engine->addTrack(str(identifier),str(name),{str(role)}); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)resizeRegion:(NSString*)identifier start:(double)start end:(double)end error:(NSError**)error {
    try { _engine->resizeRegion(str(identifier), start, end); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)moveRegion:(NSString*)identifier start:(double)start error:(NSError**)error {
    try { _engine->moveRegion(str(identifier), start); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setTimecode:(NSString*)track data:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if(!decoded) return NO;
    try { _engine->setTimecode(str(track), readTimecode(decoded)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setFX:(NSString *)track data:(NSData *)data error:(NSError **)error {
    try { object([NSJSONSerialization JSONObjectWithData:data options:0 error:error]); _engine->setFX(str(track),str([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding])); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setClipFX:(NSString *)clip data:(NSData *)data error:(NSError **)error {
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
    try { _engine->setClipFX(str(clip), readClipFX(decoded)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setClipFXBypass:(NSString *)clip bypassed:(BOOL)bypassed error:(NSError **)error {
    try { _engine->setClipFXBypass(str(clip), bypassed); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setClipText:(NSString *)clip text:(NSString *)value error:(NSError **)error {
    try { _engine->setClipText(str(clip), readClipText(value)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setMIDIInput:(NSString*)track slot:(int)slot error:(NSError**)error {
    try { _engine->setMIDIInput(str(track), slot); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setRecording:(NSString*)track first:(int)first count:(int)count format:(NSString*)format error:(NSError**)error {
    try { _engine->setRecording(str(track), first, count, str(format)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)pasteItems:(NSData*)data song:(NSString*)song moving:(BOOL)moving error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
    try {
        std::vector<Track> tracks;
        for (id raw in array(decoded)) tracks.push_back(readTrack(object(raw)));
        _engine->pasteItems(str(song), std::move(tracks), moving); return YES;
    } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)insertAudioTracks:(NSData*)data song:(NSString*)song error:(NSError**)error {
    try {
        id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
        std::vector<Track> tracks;
        for (id raw in array(decoded)) tracks.push_back(readTrack(object(raw)));
        _engine->insertAudioTracks(str(song), std::move(tracks)); return YES;
    } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)addRecordedClip:(NSData*)data track:(NSString*)track error:(NSError**)error {
    try {
        NSDictionary* d=object([NSJSONSerialization JSONObjectWithData:data options:0 error:error]);
        AudioClip clip; if(d[@"loopStart"] && d[@"loopStart"]!=NSNull.null) clip.loopStart=number(d[@"loopStart"]); if(d[@"loopLength"] && d[@"loopLength"]!=NSNull.null) clip.loopLength=number(d[@"loopLength"]); if(d[@"recordingLane"] && d[@"recordingLane"]!=NSNull.null) clip.recordingLane=(int)number(d[@"recordingLane"]); clip.id=str(d[@"id"]); clip.name=str(d[@"name"]); clip.startTime=number(d[@"startTime"]); clip.duration=number(d[@"duration"]); clip.sourceOffset=number(d[@"sourceOffset"]); clip.playbackRate=d[@"playbackRate"] && d[@"playbackRate"]!=NSNull.null ? number(d[@"playbackRate"]) : 1;
        if(d[@"audioFile"] && d[@"audioFile"]!=NSNull.null) {
            NSDictionary* source = object(d[@"audioFile"]);
            clip.audioFile=AudioFile{str(source[@"path"]),{}};
            if(source[@"sha256"] && source[@"sha256"]!=NSNull.null) clip.audioFile->sha256=str(source[@"sha256"]);
        }
        if(d[@"text"] && d[@"text"]!=NSNull.null) clip.text=readClipText(d[@"text"]);
        if(d[@"gain"] && d[@"gain"]!=NSNull.null) clip.gain=number(d[@"gain"]);
        if(d[@"fxBypassed"] && d[@"fxBypassed"]!=NSNull.null) clip.fxBypassed=clipFXBypass(d[@"fxBypassed"]);
        if(d[@"timecodeStartOffset"] && d[@"timecodeStartOffset"]!=NSNull.null) clip.timecodeStartOffset=number(d[@"timecodeStartOffset"]);
        if(d[@"timecodeEndOffset"] && d[@"timecodeEndOffset"]!=NSNull.null) clip.timecodeEndOffset=number(d[@"timecodeEndOffset"]);
        if(d[@"fx"] && d[@"fx"]!=NSNull.null) clip.fxJSON=readClipFX(d[@"fx"]);
        clip.muted=[d[@"muted"] respondsToSelector:@selector(boolValue)] && [d[@"muted"] boolValue];
        for(id value in array(d[@"waveform"])) clip.waveform.push_back(number(value));
        for(id channel in array(d[@"waveformChannels"] ?: @[])) { std::vector<double> values; for(id value in array(channel)) values.push_back(number(value)); clip.waveformChannels.push_back(std::move(values)); }
        _engine->addRecordedClip(str(track), std::move(clip)); return YES;
    } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)editTrack:(NSString*)identifier name:(NSString*)name color:(unsigned int)color error:(NSError**)error {
    try { _engine->editTrack(str(identifier), str(name), color); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setRegionPitch:(NSString*)identifier semitones:(int)semitones tracks:(NSArray<NSString*>*)tracks groups:(NSArray<NSString*>*)groups error:(NSError**)error {
    try { std::vector<ID> t, g; for (NSString* id in tracks) t.push_back(str(id)); for (NSString* id in groups) g.push_back(str(id)); _engine->setRegionPitch(str(identifier), semitones, std::move(t), std::move(g)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)editRegion:(NSString*)identifier name:(NSString*)name color:(unsigned int)color uppercaseName:(BOOL)uppercaseName error:(NSError**)error {
    try { _engine->editRegion(str(identifier), str(name), color, uppercaseName); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)moveClip:(NSString*)clipId start:(double)start track:(NSString*)trackId error:(NSError**)error {
    try { _engine->moveClip(str(clipId), start, str(trackId)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)deleteManualMarker:(NSString*)identifier error:(NSError**)error {
    try { _engine->deleteManualMarker(str(identifier)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setMarker:(NSString*)identifier name:(NSString*)name position:(double)position color:(unsigned int)color error:(NSError**)error {
    try { _engine->setMarker(str(identifier),str(name),position,color); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)regionsFromClips:(NSArray<NSString*>*)clips identifiers:(NSArray<NSString*>*)identifiers error:(NSError**)error {
    try {
        if (clips.count != identifiers.count) throw std::invalid_argument("Invalid region batch");
        std::vector<std::pair<ID,ID>> items;
        for (NSUInteger i=0; i<clips.count; ++i) items.emplace_back(str(clips[i]),str(identifiers[i]));
        _engine->regionsFromClips(items); return YES;
    } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)regionFromClip:(NSString*)clipId identifier:(NSString*)identifier error:(NSError**)error {
    try { _engine->regionFromClip(str(clipId), str(identifier)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setTrackRouting:(NSData *)data error:(NSError **)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];if(!decoded)return NO;
    try {std::vector<std::pair<ID,TrackRouting>> routes;NSDictionary *d=object(decoded);for(NSString *key in d)routes.push_back({str(key),readRouting(d[key])});_engine->setTrackRouting(routes);return YES;}catch(const std::exception& e){report(error,e);return NO;}
}
- (BOOL)setOutputPatches:(NSString*)track data:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:error]; if (!decoded) return NO;
    try { _engine->setOutputPatches(str(track), readPatches(decoded)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)setOutputPatch:(NSString*)track first:(int)first count:(int)count slot:(int)slot error:(NSError**)error {
    try { _engine->setOutputPatch(str(track), first, count, slot); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)groupTracks:(NSArray<NSString*>*)identifiers error:(NSError**)error {
    try { std::vector<ID> ids; for (NSString* identifier in identifiers) ids.push_back(str(identifier)); _engine->groupTracks(ids); return YES; }
    catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)reorderTrack:(NSString*)track before:(NSString*)before error:(NSError**)error {
    try { _engine->reorderTrack(str(track), str(before)); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (void)advance:(double)elapsed { _engine->advance(elapsed); }
- (void)finishCurrentSong:(BOOL)enabled { _engine->finishCurrentSong(enabled); }
- (NSString*)classifyFilename:(NSString*)filename { return text(_taxonomy.classify(str(filename)).id); }
@end

#include <array>
#include <atomic>
@implementation JarasMeterBank {
    std::array<std::atomic<float>, 1024> _peaks;
}
- (instancetype)init { if ((self = [super init])) for(auto& peak : _peaks) peak.store(0); return self; }
- (void)recordPeak:(float)value slot:(NSUInteger)slot {
    if(slot >= _peaks.size()) return;
    float old = _peaks[slot].load(std::memory_order_relaxed);
    while(value > old && !_peaks[slot].compare_exchange_weak(old, value, std::memory_order_relaxed)) {}
}
- (float)takePeak:(NSUInteger)slot { return slot < _peaks.size() ? _peaks[slot].exchange(0, std::memory_order_relaxed) : 0; }
@end
