#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface JarasCatSynth : NSObject
@property(nonatomic, readonly) AVAudioSourceNode *node;
@property(nonatomic, readonly) AVAudioMixerNode *mix;
- (instancetype)initWithSampleRate:(double)rate;
+ (NSArray<NSNumber *> *)factoryPatch:(NSUInteger)index;
- (void)configurePatch:(NSArray<NSNumber *> *)values enabled:(BOOL)enabled;
- (void)receiveStatus:(uint8_t)status key:(uint8_t)key value:(uint8_t)value;
- (void)screenKey:(NSUInteger)key velocity:(NSUInteger)velocity;
- (BOOL)keyIsActive:(NSUInteger)key;
@property (nonatomic, readonly) BOOL screenVoiceIsActive;
- (void)silence;
- (void)setSequenceNotes:(NSArray<NSDictionary *> *)notes;
- (void)sequenceHead:(int)head position:(double)position clock:(double)clock running:(BOOL)running loopStart:(double)start loopEnd:(double)end;
@end
NS_ASSUME_NONNULL_END
