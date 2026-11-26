// Read-only Core Audio telemetry. No audio stream, microphone access or device
// configuration is opened/changed by this process.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

// Listener blocks and snapshots run on the main queue. Count notifications
// without printing or querying properties from the device's realtime thread.
static NSMutableDictionary<NSNumber *, NSNumber *> *overloadNotifications;
static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
}
static id integerProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress property = address(selector);
    UInt32 value = 0, bytes = sizeof(value);
    return AudioObjectGetPropertyData(object, &property, 0, NULL, &bytes, &value) == noErr
        ? @(value) : NSNull.null;
}
static id rateProperty(AudioDeviceID device) {
    AudioObjectPropertyAddress property = address(kAudioDevicePropertyNominalSampleRate);
    Float64 value = 0;
    UInt32 bytes = sizeof(value);
    return AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &value) == noErr && isfinite(value)
        ? @(value) : NSNull.null;
}
static NSString *deviceName(AudioDeviceID device) {
    AudioObjectPropertyAddress property = address(kAudioObjectPropertyName);
    CFStringRef value = NULL;
    UInt32 bytes = sizeof(value);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &bytes, &value) != noErr || !value)
        return @"Unavailable";
    return CFBridgingRelease(value);
}
static NSArray<NSNumber *> *deviceIDs(void) {
    AudioObjectPropertyAddress property = address(kAudioHardwarePropertyDevices);
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &bytes) != noErr || !bytes)
        return @[];
    NSMutableData *storage = [NSMutableData dataWithLength:bytes];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &bytes, storage.mutableBytes) != noErr)
        return @[];
    NSMutableArray *result = [NSMutableArray array];
    const AudioDeviceID *ids = storage.bytes;
    for (UInt32 i = 0; i < bytes / sizeof(AudioDeviceID); ++i) [result addObject:@(ids[i])];
    return result;
}
static void snapshot(NSString *event) {
    @autoreleasepool {
        NSMutableArray *devices = [NSMutableArray array];
        for (NSNumber *number in deviceIDs()) {
            AudioDeviceID device = number.unsignedIntValue;
            [devices addObject:@{@"id": number, @"name": deviceName(device),
                @"buffer_frames": integerProperty(device, kAudioDevicePropertyBufferFrameSize),
                @"sample_rate": rateProperty(device),
                @"overload_notifications": overloadNotifications[number] ?: @0,
                @"running": integerProperty(device, kAudioDevicePropertyDeviceIsRunningSomewhere)}];
        }
        NSDictionary *record = @{@"event": event,
            @"unix_time": @([NSDate date].timeIntervalSince1970),
            @"uptime": @(NSProcessInfo.processInfo.systemUptime),
            @"default_output": integerProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice),
            @"system_output": integerProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultSystemOutputDevice),
            @"devices": devices};
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
        if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
    }
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        char *end = NULL;
        long seconds = argc == 2 ? strtol(argv[1], &end, 10) : 0;
        if (argc != 2 || !end || *end || seconds < 1 || seconds > 300) {
            fprintf(stderr, "Usage: audio-device-snapshot <seconds: 1..300>\n");
            return 2;
        }
        dispatch_queue_t queue = dispatch_get_main_queue();
        overloadNotifications = [NSMutableDictionary dictionary];
        snapshot(@"start");
        for (NSNumber *number in deviceIDs()) {
            for (NSNumber *selector in @[@(kAudioDevicePropertyBufferFrameSize), @(kAudioDevicePropertyNominalSampleRate), @(kAudioDeviceProcessorOverload)]) {
                AudioObjectPropertyAddress property = address(selector.unsignedIntValue);
                OSStatus result = AudioObjectAddPropertyListenerBlock(number.unsignedIntValue, &property, queue,
                    ^(UInt32 count, const AudioObjectPropertyAddress *properties) {
                        if (selector.unsignedIntValue == kAudioDeviceProcessorOverload) {
                            overloadNotifications[number] = @(overloadNotifications[number].unsignedLongLongValue + 1);
                            return;
                        }
                        snapshot(selector.unsignedIntValue == kAudioDevicePropertyBufferFrameSize ? @"buffer_changed" : @"rate_changed");
                    });
                if (result != noErr) fprintf(stderr, "Listener unavailable: device=%u selector=%u status=%d\n",
                                            number.unsignedIntValue, selector.unsignedIntValue, (int)result);
            }
        }
        for (NSNumber *selector in @[@(kAudioHardwarePropertyDefaultOutputDevice), @(kAudioHardwarePropertyDefaultSystemOutputDevice), @(kAudioHardwarePropertyDevices)]) {
            AudioObjectPropertyAddress property = address(selector.unsignedIntValue);
            OSStatus result = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &property, queue,
                ^(UInt32 count, const AudioObjectPropertyAddress *properties) { snapshot(@"device_configuration_changed"); });
            if (result != noErr) fprintf(stderr, "System listener unavailable: status=%d\n", (int)result);
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ snapshot(@"sample"); });
        dispatch_resume(timer);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), queue, ^{
            snapshot(@"end");
            dispatch_source_cancel(timer);
            exit(0);
        });
        dispatch_main();
    }
}
