#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
@class AVAudioPCMBuffer, AVAudioSourceNode, AVAudioFormat;
NS_ASSUME_NONNULL_BEGIN
#if TARGET_OS_OSX
/// Direct AUHAL input: no AVAudioEngine tap batching on the monitoring path.
@interface JarasMacAudioInput : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *format;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) uint32_t device;
@property(nonatomic, readonly) uint32_t bufferFrames;
- (BOOL)prepareWithDevice:(uint32_t)device bufferFrames:(uint32_t)frames error:(NSError **)error;
- (void)setCapture:(void (^_Nullable)(AVAudioPCMBuffer *))capture;
- (BOOL)startAndReturnError:(NSError **)error;
- (void)pause;
- (void)stop;
@end
#endif
@interface JarasCaptureRing : NSObject
- (instancetype)initWithChannels:(NSUInteger)channels capacity:(NSUInteger)frames;
- (AVAudioSourceNode *)monitorSourceWithSampleRate:(double)rate firstChannel:(NSUInteger)first channelCount:(NSUInteger)count;
- (void)beginCapture;
- (void)endCapture;
// Writer queue only: wait for the last accepted input buffer before draining.
- (void)waitForPendingCapture;
- (void)pushBuffer:(AVAudioPCMBuffer *)buffer;
- (NSUInteger)readFrames:(float *)destination maximum:(NSUInteger)frames;
- (float)takeInputPeak:(NSUInteger)channel;
@property(nonatomic, readonly) NSUInteger droppedFrames;
@end
@interface JarasMP3Encoder : NSObject
+ (BOOL)encodeWav:(NSURL *)source to:(NSURL *)destination error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/// Owned by a single export worker; encodes each output incrementally.
@interface JarasMP3StreamEncoder : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url sampleRate:(NSInteger)rate channels:(NSInteger)channels bitRate:(NSInteger)bitRate error:(NSError **)error;
- (BOOL)writeBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error;
- (BOOL)finishWithError:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
