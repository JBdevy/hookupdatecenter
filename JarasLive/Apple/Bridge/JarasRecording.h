#import <Foundation/Foundation.h>
@class AVAudioPCMBuffer, AVAudioSourceNode;
NS_ASSUME_NONNULL_BEGIN
@interface JarasCaptureRing : NSObject
- (instancetype)initWithChannels:(NSUInteger)channels capacity:(NSUInteger)frames;
- (AVAudioSourceNode *)monitorSourceWithSampleRate:(double)rate firstChannel:(NSUInteger)first channelCount:(NSUInteger)count;
- (void)beginCapture;
- (void)endCapture;
// Writer queue only: wait for the last accepted input buffer before draining.
- (void)waitForPendingCapture;
- (void)pushBuffer:(AVAudioPCMBuffer *)buffer;
- (NSUInteger)readFrames:(float *)destination maximum:(NSUInteger)frames;
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
