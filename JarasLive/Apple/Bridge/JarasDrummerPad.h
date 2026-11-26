#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasDrummerPad : NSObject
@property(nonatomic, readonly) AVAudioSourceNode *node;
- (instancetype)initWithCount:(NSUInteger)count sampleRate:(double)rate;
- (void)sample:(nullable AVAudioPCMBuffer *)sample pad:(NSUInteger)index;
- (void)pad:(NSUInteger)index note:(NSInteger)note gain:(float)gain;
- (void)masterGain:(float)gain;
- (void)hit:(NSUInteger)index;
- (void)midiNote:(NSUInteger)note velocity:(NSUInteger)velocity;
- (void)silence;
- (uint64_t)flashes;
- (void)setSequenceNotes:(NSArray<NSDictionary *> *)notes;
- (void)sequenceHead:(int)head position:(double)position clock:(double)clock running:(BOOL)running loopStart:(double)start loopEnd:(double)end;
@end
NS_ASSUME_NONNULL_END
