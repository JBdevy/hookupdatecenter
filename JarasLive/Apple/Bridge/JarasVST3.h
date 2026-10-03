#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface JarasVST3 : NSObject
+ (NSArray<NSDictionary *> *)scan:(NSString *)path error:(NSError **)error;
+ (AVAudioUnitEffect *)makeNode;
+ (BOOL)configure:(AVAudioUnitEffect *)node plugins:(NSArray<NSDictionary *> *)plugins error:(NSError **)error;
+ (void)setSequence:(AVAudioUnitEffect *)node notes:(NSArray<NSDictionary *> *)notes;
+ (void)sequenceClock:(AVAudioUnitEffect *)node head:(int)head position:(double)position clock:(double)clock running:(BOOL)running loopStart:(double)start loopEnd:(double)end;
+ (void)sendMIDI:(AVAudioUnitEffect *)node status:(unsigned char)status data1:(unsigned char)data1 data2:(unsigned char)data2;
+ (void)silence:(AVAudioUnitEffect *)node;
+ (void)instrumentMIDIInput:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (void)transport:(AVAudioUnitEffect *)node position:(double)position tempo:(double)tempo beats:(int)beats unit:(int)unit playing:(BOOL)playing;
+ (void)onEdit:(AVAudioUnitEffect *)node identifier:(NSString *)identifier action:(void (^)(void))action;
+ (NSDictionary * _Nullable)state:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
+ (NSArray<NSDictionary *> *)parameters:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
+ (void)setParameter:(AVAudioUnitEffect *)node identifier:(NSString *)identifier parameter:(unsigned int)parameter value:(double)value;
+ (NSView * _Nullable)editor:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
#endif
