#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// A bounded analysis tap, installed only while an effect editor is observing.
@interface JarasAudioAnalysisProbe : NSObject
- (void)attachToNode:(AVAudioNode *)node;
- (void)detach;
- (nullable NSData *)frame;
- (NSArray<NSNumber *> *)takePeaks;
@end
@interface JarasEqualizer : NSObject
+ (AVAudioUnitEffect *)makeNode;
+ (void)configure:(AVAudioUnitEffect *)node coefficients:(NSArray<NSArray<NSNumber *> *> *)coefficients enabled:(BOOL)enabled;
+ (void)setPolarity:(AVAudioUnitEffect *)node inverted:(BOOL)inverted;
+ (void)setInputGain:(AVAudioUnitEffect *)node gain:(double)gain;
+ (void)setInputPan:(AVAudioUnitEffect *)node pan:(double)pan;
+ (void)setPlaybackBoundary:(AVAudioUnitEffect *)node hostTime:(uint64_t)hostTime;
+ (void)setInputFade:(AVAudioUnitEffect *)node fadeIn:(double)fadeIn fadeOut:(double)fadeOut duration:(double)duration position:(double)position hostTime:(uint64_t)hostTime sampleTime:(double)sampleTime;
+ (void)setInputChannelMode:(AVAudioUnitEffect *)node mode:(int)mode;
+ (void)setOutputMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (float)takeOutputPeak:(AVAudioUnitEffect *)node channel:(NSUInteger)channel;
+ (void)setAnalysisEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (nullable NSData *)analysisFrame:(AVAudioUnitEffect *)node input:(BOOL)input;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface JarasDynamics : NSObject
/// EQ and compressor share one render pull for each fixed-order item chain.
+ (AVAudioUnitEffect *)makeItemEqualizerCompressor;
+ (AVAudioUnitEffect *)makeCompressor;
+ (AVAudioUnitEffect *)makeLimiter;
+ (void)configureLimiter:(AVAudioUnitEffect *)node enabled:(BOOL)enabled gain:(double)gain ceiling:(double)ceiling release:(double)release;
+ (AVAudioUnitEffect *)makeReverb;
+ (void)configureCompressor:(AVAudioUnitEffect *)node enabled:(BOOL)enabled threshold:(double)threshold ratio:(double)ratio attack:(double)attack release:(double)release gain:(double)gain;
+ (void)configureReverb:(AVAudioUnitEffect *)node enabled:(BOOL)enabled space:(NSInteger)space mix:(double)mix decay:(double)decay lowCut:(double)lowCut highCut:(double)highCut;
+ (void)setAnalysisEnabled:(AVAudioUnitEffect *)node input:(BOOL)input enabled:(BOOL)enabled;
+ (void)setCompressorMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (nullable NSData *)analysisFrame:(AVAudioUnitEffect *)node input:(BOOL)input;
+ (NSArray<NSNumber *> *)analysisPeaks:(AVAudioUnitEffect *)node input:(BOOL)input;
+ (NSArray<NSNumber *> *)takeCompressorPeaks:(AVAudioUnitEffect *)node;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface JarasChannelRouter : NSObject
+ (AVAudioUnitEffect *)makeNode;
+ (void)setRenderEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (void)beginStopFade:(AVAudioUnitEffect *)node;
+ (void)setInputMeteringEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (float)takeInputPeak:(AVAudioUnitEffect *)node channel:(NSUInteger)channel;
+ (void)configure:(AVAudioUnitEffect *)node first:(NSInteger)first count:(NSInteger)count;
+ (void)configurePatches:(AVAudioUnitEffect *)node firsts:(NSArray<NSNumber *> *)firsts counts:(NSArray<NSNumber *> *)counts;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/// Fixed item output: gain changes never reconnect the graph. Idle sources
/// return silence without rendering their upstream player or effect chain.
@interface JarasVoiceGain : NSObject
+ (AVAudioUnitEffect *)makeNode;
+ (void)setDecibels:(AVAudioUnitEffect *)node decibels:(double)decibels;
+ (void)setRenderEnabled:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/// Packs N independent stereo exports into one offline render block.
@interface JarasExportMultiplexer : NSObject
+ (AVAudioUnitEffect *)makeNode:(NSInteger)outputs;
@end
NS_ASSUME_NONNULL_END
