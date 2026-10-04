#import "JarasRecording.h"
#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <vector>
#include <algorithm>
#include <thread>
#include "../../Core/ThirdParty/Lame/lame.h"
@implementation JarasCaptureRing {
    std::vector<float> _samples;
    NSUInteger _channels, _capacity;
    std::atomic<uint64_t> _read, _write, _dropped;
    // Bit 0 accepts input; bit 1 belongs to the single realtime producer.
    std::atomic<unsigned> _captureState;
}
- (instancetype)initWithChannels:(NSUInteger)channels capacity:(NSUInteger)frames {
    if ((self = [super init])) { _channels=channels; _capacity=frames; _samples.resize(channels*frames); _read=0; _write=0; _dropped=0; _captureState=1; }
    return self;
}
- (void)beginCapture {
    // The preceding writer has finished before a ring can be reused.
    [self endCapture]; [self waitForPendingCapture];
    _read=0; _write=0; _dropped=0;
    _captureState.store(1, std::memory_order_release);
}
- (void)endCapture { _captureState.fetch_and(~1u, std::memory_order_acq_rel); }
- (void)waitForPendingCapture {
    while (_captureState.load(std::memory_order_acquire) & 2u) std::this_thread::yield();
}
- (void)pushBuffer:(AVAudioPCMBuffer *)buffer {
    if (!buffer.floatChannelData || buffer.format.channelCount != _channels || !_capacity) return;
    unsigned accepting = 1;
    if (!_captureState.compare_exchange_strong(accepting, 3, std::memory_order_acquire)) return;
    auto write=_write.load(std::memory_order_relaxed), read=_read.load(std::memory_order_acquire);
    auto count=std::min<uint64_t>(buffer.frameLength, _capacity-(write-read));
    auto channels=buffer.floatChannelData;
    for(uint64_t f=0;f<count;++f) for(NSUInteger c=0;c<_channels;++c)
        _samples[((write+f)%_capacity)*_channels+c]=channels[c][f*buffer.stride];
    _write.store(write+count,std::memory_order_release);
    _dropped.fetch_add(buffer.frameLength-count,std::memory_order_relaxed);
    _captureState.fetch_and(~2u, std::memory_order_release);
}
- (NSUInteger)readFrames:(float *)destination maximum:(NSUInteger)frames {
    auto read=_read.load(std::memory_order_relaxed), write=_write.load(std::memory_order_acquire);
    auto count=std::min<uint64_t>(frames,write-read);
    for(uint64_t f=0;f<count;++f) std::copy_n(&_samples[((read+f)%_capacity)*_channels],_channels,destination+f*_channels);
    _read.store(read+count,std::memory_order_release); return count;
}
- (AVAudioSourceNode *)monitorSourceWithSampleRate:(double)rate firstChannel:(NSUInteger)first channelCount:(NSUInteger)count {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)count];
    return [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *output) {
        auto read=self->_read.load(std::memory_order_relaxed), write=self->_write.load(std::memory_order_acquire);
        // Bound latency after a device pause; never replay stale live input.
        if (write-read > std::max<uint64_t>(4096, frames*4)) read=write-std::min<uint64_t>(write-read,frames*2);
        auto available=std::min<uint64_t>(frames,write-read);
        *silent=available==0;
        for (NSUInteger c=0; c<output->mNumberBuffers; ++c) {
            auto *samples=(float *)output->mBuffers[c].mData;
            if (!samples) continue;
            auto source=first+c;
            for (NSUInteger f=0; f<frames; ++f) samples[f]=(f<available && source<self->_channels) ? self->_samples[((read+f)%self->_capacity)*self->_channels+source] : 0;
        }
        self->_read.store(read+available,std::memory_order_release);
        return noErr;
    }];
}
- (NSUInteger)droppedFrames { return _dropped.load(std::memory_order_relaxed); }
@end
@implementation JarasMP3Encoder
+ (BOOL)encodeWav:(NSURL *)source to:(NSURL *)destination error:(NSError **)error {
    AVAudioFile *file=[[AVAudioFile alloc] initForReading:source error:error]; if(!file) return NO;
    const int channels=(int)file.processingFormat.channelCount;
    lame_t encoder=lame_init(); if(!encoder) return NO;
    lame_set_in_samplerate(encoder,(int)file.processingFormat.sampleRate);
    lame_set_out_samplerate(encoder,(int)file.processingFormat.sampleRate);
    lame_set_num_channels(encoder,channels); lame_set_brate(encoder,320); lame_set_quality(encoder,0);
    lame_set_mode(encoder,channels==1 ? MONO : JOINT_STEREO);
    lame_set_bWriteVbrTag(encoder,0);
    FILE *output=nullptr;
    BOOL ok=lame_init_params(encoder)>=0;
    if(ok) { output=fopen(destination.fileSystemRepresentation,"wb"); ok=output!=nullptr; }
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:4096];
    unsigned char encoded[16384];
    while(ok && file.framePosition<file.length) {
        if(![file readIntoBuffer:buffer frameCount:4096 error:error]) { ok=NO; break; }
        if(!buffer.frameLength) break;
        int bytes=lame_encode_buffer_ieee_float(encoder,buffer.floatChannelData[0],buffer.floatChannelData[channels>1?1:0],(int)buffer.frameLength,encoded,sizeof(encoded));
        if(bytes<0 || fwrite(encoded,1,bytes,output)!=(size_t)bytes) { ok=NO; break; }
    }
    if(ok) { int bytes=lame_encode_flush(encoder,encoded,sizeof(encoded)); ok=bytes>=0 && fwrite(encoded,1,bytes,output)==(size_t)bytes; }
    if(output && fclose(output)!=0) ok=NO;
    lame_close(encoder);
    if(!ok && error && !*error) *error=[NSError errorWithDomain:@"JarasRecording" code:1 userInfo:@{NSLocalizedDescriptionKey:@"MP3 export failed. The 24-bit WAV recording has been preserved."}];
    return ok;
}
@end
@implementation JarasMP3StreamEncoder {
    lame_t _encoder;
    FILE *_output;
    unsigned char _encoded[16384];
    int _channels;
}
- (instancetype)initWithURL:(NSURL *)url sampleRate:(NSInteger)rate channels:(NSInteger)channels bitRate:(NSInteger)bitRate error:(NSError **)error {
    if((self=[super init])) {
        _channels=int(channels); _encoder=lame_init();
        if(!_encoder) return nil;
        lame_set_in_samplerate(_encoder,int(rate)); lame_set_out_samplerate(_encoder,int(rate));
        lame_set_num_channels(_encoder,_channels); lame_set_brate(_encoder,int(bitRate)); lame_set_quality(_encoder,0);
        lame_set_mode(_encoder,_channels==1 ? MONO : JOINT_STEREO); lame_set_bWriteVbrTag(_encoder,0);
        if(lame_init_params(_encoder)<0 || !(_output=fopen(url.fileSystemRepresentation,"wb"))) {
            if(error) *error=[NSError errorWithDomain:@"JarasExport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not create the MP3 output."}];
            return nil;
        }
    }
    return self;
}
- (BOOL)writeBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    if(!_encoder || !_output || !buffer.floatChannelData || buffer.frameLength>4096 || buffer.format.channelCount!=_channels) return NO;
    int bytes=lame_encode_buffer_ieee_float(_encoder,buffer.floatChannelData[0],buffer.floatChannelData[_channels>1?1:0],int(buffer.frameLength),_encoded,sizeof(_encoded));
    BOOL ok=bytes>=0 && fwrite(_encoded,1,bytes,_output)==size_t(bytes);
    if(!ok && error) *error=[NSError errorWithDomain:@"JarasExport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"MP3 encoding failed."}];
    return ok;
}
- (BOOL)finishWithError:(NSError **)error {
    if(!_encoder || !_output) return NO;
    int bytes=lame_encode_flush(_encoder,_encoded,sizeof(_encoded));
    BOOL ok=bytes>=0 && fwrite(_encoded,1,bytes,_output)==size_t(bytes);
    if(fclose(_output)!=0) ok=NO; _output=nullptr;
    lame_close(_encoder); _encoder=nullptr;
    if(!ok && error) *error=[NSError errorWithDomain:@"JarasExport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Could not finish the MP3 output."}];
    return ok;
}
- (void)dealloc { if(_output) fclose(_output); if(_encoder) lame_close(_encoder); }
@end
