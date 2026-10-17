import AVFoundation
import CoreVideo
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let silent=root.appendingPathComponent("silent.mp4"),wav=root.appendingPathComponent("tone.wav"),out=root.appendingPathComponent("tone-video.mp4")
for u in [silent,wav,out] {try? FileManager.default.removeItem(at:u)}
let writer=try AVAssetWriter(outputURL:silent,fileType:.mp4)
let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
for frame in 0..<60 {
 while !input.isReadyForMoreMediaData {Thread.sleep(forTimeInterval:0.002)}
 var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
 CVPixelBufferLockBaseAddress(buffer!,[]);memset(CVPixelBufferGetBaseAddress(buffer!),Int32(frame*3),CVPixelBufferGetDataSize(buffer!));CVPixelBufferUnlockBaseAddress(buffer!,[])
 assert(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
}
input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()};done.wait();if let error=writer.error {throw error}
let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
var audio: AVAudioFile? = try AVAudioFile(forWriting:wav,settings:format.settings)
let samples=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000)!;samples.frameLength=96000
for c in 0..<2 {for i in 0..<96000 {samples.floatChannelData![c][i]=Float(sin(Double(i)*2*Double.pi*440/48000)*0.25)}}
try audio!.write(from:samples)
audio=nil
let composition=AVMutableComposition(),v=AVURLAsset(url:silent),a=AVURLAsset(url:wav)
let range=CMTimeRange(start:.zero,duration:CMTime(value:2,timescale:1))
try composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:v.tracks(withMediaType:.video)[0],at:.zero)
try composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:a.tracks(withMediaType:.audio)[0],at:.zero)
let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetMediumQuality)!;export.outputURL=out;export.outputFileType = .mp4
let exported=DispatchSemaphore(value:0);export.exportAsynchronously{exported.signal()};exported.wait();if let error=export.error{throw error}
print(out.path)
