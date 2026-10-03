#import <Foundation/Foundation.h>
#import "../../Apple/Bridge/JarasCoreBridge.h"
#include <iostream>
#include <limits>
#include <stdexcept>
static void expect(bool ok,const char* message){if(!ok) throw std::runtime_error(message);}
static bool equalJSON(id a,id b) {
    if([a isKindOfClass:NSNumber.class] && [b isKindOfClass:NSNumber.class]) return std::abs([a doubleValue]-[b doubleValue])<1e-12;
    if([a isKindOfClass:NSArray.class] && [b isKindOfClass:NSArray.class]) { if([a count]!=[b count]) return false; for(NSUInteger i=0;i<[a count];++i) if(!equalJSON(a[i],b[i])) return false; return true; }
    if([a isKindOfClass:NSDictionary.class] && [b isKindOfClass:NSDictionary.class]) { if([a count]!=[b count]) return false; for(id key in a) if(!b[key] || !equalJSON(a[key],b[key])) return false; return true; }
    return [a isEqual:b];
}
static void expectMetadataSnapshot(JarasCoreBridge* core, NSDictionary* full) {
    NSError* error=nil;
    NSData* encoded=[core metadataSnapshotWithError:&error];
    expect(encoded!=nil && error==nil,"metadata snapshot serializes without touching waveform data");
    NSDictionary* metadata=[NSJSONSerialization JSONObjectWithData:encoded options:0 error:&error];
    NSMutableDictionary* expected=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:full options:0 error:&error] options:NSJSONReadingMutableContainers error:&error];
    for(NSMutableDictionary* song in expected[@"project"][@"songs"]) for(NSMutableDictionary* track in song[@"tracks"]) for(NSMutableDictionary* clip in track[@"clips"]) {
        clip[@"waveform"]=@[]; clip[@"waveformChannels"]=@[];
    }
    expect(equalJSON(expected,metadata),"metadata retains all project fields, clip settings and both running transport heads; only waveform arrays differ");
    for(NSDictionary* song in metadata[@"project"][@"songs"]) for(NSDictionary* track in song[@"tracks"]) for(NSDictionary* clip in track[@"clips"]) {
        expect([clip[@"waveform"] isKindOfClass:NSArray.class] && [clip[@"waveform"] count]==0,"metadata emits an empty main waveform array for every item");
        expect([clip[@"waveformChannels"] isKindOfClass:NSArray.class] && [clip[@"waveformChannels"] count]==0,"metadata emits an empty channel waveform array for every item");
    }
    NSDictionary* unchanged=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(full,unchanged),"reading metadata never strips stored waveforms or changes playback");
}
int main(int argc,char**argv){@autoreleasepool{
    expect(argc==2,"fixture required");
    NSData* input=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]]; NSError* error=nil;
    JarasCoreBridge* core=[JarasCoreBridge new]; expect([core loadProjectData:input error:&error],"load bridge");
    NSDictionary* original=[NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
    NSDictionary* snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(original,snapshot[@"project"]),"bridge round trip preserves all fields and clips");
    expectMetadataSnapshot(core,snapshot);
    expect([core executeCommand:@"solo" target:nil value:0 error:&error], "Master solo is a native mixer command");
    NSString* phaseTrack=original[@"songs"][0][@"tracks"][0][@"id"];
    expect([core executeCommand:@"phase" target:nil value:0 error:&error],"Master phase command");
    expect([core executeCommand:@"phase" target:phaseTrack value:0 error:&error],"track phase command");

    expect([core editMasterColor:0x12ab34 error:&error], "edit Master color incrementally");
    NSDictionary* masterEdited=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(![masterEdited[@"project"][@"masterPhaseInverted"] boolValue] && [masterEdited[@"project"][@"songs"][0][@"tracks"][0][@"phaseInverted"] boolValue],"phase is available only on tracks");
    expect([masterEdited[@"project"][@"masterSolo"] boolValue] && [masterEdited[@"project"][@"masterColor"] unsignedIntValue]==0x12ab34, "Master solo and color persist in snapshots");
    expect(equalJSON(snapshot[@"transport"],masterEdited[@"transport"]), "Master mixer changes preserve both transport heads");
    NSData* masterSaved=[NSJSONSerialization dataWithJSONObject:masterEdited[@"project"] options:0 error:&error];
    expect([core loadProjectData:masterSaved error:&error], "reload Master mixer settings");
    NSDictionary* masterReloaded=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(masterEdited[@"project"],masterReloaded[@"project"]), "Master mixer settings survive native project round trip");
    error=nil;
    expect(![core editMasterColor:0x1000000 error:&error] && error!=nil, "reject invalid Master color");
    NSDictionary* masterRejected=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(masterReloaded,masterRejected), "invalid Master color is atomic");
    error=nil; expect([core loadProjectData:input error:&error], "restore original project after Master tests");
    NSString* regionID = original[@"songs"][0][@"parts"][0][@"id"];
    NSString* pitchTrack = original[@"songs"][0][@"tracks"][0][@"id"];
    expect([core setRegionPitch:regionID semitones:-3 tracks:@[pitchTrack] groups:@[] error:&error], "incremental pitch mutation through native bridge");
    NSDictionary* pitched = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect([pitched[@"project"][@"songs"][0][@"parts"][0][@"pitchSemitones"] intValue] == -3, "native pitch value persists");
    expect(equalJSON(snapshot[@"transport"], pitched[@"transport"]), "pitch edit preserves the transport");
    expect(equalJSON(original[@"songs"][0][@"parts"][1], pitched[@"project"][@"songs"][0][@"parts"][1]), "pitch edit preserves other songs");
    expect([core loadProjectData:input error:&error], "restore round trip fixture");
    NSMutableDictionary* stopList = [original[@"regionSetlist"] mutableCopy];
    stopList[@"stopAtRegionEnd"] = @YES;
    stopList[@"prepareWithoutPlayback"] = @YES;
    stopList[@"automaticSubplay"] = @YES; stopList[@"automaticSubplaySeconds"] = @3;
    expect([core configureRegionSetlistData:[NSJSONSerialization dataWithJSONObject:stopList options:0 error:&error] error:&error], "enable region Stop through bridge");
    NSDictionary* stopSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect([stopSnapshot[@"project"][@"regionSetlist"][@"automaticSubplay"] boolValue] && [stopSnapshot[@"project"][@"regionSetlist"][@"automaticSubplaySeconds"] doubleValue] == 3, "automatic subplay settings survive native serialization");
    expect([stopSnapshot[@"project"][@"regionSetlist"][@"prepareWithoutPlayback"] boolValue], "prepare without playback survives native serialization");
    expect([stopSnapshot[@"project"][@"regionSetlist"][@"stopAtRegionEnd"] boolValue], "region Stop survives native serialization");
    expect([core configureRegionSetlistData:[NSJSONSerialization dataWithJSONObject:original[@"regionSetlist"] options:0 error:&error] error:&error], "restore disabled region Stop");
    NSString* midiTrack=original[@"songs"][0][@"tracks"][0][@"id"];
    expect([core setMIDIInput:midiTrack slot:2 error:&error],"select MIDI slot");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect([snapshot[@"project"][@"songs"][0][@"tracks"][0][@"midiInput"] intValue]==2,"MIDI slot persists in snapshot");
    expect(![core setMIDIInput:midiTrack slot:4 error:&error],"reject fourth MIDI slot");
    expect([core setMIDIInput:midiTrack slot:0 error:&error],"clear MIDI slot");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(snapshot[@"project"][@"songs"][0][@"tracks"][0][@"midiInput"]==nil,"cleared MIDI slot absent");
    expect([core executeCommand:@"play" target:nil value:0 error:&error],"main play");
    [core executeCommand:@"subSeek" target:nil value:20 error:&error]; [core executeCommand:@"subPlay" target:nil value:0 error:&error]; [core advance:2];
    NSDictionary* playback=[NSJSONSerialization JSONObjectWithData:[core playbackSnapshotWithError:&error] options:0 error:&error];
    expect([playback[@"transport"][@"position"] doubleValue]==2,"main position");
    expect([playback[@"transport"][@"subPlay"][@"position"] doubleValue]==22,"secondary independent position");
    NSString* gainClipID=original[@"songs"][0][@"tracks"][0][@"clips"][0][@"id"];
    expect([core executeCommand:@"clipGain" target:gainClipID value:0.25 error:&error],"set item gain without project serialization");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect([snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0][@"gain"] doubleValue]==0.25,"item gain reaches bridge snapshot");
    expect([snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0][@"muted"] boolValue],"item gain preserves clip mute");
    expect(equalJSON(snapshot[@"transport"],playback[@"transport"]),"item gain preserves the entire live transport");
    expectMetadataSnapshot(core,snapshot);
    for(double invalid : {-0.01,std::pow(10.0,24.0/20.0)+0.01,std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::infinity()}) {
        error=nil;
        expect(![core executeCommand:@"clipGain" target:gainClipID value:invalid error:&error] && error!=nil,"invalid item gain is reported");
        NSDictionary* unchanged=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        expect(equalJSON(snapshot,unchanged),"invalid item gain leaves full bridge state unchanged");
    }
    error=nil;
    expect(![core executeCommand:@"clipGain" target:@"missing" value:0.5 error:&error],"unknown item gain target rejected");
    NSDictionary* gainAfterUnknown=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(snapshot,gainAfterUnknown),"unknown item gain target is atomic");
    NSMutableDictionary* itemFX = [original[@"songs"][0][@"tracks"][0][@"clips"][0][@"fx"] mutableCopy];
    itemFX[@"delayEnabled"] = @YES; itemFX[@"delayMix"] = @35;
    itemFX[@"inserted"] = @[@"EQ", @"Delay", @"Reverb"];
    error = nil;
    expect([core setClipFX:gainClipID data:[NSJSONSerialization dataWithJSONObject:itemFX options:0 error:&error] error:&error], "set effects directly on an item");
    NSDictionary* withItemFX = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSMutableDictionary* expectedClip = [snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0] mutableCopy];
    expectedClip[@"fx"] = itemFX;
    expect(equalJSON(expectedClip, withItemFX[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0]), "item FX setter preserves gain, waveform, mute, loop, rate and source metadata");
    expect(equalJSON(snapshot[@"transport"], withItemFX[@"transport"]), "item FX leaves both playback heads unchanged");
    expect(withItemFX[@"project"][@"songs"][0][@"tracks"][0][@"fx"] == nil, "item FX does not insert a track effect");
    NSArray* invalidItemEffects = @[
        @{@"inserted": @[@"Instruments"]}, @{@"inserted": @[@"Unknown"]}, @{@"inserted": @[@"EQ", @"EQ"]},
        @{@"inserted": @[], @"instrumentID": @"Piano"}, @{@"inserted": @[], @"instrumentParameters": @{}},
        @{@"inserted": @[], @"instrumentBypassed": @YES}
    ];
    for (NSDictionary* invalid in invalidItemEffects) {
        error = nil;
        expect(![core setClipFX:gainClipID data:[NSJSONSerialization dataWithJSONObject:invalid options:0 error:&error] error:&error] && error != nil, "item FX rejects instruments and unknown effect types");
        NSDictionary* unchangedFX = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        expect(equalJSON(withItemFX, unchangedFX), "rejected item FX leaves project and transport unchanged");
    }
    error = nil;
    expect(![core setClipFX:gainClipID data:[@"{invalid" dataUsingEncoding:NSUTF8StringEncoding] error:&error], "malformed item FX rejected");
    expect(![core setClipFX:@"missing" data:[NSJSONSerialization dataWithJSONObject:itemFX options:0 error:&error] error:&error], "unknown item FX rejected");
    snapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(withItemFX, snapshot), "malformed or missing-target item FX is atomic");
    for (NSNumber* bypassed in @[@YES, @NO, @YES]) {
        NSDictionary* beforeBypass = snapshot;
        expect([core setClipFXBypass:gainClipID bypassed:bypassed.boolValue error:&error], "global item FX bypass uses scalar native setter");
        snapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        NSMutableDictionary* bypassedClip = [beforeBypass[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0] mutableCopy];
        bypassedClip[@"fxBypassed"] = bypassed;
        expect(equalJSON(bypassedClip, snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0]), "global bypass retains individual FX flags, gain and complete clip metadata; false remains persisted");
        expect(equalJSON(beforeBypass[@"transport"], snapshot[@"transport"]), "global bypass preserves both running playback heads");
    }
    error = nil;
    expect(![core setClipFXBypass:@"missing" bypassed:NO error:&error] && error != nil, "unknown global bypass target rejected");
    NSDictionary* bypassAfterUnknown = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(snapshot, bypassAfterUnknown), "unknown global bypass mutation is atomic");
    NSString* tempoID=NSUUID.UUID.UUIDString;
    expect([core setTempoMarker:tempoID position:8 bpm:180 beats:3 unit:8 timebase:@"global" error:&error], "create tempo marker without replacing the project");
    NSDictionary* tempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSDictionary* tempoMarker=[tempoSnapshot[@"project"][@"songs"][0][@"markers"] lastObject];
    expect([tempoMarker[@"tempoBPM"] doubleValue]==180 && [tempoMarker[@"tempoBeats"] intValue]==3 && [tempoMarker[@"tempoUnit"] intValue]==8, "tempo marker BPM and meter survive bridge snapshot");
    expect(equalJSON(snapshot[@"transport"],tempoSnapshot[@"transport"]), "tempo marker preserves both playback heads");
    expect([tempoMarker[@"tempoTimebase"] isEqual:@"global"], "new tempo marker follows global timebase");
    expect(![core setTempoMarker:tempoID position:8 bpm:301 beats:3 unit:8 timebase:@"global" error:&error], "reject out-of-range marker tempo");
    NSDictionary* badTempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(tempoSnapshot,badTempoSnapshot), "invalid tempo marker is atomic");
    for (NSString* mode in @[@"free", @"relative", @"global"]) {
        expect([core setTempoMarker:tempoID position:8 bpm:180 beats:3 unit:8 timebase:mode error:&error], "edit marker-specific timebase incrementally");
        tempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        expect([[tempoSnapshot[@"project"][@"songs"][0][@"markers"] lastObject][@"tempoTimebase"] isEqual:mode], "marker timebase survives bridge snapshot");
        NSMutableDictionary* expectedTransport=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:snapshot[@"transport"] options:0 error:&error] options:NSJSONReadingMutableContainers error:&error];
        // Relative tempo resizes occupied spans after 8 s, keeping the 8 s gap.
        // The main head at 2 s stays put; the secondary head follows the music.
        expectedTransport[@"subPlay"][@"position"] = [mode isEqual:@"relative"] ? @19.2 : @22;
        expect(equalJSON(expectedTransport,tempoSnapshot[@"transport"]), "timebase edit keeps playing state and retimes the secondary head with occupied audio");
    }
    for (double position : {8.137875, 7.932125}) {
        error=nil;
        expect([core setTempoMarker:tempoID position:position bpm:180 beats:3 unit:8 timebase:@"global" error:&error], "move tempo marker freely in either direction");
        tempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        NSDictionary* moved=[[tempoSnapshot[@"project"][@"songs"] firstObject][@"markers"] lastObject];
        expect(std::abs([moved[@"position"] doubleValue]-position)<1e-12, "tempo drag must retain exact fractional positions without beat snapping");
        expect(equalJSON(snapshot[@"transport"],tempoSnapshot[@"transport"]), "moving tempo markers cannot move either playback head");
    }
    expect(![core setTempoMarker:tempoID position:8 bpm:180 beats:3 unit:8 timebase:@"invalid" error:&error], "reject invalid marker timebase");
    badTempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(tempoSnapshot,badTempoSnapshot), "invalid marker timebase is atomic");
    NSMutableDictionary* detectedTempo = [[tempoSnapshot[@"project"][@"songs"][0][@"markers"] lastObject] mutableCopy];
    detectedTempo[@"tempoReferenceBPM"] = @120;
    NSData* detectedBatch = [NSJSONSerialization dataWithJSONObject:@[detectedTempo] options:0 error:&error];
    expect([core setTempoMarkers:detectedBatch error:&error], "detected marker batch accepts original tempo reference");
    expect([core setTempoMarker:tempoID position:8 bpm:240 beats:4 unit:4 timebase:@"global" error:&error], "detected BPM remains editable");
    tempoSnapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSDictionary* editedDetected = [tempoSnapshot[@"project"][@"songs"][0][@"markers"] lastObject];
    expect([editedDetected[@"tempoReferenceBPM"] doubleValue] == 120, "BPM edit retains original reference through native bridge");
    NSData* tempoData=[NSJSONSerialization dataWithJSONObject:tempoSnapshot[@"project"] options:0 error:&error];
    JarasCoreBridge* tempoCore=[JarasCoreBridge new];
    expect([tempoCore loadProjectData:tempoData error:&error], "reload tempo marker metadata");
    NSDictionary* tempoReloaded=[NSJSONSerialization JSONObjectWithData:[tempoCore snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(tempoSnapshot[@"project"],tempoReloaded[@"project"]), "tempo map project round trip");
    NSString* correctedTempoID = NSUUID.UUID.UUIDString;
    NSDictionary* correctedTempo = @{@"id":correctedTempoID,@"name":@"TEMPO",@"position":@7.9,@"tempoBPM":@140,@"tempoBeats":@4,@"tempoUnit":@4,@"tempoTimebase":@"global",@"tempoReferenceBPM":@140};
    NSData* correctedData = [NSJSONSerialization dataWithJSONObject:@[correctedTempo] options:0 error:&error];
    expect([tempoCore setTempoMarkers:correctedData removing:@[tempoID] error:&error], "redetection atomically replaces old detected marker");
    NSDictionary* correctedSnapshot = [NSJSONSerialization JSONObjectWithData:[tempoCore snapshotWithError:&error] options:0 error:&error];
    NSArray* correctedMarkers = correctedSnapshot[@"project"][@"songs"][0][@"markers"];
    expect(![correctedMarkers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", tempoID]].count, "wrong marker is gone");
    expect([correctedMarkers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", correctedTempoID]].count == 1, "one corrected marker exists");
    expect(equalJSON(tempoReloaded[@"project"][@"songs"][0][@"tracks"], correctedSnapshot[@"project"][@"songs"][0][@"tracks"]), "redetect leaves audio positions and rates intact");
    expect(equalJSON(tempoReloaded[@"project"][@"songs"][0][@"timeSettings"] ?: NSNull.null, correctedSnapshot[@"project"][@"songs"][0][@"timeSettings"] ?: NSNull.null), "redetect restores project timebase");
    expect([core deleteManualMarker:tempoID error:&error], "delete tempo marker");
    NSString* markerID=NSUUID.UUID.UUIDString;
    expect([core setMarker:markerID name:@"Entrada" position:18 color:0x00ff88 error:&error],"create marker");
    expect([core setMarker:markerID name:@"Refrão" position:19 color:0xffcc00 error:&error],"edit marker");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSArray* markers=snapshot[@"project"][@"songs"][0][@"markers"];
    expect(markers.count==2 && [markers.lastObject[@"name"] isEqual:@"Refrão"],"marker upsert preserves existing markers");
    expect([snapshot[@"transport"][@"position"] doubleValue]==2 && [snapshot[@"transport"][@"playing"] boolValue],"marker editing preserves transport");
    expect(![core setMarker:markerID name:@"Invalid" position:-1 color:0 error:&error],"reject invalid marker");
    NSDictionary* afterInvalid=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(snapshot,afterInvalid),"invalid marker is atomic");
    expect([core deleteManualMarker:markerID error:&error], "delete manual marker through native bridge");
    NSDictionary* afterMarkerDelete = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect([afterMarkerDelete[@"project"][@"songs"][0][@"markers"] count] == 1, "deletion preserves the other manual marker");
    expect(equalJSON(snapshot[@"transport"], afterMarkerDelete[@"transport"]), "deletion preserves both playback cursors");
    expect(equalJSON(snapshot[@"project"][@"songs"][0][@"tracks"], afterMarkerDelete[@"project"][@"songs"][0][@"tracks"]), "deletion preserves items, waveforms and routing");

    NSString* identifier=NSUUID.UUID.UUIDString;
    expect([core addTrackWithId:identifier name:@"Nova pista" role:@"keys" error:&error],"create track while transport active");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSArray* tracks=snapshot[@"project"][@"songs"][0][@"tracks"];
    expect([tracks.lastObject[@"id"] isEqual:identifier],"new track follows last track");
    NSMutableDictionary* imported=[tracks[0] mutableCopy];
    imported[@"id"]=NSUUID.UUID.UUIDString; imported[@"name"]=@"Dropped audio";
    NSMutableArray* clips=[NSMutableArray new];
    for(NSDictionary* clip in imported[@"clips"]) { NSMutableDictionary* copy=[clip mutableCopy]; copy[@"id"]=NSUUID.UUID.UUIDString; [clips addObject:copy]; }
    imported[@"clips"]=clips;
    NSData* batch=[NSJSONSerialization dataWithJSONObject:@[imported] options:0 error:&error];
    expect([core insertAudioTracks:batch song:original[@"songs"][0][@"id"] error:&error],"import audio through bridge");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON([snapshot[@"project"][@"songs"][0][@"tracks"] lastObject],imported),"audio import preserves complete track and clip metadata");
    expect([snapshot[@"transport"][@"playing"] boolValue],"import preserves playback");
    NSMutableDictionary* recorded = [snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0] mutableCopy];
    recorded[@"id"] = NSUUID.UUID.UUIDString; recorded[@"recordingLane"] = @4;
    recorded[@"startTime"] = @32; recorded[@"duration"] = @8;
    NSMutableDictionary* recordedSource = [recorded[@"audioFile"] mutableCopy];
    recordedSource[@"sha256"] = [@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]; recorded[@"audioFile"] = recordedSource;
    expect([core addRecordedClip:[NSJSONSerialization dataWithJSONObject:recorded options:0 error:&error] track:midiTrack error:&error], "recorded clip insertion accepts complete item settings");
    snapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON([snapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"] lastObject], recorded), "recorded clip path preserves FX, gain, mute, stereo, loops, offsets, rate and source hash");
    expect(equalJSON(snapshot[@"transport"], playback[@"transport"]), "recorded clip FX insertion preserves both live playback heads");
    NSString* timecodeTrackID = NSUUID.UUID.UUIDString;
    expect([core addTrackWithId:timecodeTrackID name:@"Timecode" role:@"timecode" error:&error], "create derived Timecode track through bridge");
    NSMutableDictionary* timecodeEdit = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:NSJSONReadingMutableContainers error:&error];
    NSMutableDictionary* timecodeClip = timecodeEdit[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0];
    NSString* timecodeClipID = timecodeClip[@"id"];
    timecodeClip[@"timecodeStartOffset"] = @1; timecodeClip[@"timecodeEndOffset"] = @5;
    expect([core applyProjectEditData:[NSJSONSerialization dataWithJSONObject:timecodeEdit[@"project"] options:0 error:&error] error:&error], "Timecode span offsets cross native project edit bridge");
    NSDictionary* timecodeSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSDictionary* editedTimecodeClip = timecodeSnapshot[@"project"][@"songs"][0][@"tracks"][0][@"clips"][0];
    expect([editedTimecodeClip[@"startTime"] doubleValue] == 1 && [editedTimecodeClip[@"duration"] doubleValue] == 16 && [editedTimecodeClip[@"timecodeStartOffset"] doubleValue] == 1 && [editedTimecodeClip[@"timecodeEndOffset"] doubleValue] == 5, "native Timecode offsets preserve editable edges and derived identity");
    expect(equalJSON(timecodeSnapshot[@"transport"], timecodeEdit[@"transport"]), "Timecode edit preserves both live clocks");
    JarasCoreBridge* reloadedTimecode = [JarasCoreBridge new];
    expect([reloadedTimecode loadProjectData:[NSJSONSerialization dataWithJSONObject:timecodeSnapshot[@"project"] options:0 error:&error] error:&error], "saved Timecode offsets load through bridge");
    NSDictionary* reloadedSnapshot = [NSJSONSerialization JSONObjectWithData:[reloadedTimecode snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(timecodeSnapshot[@"project"], reloadedSnapshot[@"project"]), "Timecode persisted edge edits survive load and native synchronization");
    expect(![core regionsFromClips:@[timecodeClipID] identifiers:@[NSUUID.UUID.UUIDString] error:&error], "Timecode item cannot create a new region through native API");
    expect(![core setClipFX:timecodeClipID data:[NSJSONSerialization dataWithJSONObject:itemFX options:0 error:&error] error:&error], "Timecode item cannot receive item FX");
    expect(![core setClipFXBypass:timecodeClipID bypassed:YES error:&error], "Timecode item cannot receive global item FX bypass");
    NSDictionary* timecodeAfterRejected = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(timecodeSnapshot, timecodeAfterRejected), "Timecode forbidden commands leave project and transport unchanged");
    NSString* chordsTrackID = NSUUID.UUID.UUIDString;
    expect([core addTrackWithId:chordsTrackID name:@"Ignored" role:@"chords" error:&error], "create a persisted Chords track through native bridge");
    NSString* textItemID = NSUUID.UUID.UUIDString;
    NSDictionary* textItem = @{@"id":textItemID, @"name":@"Chords", @"startTime":@4, @"duration":@10, @"sourceOffset":@0, @"playbackRate":@1, @"waveform":@[], @"text":@"C♯m / G♭ — Refrão 🎵"};
    expect([core addRecordedClip:[NSJSONSerialization dataWithJSONObject:textItem options:0 error:&error] track:chordsTrackID error:&error], "text clip uses the insert bridge without requiring audioFile");
    NSDictionary* textSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSDictionary* chordsTrack = nil;
    for (NSDictionary* track in textSnapshot[@"project"][@"songs"][0][@"tracks"]) if ([track[@"id"] isEqual:chordsTrackID]) chordsTrack = track;
    expect(equalJSON(chordsTrack[@"clips"][0], textItem), "text content persists independently of fixed item and track names");
    NSString* maximumEmoji = [@"" stringByPaddingToLength:60 withString:@"🎵" startingAtIndex:0];
    expect([core setClipText:textItemID text:maximumEmoji error:&error], "30 non-ASCII emoji are accepted through native scalar setter");
    NSDictionary* textEditedSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(textSnapshot[@"transport"], textEditedSnapshot[@"transport"]), "text edits preserve both active transport heads");
    expect(![core setClipText:textItemID text:[maximumEmoji stringByAppendingString:@"A"] error:&error], "Chords text above 30 Unicode scalars is rejected");
    expect(![core setClipText:gainClipID text:@"Invalid" error:&error] && ![core setClipText:@"missing" text:@"Invalid" error:&error], "text setter rejects wrong kind and missing target");
    NSDictionary* textRejectedSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(textEditedSnapshot, textRejectedSnapshot), "rejected text edits leave complete native state unchanged");
    JarasCoreBridge* reloadedText = [JarasCoreBridge new];
    expect([reloadedText loadProjectData:[NSJSONSerialization dataWithJSONObject:textEditedSnapshot[@"project"] options:0 error:&error] error:&error], "load a saved project containing Chords and Unicode text");
    NSDictionary* reloadedTextSnapshot = [NSJSONSerialization JSONObjectWithData:[reloadedText snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(textEditedSnapshot[@"project"], reloadedTextSnapshot[@"project"]), "native text and Chords persisted fields survive full project round trip");
    for (NSString* field in @[@"fxBypassed", @"text"]) {
        NSMutableDictionary* malformedOptional = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:textEditedSnapshot[@"project"] options:0 error:&error] options:NSJSONReadingMutableContainers error:&error];
        for (NSMutableDictionary* track in malformedOptional[@"songs"][0][@"tracks"]) if ([track[@"id"] isEqual:chordsTrackID]) track[@"clips"][0][field] = @2;
        expect(![core loadProjectData:[NSJSONSerialization dataWithJSONObject:malformedOptional options:0 error:&error] error:&error], "typed optional item fields reject numeric coercion on native load");
        NSDictionary* typedAfterRejected = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        expect(equalJSON(textEditedSnapshot, typedAfterRejected), "invalid optional field types leave project and both clocks intact");
    }
    const unichar textCharacters[] = {'A', 0, 'B'};
    NSString* embeddedNullText = [[NSString alloc] initWithCharacters:textCharacters length:3];
    expect([core setClipText:textItemID text:embeddedNullText error:&error], "bounded Unicode text setter retains embedded NUL without C-string truncation");
    NSDictionary* nullTextSnapshot = [NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    for (NSDictionary* track in nullTextSnapshot[@"project"][@"songs"][0][@"tracks"]) if ([track[@"id"] isEqual:chordsTrackID]) expect([track[@"clips"][0][@"text"] isEqual:embeddedNullText], "text snapshot preserves every Unicode scalar including NUL");
    expect([reloadedText loadProjectData:[NSJSONSerialization dataWithJSONObject:nullTextSnapshot[@"project"] options:0 error:&error] error:&error], "full project load retains embedded NUL text");
    NSDictionary* nullTextReloaded = [NSJSONSerialization JSONObjectWithData:[reloadedText snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(nullTextSnapshot[@"project"], nullTextReloaded[@"project"]), "text containing embedded NUL round trips through native codecs");
    expectMetadataSnapshot(core,nullTextSnapshot);
    NSMutableDictionary* metadataEdit=[NSJSONSerialization JSONObjectWithData:[core metadataSnapshotWithError:&error] options:NSJSONReadingMutableContainers error:&error];
    NSMutableArray<NSString*>* preserved=[NSMutableArray new];
    for(NSDictionary* song in metadataEdit[@"project"][@"songs"]) for(NSDictionary* track in song[@"tracks"]) for(NSDictionary* clip in track[@"clips"]) [preserved addObject:clip[@"id"]];
    expect([core applyProjectMetadataEditData:[NSJSONSerialization dataWithJSONObject:metadataEdit[@"project"] options:0 error:&error] preservingWaveforms:preserved error:&error],"metadata structural edit reattaches existing validated waveforms by item ID");
    NSDictionary* afterMetadataEdit=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(nullTextSnapshot,afterMetadataEdit),"metadata edit retains every original waveform, all item fields and both playback heads without reload");
    for(NSArray<NSString*>* invalid in @[@[@"missing"], @[preserved[0],preserved[0]]]) {
        error=nil;
        expect(![core applyProjectMetadataEditData:[NSJSONSerialization dataWithJSONObject:metadataEdit[@"project"] options:0 error:&error] preservingWaveforms:invalid error:&error] && error!=nil,"unknown and duplicate preserved waveform IDs reject atomically");
        NSDictionary* unchangedMetadata=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
        expect(equalJSON(afterMetadataEdit,unchangedMetadata),"invalid metadata waveform references never modify native project or playback");
    }
    NSMutableDictionary* absentEdit=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:metadataEdit[@"project"] options:0 error:&error] options:NSJSONReadingMutableContainers error:&error];
    for(NSMutableDictionary* song in absentEdit[@"songs"]) for(NSMutableDictionary* track in song[@"tracks"]) {
        NSMutableArray* clips=track[@"clips"];
        for(NSInteger i=(NSInteger)clips.count-1;i>=0;--i) if([clips[i][@"id"] isEqual:preserved[0]]) [clips removeObjectAtIndex:(NSUInteger)i];
    }
    error=nil;
    expect(![core applyProjectMetadataEditData:[NSJSONSerialization dataWithJSONObject:absentEdit options:0 error:&error] preservingWaveforms:@[preserved[0]] error:&error] && error!=nil,"a retained waveform cannot reference an item removed from the candidate edit");
    NSDictionary* afterAbsentEdit=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(afterMetadataEdit,afterAbsentEdit),"missing candidate item is atomic");
    expect(![core executeCommand:@"invalid" target:nil value:0 error:&error] && error!=nil,"invalid command reported");
    NSMutableDictionary* unifiedProject = [NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingMutableContainers error:&error];
    [unifiedProject removeObjectForKey:@"regionSetlist"];
    NSMutableDictionary* unifiedSong = unifiedProject[@"songs"][0];
    NSString* groupID = NSUUID.UUID.UUIDString;
    NSString* firstSongID = NSUUID.UUID.UUIDString;
    NSString* secondSongID = NSUUID.UUID.UUIDString;
    NSString* unifiedMarkerID = NSUUID.UUID.UUIDString;
    unifiedSong[@"parts"] = @[@{@"id":firstSongID,@"name":@"First original song name",@"startTime":@10,@"endTime":@40,@"parentRegionID":groupID},
                              @{@"id":secondSongID,@"name":@"Second",@"startTime":@30,@"endTime":@60,@"parentRegionID":groupID},
                              @{@"id":groupID,@"name":@"Unified",@"startTime":@10,@"endTime":@60}];
    unifiedSong[@"markers"] = @[@{@"id":unifiedMarkerID,@"name":@"First original song name",@"position":@10,@"color":@0xffdc52,@"unifiedRegionID":groupID,@"sourceRegionID":firstSongID}];
    JarasCoreBridge* unifiedCore = [JarasCoreBridge new];
    error = nil; BOOL unifiedLoaded = [unifiedCore loadProjectData:[NSJSONSerialization dataWithJSONObject:unifiedProject options:0 error:&error] error:&error];
    if (!unifiedLoaded) NSLog(@"Unified load: %@", error);
    expect(unifiedLoaded, "load unified songs through native bridge");
    NSDictionary* unifiedSnapshot = [NSJSONSerialization JSONObjectWithData:[unifiedCore snapshotWithError:&error] options:0 error:&error];
    expect([unifiedSnapshot[@"project"][@"songs"][0][@"parts"][0][@"parentRegionID"] isEqual:groupID], "unified drawer owner survives native serialization");
    expect([unifiedSnapshot[@"project"][@"songs"][0][@"markers"][0][@"unifiedRegionID"] isEqual:groupID], "generated marker owner survives native serialization");
    expect([unifiedSnapshot[@"project"][@"songs"][0][@"markers"][0][@"sourceRegionID"] isEqual:firstSongID], "generated marker retains its original song identity through bridge");
    expect(![unifiedCore deleteManualMarker:unifiedMarkerID error:&error], "native bridge refuses to delete unified song markers");
    NSDictionary* protectedMarkerSnapshot = [NSJSONSerialization JSONObjectWithData:[unifiedCore snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(unifiedSnapshot, protectedMarkerSnapshot), "protected marker rejection changes nothing");
    expect([unifiedCore moveRegion:groupID start:50 error:&error], "move entire unified region through bridge");
    NSDictionary* movedUnified = [NSJSONSerialization JSONObjectWithData:[unifiedCore snapshotWithError:&error] options:0 error:&error];
    expect([movedUnified[@"project"][@"songs"][0][@"parts"][0][@"startTime"] doubleValue] == 50 && [movedUnified[@"project"][@"songs"][0][@"parts"][1][@"startTime"] doubleValue] == 70, "both drawer songs move with their parent");
    expect([movedUnified[@"project"][@"songs"][0][@"markers"][0][@"position"] doubleValue] == 50, "generated marker moves with its parent through bridge");
    expect(![unifiedCore moveRegion:firstSongID start:60 error:&error], "drawer song move rejects through bridge");
    JarasCoreBridge *routeCore=[JarasCoreBridge new];
    expect([routeCore loadProjectData:input error:&error], "load routing fixture");
    NSString *source=original[@"songs"][0][@"tracks"][0][@"id"],*destination=original[@"songs"][0][@"tracks"][2][@"id"];
    NSDictionary *routes=@{source:@{@"receives":@[NSNull.null,NSNull.null],@"transmitters":@[destination,NSNull.null]},destination:@{@"receives":@[source,NSNull.null],@"transmitters":@[NSNull.null,NSNull.null]}};
    expect([routeCore setTrackRouting:[NSJSONSerialization dataWithJSONObject:routes options:0 error:&error] error:&error], "set dual Receive and Transmitter natively");
    NSDictionary *routed=[NSJSONSerialization JSONObjectWithData:[routeCore metadataSnapshotWithError:&error] options:0 error:&error];
    expect([routed[@"project"][@"songs"][0][@"tracks"][0][@"routing"][@"transmitters"][0] isEqual:destination], "transmitter survives native snapshot");
    NSDictionary *cycle=@{destination:@{@"receives":@[source,NSNull.null],@"transmitters":@[source,NSNull.null]}};
    expect(![routeCore setTrackRouting:[NSJSONSerialization dataWithJSONObject:cycle options:0 error:&error] error:&error], "native routing rejects feedback before mutation");
    error=nil;
    NSDictionary *after=[NSJSONSerialization JSONObjectWithData:[routeCore metadataSnapshotWithError:&error] options:0 error:&error];
    expect([routed[@"project"] isEqual:after[@"project"]], "rejected native routing restores both slots");
    JarasMeterBank* bank=[JarasMeterBank new];
    [bank recordPeak:0.5f slot:1998]; [bank recordPeak:0.25f slot:1999];
    [bank recordPeak:0.75f slot:2000]; [bank recordPeak:1.0f slot:2001];
    expect([bank takePeak:1998]==0.5f && [bank takePeak:1999]==0.25f, "track 1000 has independent stereo meter slots");
    expect([bank takePeak:2000]==0.75f && [bank takePeak:2001]==1.0f, "Master meter does not collide with track 1000");
    // Imported Timecode must survive Swift -> native core -> metadata snapshot.
    NSMutableDictionary* importedTimecodeProject=[NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingMutableContainers error:&error];
    NSDictionary* tcSettings=@{@"mode":@"mtc",@"frameRate":@25,@"offset":@3602,@"regionRelative":@YES,@"midiDestination":@0};
    NSDictionary* tcClip=@{@"id":@"AA111111-1111-4111-8111-111111111111",@"name":@"MTC",@"startTime":@5,@"duration":@7,@"sourceOffset":@0,@"waveform":@[],@"timecode":tcSettings};
    NSDictionary* tcTrack=@{@"id":@"BB111111-1111-4111-8111-111111111111",@"name":@"Timecode",@"role":@"timecode",@"volume":@1,@"pan":@0,@"mute":@NO,@"solo":@NO,@"output":@1,@"importedTimecodeItems":@YES,@"timecode":tcSettings,@"clips":@[tcClip]};
    [importedTimecodeProject[@"songs"][0][@"tracks"] insertObject:tcTrack atIndex:0];
    JarasCoreBridge* migrated=[JarasCoreBridge new];
    expect([migrated loadProjectData:[NSJSONSerialization dataWithJSONObject:importedTimecodeProject options:0 error:&error] error:&error],"load imported Timecode");
    NSDictionary* migratedSnapshot=[NSJSONSerialization JSONObjectWithData:[migrated metadataSnapshotWithError:&error] options:0 error:&error];
    NSDictionary* tcResult=migratedSnapshot[@"project"][@"songs"][0][@"tracks"][0];
    expect([tcResult[@"importedTimecodeItems"] boolValue] && [tcResult[@"clips"] count]==1,"imported generator edges are not replaced by automatic region items");
    expect(equalJSON(tcResult[@"clips"][0][@"timecode"],tcSettings),"per-item Timecode settings survive metadata bridge");
    expect([tcResult[@"clips"][0][@"startTime"] doubleValue]==5 && [tcResult[@"clips"][0][@"duration"] doubleValue]==7,"generator position/duration survive native load");
    std::cout<<"JARAS_BRIDGE_OK\n";
}}
