#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
NS_ASSUME_NONNULL_BEGIN
/// Continuous track processor. Control methods are never called by the audio callback.
@interface JarasStemSeparator : NSObject
+ (AVAudioUnitEffect *)makeNode;
/// Returns immediately after admission; inspect status for asynchronous model readiness.
+ (BOOL)start:(AVAudioUnitEffect *)node executable:(NSURL *)executable worker:(NSURL *)worker modelCache:(NSURL *)modelCache error:(NSError **)error;
+ (void)configure:(AVAudioUnitEffect *)node enabled:(BOOL)enabled gains:(NSArray<NSNumber *> *)gains muteMask:(NSUInteger)muteMask soloMask:(NSUInteger)soloMask;
+ (void)invalidate:(AVAudioUnitEffect *)node;
+ (void)stop:(AVAudioUnitEffect *)node;
/// Offline/export worker only. Reaps this process before the next export batch.
+ (BOOL)stopAndWait:(AVAudioUnitEffect *)node timeout:(NSTimeInterval)timeout error:(NSError **)error;
/// Only the separate manual-render/export graph may enable this bounded waiting path.
+ (void)setOfflineRendering:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
/// state, ready, error, latencyFrames, latencySeconds, underruns, overruns, generation.
+ (NSDictionary<NSString *,id> *)status:(AVAudioUnitEffect *)node;
@end
NS_ASSUME_NONNULL_END
#endif
