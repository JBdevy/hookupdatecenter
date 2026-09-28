#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasTimecodeGenerator : NSObject
@property(nonatomic,readonly) AVAudioSourceNode *node;
- (instancetype)initWithFormat:(AVAudioFormat *)format;
// Host time is the instant represented by position. end is in the same timebase.
- (void)configurePosition:(double)position end:(double)end hostTime:(uint64_t)hostTime rate:(double)fps mode:(NSString *)mode running:(BOOL)running destination:(int32_t)destination;
- (float)takePeak;
+ (NSArray<NSDictionary *> *)destinations;
@end
NS_ASSUME_NONNULL_END
