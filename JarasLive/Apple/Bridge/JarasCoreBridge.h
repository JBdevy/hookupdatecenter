#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasCoreBridge : NSObject
- (BOOL)applyProjectEditData:(NSData *)data error:(NSError **)error;
- (BOOL)applyProjectMetadataEditData:(NSData *)data preservingWaveforms:(NSArray<NSString *> *)identifiers error:(NSError **)error NS_SWIFT_NAME(applyProjectMetadataEdit(_:preservingWaveforms:));
- (BOOL)loadProjectData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(load(projectData:));
- (BOOL)executeCommand:(NSString *)command target:(nullable NSString *)target value:(double)value error:(NSError **)error NS_SWIFT_NAME(execute(command:target:value:));
- (nullable NSData *)snapshotWithError:(NSError **)error NS_SWIFT_NAME(snapshot());
- (nullable NSData *)metadataSnapshotWithError:(NSError **)error NS_SWIFT_NAME(metadataSnapshot());
- (nullable NSData *)playbackSnapshotWithError:(NSError **)error NS_SWIFT_NAME(playbackSnapshot());
- (BOOL)configureRegionSetlistData:(NSData *)data error:(NSError **)error;
- (BOOL)addTrackWithId:(NSString *)identifier name:(NSString *)name role:(NSString *)role error:(NSError **)error NS_SWIFT_NAME(addTrack(id:name:role:));
- (BOOL)resizeRegion:(NSString *)identifier start:(double)start end:(double)end error:(NSError **)error;
- (BOOL)moveRegion:(NSString *)identifier start:(double)start error:(NSError **)error;
- (BOOL)setFX:(NSString *)track data:(NSData *)data error:(NSError **)error;
- (BOOL)setClipFX:(NSString *)clip data:(NSData *)data error:(NSError **)error;
- (BOOL)setClipFXBypass:(NSString *)clip bypassed:(BOOL)bypassed error:(NSError **)error;
- (BOOL)setClipText:(NSString *)clip text:(NSString *)text error:(NSError **)error;
- (BOOL)setTimecode:(NSString *)track data:(NSData *)data error:(NSError **)error;
- (BOOL)setMIDIInput:(NSString *)track slot:(int)slot error:(NSError **)error;
- (BOOL)setMIDIChannel:(NSString *)track channel:(int)channel error:(NSError **)error;
- (BOOL)setRecordingChannels:(NSString *)track channel:(int)channel error:(NSError **)error;
- (BOOL)setRecording:(NSString *)track first:(int)first count:(int)count format:(NSString *)format error:(NSError **)error;
- (BOOL)pasteItems:(NSData *)data song:(NSString *)song moving:(BOOL)moving error:(NSError **)error;
- (BOOL)insertAudioTracks:(NSData *)data song:(NSString *)song error:(NSError **)error;
- (BOOL)replaceAudioClip:(NSData *)data track:(NSString *)track error:(NSError **)error;
- (BOOL)addRecordedClip:(NSData *)data track:(NSString *)track error:(NSError **)error;
- (BOOL)editMasterColor:(unsigned int)color error:(NSError **)error;
- (BOOL)editTrack:(NSString *)identifier name:(NSString *)name color:(unsigned int)color error:(NSError **)error;
- (BOOL)setRegionPitch:(NSString *)identifier semitones:(int)semitones tracks:(NSArray<NSString *> *)tracks groups:(NSArray<NSString *> *)groups error:(NSError **)error;
- (BOOL)editRegion:(NSString *)identifier name:(NSString *)name color:(unsigned int)color uppercaseName:(BOOL)uppercaseName error:(NSError **)error;
- (BOOL)moveClip:(NSString *)clipId start:(double)start track:(NSString *)trackId error:(NSError **)error;
- (BOOL)deleteManualMarker:(NSString *)identifier error:(NSError **)error;
- (BOOL)setProjectTiming:(double)bpm beats:(int)beats unit:(int)unit settings:(NSData *)settings error:(NSError **)error;
- (BOOL)setTempoMarkers:(NSData *)data error:(NSError **)error;
- (BOOL)setTempoMarker:(NSString *)identifier position:(double)position bpm:(double)bpm beats:(int)beats unit:(int)unit timebase:(NSString *)timebase error:(NSError **)error;
- (BOOL)setMarker:(NSString *)identifier name:(NSString *)name position:(double)position color:(unsigned int)color error:(NSError **)error;
- (BOOL)regionsFromClips:(NSArray<NSString *> *)clips identifiers:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)regionFromClip:(NSString *)clipId identifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)setTrackRouting:(NSData *)data error:(NSError **)error;
- (BOOL)setOutputPatches:(NSString *)track data:(NSData *)data error:(NSError **)error;
- (BOOL)setOutputPatch:(NSString *)track first:(int)first count:(int)count slot:(int)slot error:(NSError **)error;
- (BOOL)groupTracks:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)reorderTrack:(NSString *)track before:(NSString *)before error:(NSError **)error;
- (void)advance:(double)elapsed;
- (void)finishCurrentSong:(BOOL)enabled;
- (NSString *)classifyFilename:(NSString *)filename;
@end
@interface JarasMeterBank : NSObject
- (void)recordPeak:(float)value slot:(NSUInteger)slot;
- (float)takePeak:(NSUInteger)slot;
@end
NS_ASSUME_NONNULL_END
