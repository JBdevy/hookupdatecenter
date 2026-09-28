#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasSoundFont : NSObject
@property(nonatomic, readonly) AVAudioSourceNode *node;
- (nullable instancetype)initWithURL:(NSURL *)url sampleRate:(double)sampleRate error:(NSError **)error;
- (void)sendStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2;
- (void)setGain:(double)decibels pan:(double)pan;
- (void)setEnvelopeAttack:(double)attack hold:(double)hold decay:(double)decay sustain:(double)sustain release:(double)releaseTime;
- (void)setPerformanceMonophonic:(BOOL)monophonic drums:(BOOL)drums velocityCurve:(int)curve;
- (void)setFilterCutoff:(double)cutoff velocityMinimum:(double)minimum attack:(double)attack hold:(double)hold decay:(double)decay sustain:(double)sustain release:(double)releaseTime depth:(double)depth;
- (void)setControllersModulation:(BOOL)modulation pitchBend:(BOOL)pitchBend;
- (void)silence;
@end
NS_ASSUME_NONNULL_END
