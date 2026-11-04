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
+ (void)setSequence:(AVAudioUnitEffect *)node notes:(NSArray<NSDictionary *> *)notes preserveHeld:(BOOL)preserveHeld;
+ (void)sequenceClock:(AVAudioUnitEffect *)node head:(int)head position:(double)position clock:(double)clock running:(BOOL)running loopStart:(double)start loopEnd:(double)end;
+ (void)sendMIDI:(AVAudioUnitEffect *)node status:(unsigned char)status data1:(unsigned char)data1 data2:(unsigned char)data2;
+ (void)silence:(AVAudioUnitEffect *)node;
+ (void)instrumentMIDIInput:(AVAudioUnitEffect *)node enabled:(BOOL)enabled;
+ (void)transport:(AVAudioUnitEffect *)node position:(double)position tempo:(double)tempo beats:(int)beats unit:(int)unit playing:(BOOL)playing;
// Immutable tempo map and an audio-clock anchor, prepared by the graph owner.
+ (void)setTempoMap:(AVAudioUnitEffect *)node points:(NSArray<NSDictionary *> *)points;
+ (void)transportClock:(AVAudioUnitEffect *)node position:(double)position clock:(double)clock playing:(BOOL)playing loopStart:(double)start loopEnd:(double)end;
+ (void)onEdit:(AVAudioUnitEffect *)node identifier:(NSString *)identifier action:(void (^)(void))action;
+ (BOOL)isPluginLoaded:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
+ (NSDictionary * _Nullable)state:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
+ (void)rememberCapturedState:(AVAudioUnitEffect *)node identifier:(NSString *)identifier component:(NSString * _Nullable)component controller:(NSString * _Nullable)controller;
+ (void)onParameterEdit:(AVAudioUnitEffect *)node identifier:(NSString *)identifier action:(void (^)(unsigned int, double, BOOL))action;
+ (NSArray<NSDictionary *> *)parameters:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
+ (void)setParameter:(AVAudioUnitEffect *)node identifier:(NSString *)identifier parameter:(unsigned int)parameter value:(double)value;
+ (NSView * _Nullable)editor:(AVAudioUnitEffect *)node identifier:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
#endif
