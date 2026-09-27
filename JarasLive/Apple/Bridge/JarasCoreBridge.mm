#import "JarasCoreBridge.h"
#include "../../Core/Transport/Engine.hpp"
#include "../../Core/Import/TrackTaxonomy.hpp"
#include <memory>
#include <map>
#include <stdexcept>
using namespace jaras;
static std::string str(id value) { if (![value isKindOfClass:NSString.class]) throw std::invalid_argument("Expected text"); return [value UTF8String]; }
static NSString* text(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static NSArray* array(id value) { if (![value isKindOfClass:NSArray.class]) throw std::invalid_argument("Expected array"); return value; }
static NSDictionary* object(id value) { if (![value isKindOfClass:NSDictionary.class]) throw std::invalid_argument("Expected object"); return value; }
static double number(id value) { if (![value isKindOfClass:NSNumber.class]) throw std::invalid_argument("Expected number"); return [value doubleValue]; }
static id optionalID(const std::optional<ID>& value) { return value ? (id)text(*value) : NSNull.null; }
static NSDictionary* trackJSON(const Track& t) {
    NSMutableDictionary* d = [@{@"id":text(t.id), @"name":text(t.name), @"role":text(t.role.id), @"volume":@(t.volume), @"pan":@(t.pan), @"mute":@(t.mute), @"solo":@(t.solo), @"output":@(t.output)} mutableCopy];
    NSMutableArray* clips=[NSMutableArray new];
    for (const auto& clip:t.clips) { NSMutableArray* peaks=[NSMutableArray new]; for(double peak:clip.waveform) [peaks addObject:@(peak)]; [clips addObject:@{@"id":text(clip.id),@"name":text(clip.name),@"startTime":@(clip.startTime),@"duration":@(clip.duration),@"sourceOffset":@(clip.sourceOffset),@"waveform":peaks}]; }
    d[@"clips"]=clips;
    if (t.audioFile) { NSMutableDictionary* file = [@{@"path":text(t.audioFile->path)} mutableCopy]; if (t.audioFile->sha256) file[@"sha256"] = text(*t.audioFile->sha256); d[@"audioFile"] = file; }
    return d;
}
static NSDictionary* projectJSON(const Project& p) {
    NSMutableArray *songs = [NSMutableArray new], *setlists = [NSMutableArray new];
    for (const auto& s : p.songs) {
        NSMutableArray *tracks = [NSMutableArray new], *parts = [NSMutableArray new];
        for (const auto& t : s.tracks) [tracks addObject:trackJSON(t)];
        for (const auto& part : s.parts) [parts addObject:@{@"id":text(part.id),@"name":text(part.name),@"startTime":@(part.startTime),@"endTime":@(part.endTime)}];
        [songs addObject:@{@"id":text(s.id),@"name":text(s.name),@"duration":@(s.duration),@"bpm":@(s.bpm),@"tracks":tracks,@"parts":parts}];
    }
    for (const auto& s : p.setlists) { NSMutableArray* ids = [NSMutableArray new]; for (const auto& id : s.songIds) [ids addObject:text(id)]; [setlists addObject:@{@"id":text(s.id),@"name":text(s.name),@"songIds":ids}]; }
    return @{@"id":text(p.id),@"name":text(p.name),@"projectFormatVersion":@(p.projectFormatVersion),@"minimumJarasVersion":text(p.minimumJarasVersion),@"createdAt":text(p.createdAt),@"updatedAt":text(p.updatedAt),@"songs":songs,@"setlists":setlists};
}
static Project readProject(NSDictionary* d) {
    Project p; p.id=str(d[@"id"]); p.name=str(d[@"name"]); p.projectFormatVersion=number(d[@"projectFormatVersion"]); p.minimumJarasVersion=str(d[@"minimumJarasVersion"]); p.createdAt=str(d[@"createdAt"]); p.updatedAt=str(d[@"updatedAt"]);
    for (id rawSong in array(d[@"songs"])) {
        NSDictionary* sd=object(rawSong); Song s; s.id=str(sd[@"id"]); s.name=str(sd[@"name"]); s.duration=number(sd[@"duration"]); s.bpm=number(sd[@"bpm"]);
        for (id rawTrack in array(sd[@"tracks"])) {
            NSDictionary* td=object(rawTrack); Track t; t.id=str(td[@"id"]); t.name=str(td[@"name"]); t.role={str(td[@"role"])}; t.volume=number(td[@"volume"]); t.pan=number(td[@"pan"]); t.mute=number(td[@"mute"])!=0; t.solo=number(td[@"solo"])!=0; t.output=number(td[@"output"]);
            if (td[@"audioFile"] && td[@"audioFile"] != NSNull.null) { NSDictionary* f=object(td[@"audioFile"]); AudioFile file; file.path=str(f[@"path"]); if (f[@"sha256"] && f[@"sha256"]!=NSNull.null) file.sha256=str(f[@"sha256"]); t.audioFile=file; }
            for (id rawClip in array(td[@"clips"])) { NSDictionary* cd=object(rawClip); AudioClip clip; clip.id=str(cd[@"id"]); clip.name=str(cd[@"name"]); clip.startTime=number(cd[@"startTime"]); clip.duration=number(cd[@"duration"]); clip.sourceOffset=number(cd[@"sourceOffset"]); for(id peak in array(cd[@"waveform"])) clip.waveform.push_back(number(peak)); t.clips.push_back(std::move(clip)); }
            s.tracks.push_back(std::move(t));
        }
        for (id rawPart in array(sd[@"parts"])) { NSDictionary* part=object(rawPart); s.parts.push_back({str(part[@"id"]),str(part[@"name"]),number(part[@"startTime"]),number(part[@"endTime"])}); }
        p.songs.push_back(std::move(s));
    }
    for (id rawSet in array(d[@"setlists"])) { NSDictionary* sd=object(rawSet); Setlist s; s.id=str(sd[@"id"]); s.name=str(sd[@"name"]); for (id songId in array(sd[@"songIds"])) s.songIds.push_back(str(songId)); p.setlists.push_back(std::move(s)); }
    return p;
}
static void report(NSError** error, const std::exception& e) { if (error) *error = [NSError errorWithDomain:@"JarasLiveCore" code:1 userInfo:@{NSLocalizedDescriptionKey:text(e.what())}]; }
@implementation JarasCoreBridge { std::unique_ptr<Engine> _engine; TrackTaxonomy _taxonomy; }
- (instancetype)init { if ((self=[super init])) _engine=std::make_unique<Engine>(); return self; }
- (BOOL)loadProjectData:(NSData*)data error:(NSError**)error {
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:error]; if (!decoded) return NO;
    try { _engine->loadProject(readProject(object(decoded))); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (BOOL)executeCommand:(NSString*)command target:(NSString*)target value:(double)value error:(NSError**)error {
    static const std::map<std::string,CommandKind> commands={{"play",CommandKind::play},{"stop",CommandKind::stop},{"next",CommandKind::next},{"previous",CommandKind::previous},{"queue",CommandKind::queue},{"select",CommandKind::select},{"toggleLoop",CommandKind::toggleLoop},{"seek",CommandKind::seek},{"subPlay",CommandKind::subPlay},{"subStop",CommandKind::subStop},{"subSeek",CommandKind::subSeek},{"stopAll",CommandKind::stopAll},{"volume",CommandKind::volume},{"pan",CommandKind::pan},{"mute",CommandKind::mute},{"solo",CommandKind::solo}};
    try { auto found=commands.find(str(command)); if(found==commands.end()) throw std::invalid_argument("Unknown command"); _engine->execute({found->second,target?str(target):"",value}); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (NSData*)snapshotWithError:(NSError**)error {
    NSData* playback=[self playbackSnapshotWithError:error]; if(!playback) return nil;
    NSMutableDictionary* data=[[NSJSONSerialization JSONObjectWithData:playback options:0 error:error] mutableCopy];
    data[@"project"]=projectJSON(_engine->project());
    return [NSJSONSerialization dataWithJSONObject:data options:0 error:error];
}
- (NSData*)playbackSnapshotWithError:(NSError**)error {
    const auto& t=_engine->transport();
    NSDictionary* transport=@{@"playing":@(t.playing),@"songId":optionalID(t.songId),@"position":@(t.position),@"queue":@{@"songId":optionalID(t.queue.songId)},@"loop":@{@"enabled":@(t.loop.enabled)},@"subPlay":@{@"playing":@(t.subPlay.playing),@"position":@(t.subPlay.position)}};
    return [NSJSONSerialization dataWithJSONObject:@{@"transport":transport,@"nextSongId":optionalID(_engine->nextSongId())} options:0 error:error];
}
- (BOOL)addTrackWithId:(NSString*)identifier name:(NSString*)name role:(NSString*)role error:(NSError**)error {
    try { _engine->addTrack(str(identifier),str(name),{str(role)}); return YES; } catch(const std::exception& e) { report(error,e); return NO; }
}
- (void)advance:(double)elapsed { _engine->advance(elapsed); }
- (void)finishCurrentSong:(BOOL)enabled { _engine->finishCurrentSong(enabled); }
- (NSString*)classifyFilename:(NSString*)filename { return text(_taxonomy.classify(str(filename)).id); }
@end
