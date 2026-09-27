#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasCoreBridge : NSObject
- (BOOL)loadProjectData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(load(projectData:));
- (BOOL)executeCommand:(NSString *)command target:(nullable NSString *)target value:(double)value error:(NSError **)error NS_SWIFT_NAME(execute(command:target:value:));
- (nullable NSData *)snapshotWithError:(NSError **)error NS_SWIFT_NAME(snapshot());
- (nullable NSData *)playbackSnapshotWithError:(NSError **)error NS_SWIFT_NAME(playbackSnapshot());
- (BOOL)addTrackWithId:(NSString *)identifier name:(NSString *)name role:(NSString *)role error:(NSError **)error NS_SWIFT_NAME(addTrack(id:name:role:));
- (void)advance:(double)elapsed;
- (void)finishCurrentSong:(BOOL)enabled;
- (NSString *)classifyFilename:(NSString *)filename;
@end
NS_ASSUME_NONNULL_END
