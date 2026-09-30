#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasTimecodeGenerator : NSObject
@property(nonatomic,readonly) AVAudioSourceNode *node;
- (instancetype)initWithFormat:(AVAudioFormat *)format;
// Host time is the instant represented by position. end is in the same timebase.
- (void)configurePosition:(double)position end:(double)end hostTime:(uint64_t)hostTime rate:(double)fps mode:(NSString *)mode running:(BOOL)running destination:(int32_t)destination;
- (void)setGain:(float)gain;
- (float)takePeak;
+ (NSArray<NSDictionary *> *)destinations;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface JarasMetronomeGenerator : NSObject
@property(nonatomic,readonly) AVAudioSourceNode *node;
- (instancetype)initWithFormat:(AVAudioFormat *)format;
- (void)setSections:(NSArray<NSDictionary *> *)sections soundA:(NSData *)soundA soundB:(NSData *)soundB mode:(NSInteger)mode;
- (void)setGainA:(float)a gainB:(float)b;
- (void)configurePosition:(double)position hostTime:(uint64_t)hostTime running:(BOOL)running loopStart:(double)loopStart loopEnd:(double)loopEnd;
@end
NS_ASSUME_NONNULL_END
