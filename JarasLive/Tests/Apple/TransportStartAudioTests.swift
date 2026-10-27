import Foundation
import AVFoundation
import Darwin
setbuf(stdout,nil)
final class OnsetCapture: @unchecked Sendable {
 let lock=NSLock(); var values:[Float]=[]; var earliest:UInt64=0; var firstSound:Double?
 func append(_ b:AVAudioPCMBuffer,_ time:AVAudioTime){guard let p=b.floatChannelData?[0] else{return};lock.lock();defer{lock.unlock()};guard time.hostTime>=earliest else{return};if firstSound == nil, let index=(0..<Int(b.frameLength)).first(where: { abs(p[$0]) > 0.001 }) { firstSound=AVAudioTime.seconds(forHostTime: time.hostTime-earliest)+Double(index)/b.format.sampleRate };values += Array(UnsafeBufferPointer(start:p,count:Int(b.frameLength)))}
 func clear(){lock.lock();values.removeAll(keepingCapacity:true);earliest=mach_absolute_time();firstSound=nil;lock.unlock()}
 func read()->[Float]{lock.lock();defer{lock.unlock()};return values}
}
@MainActor func run() async throws {
 let rate=Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
 let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
 defer{try? FileManager.default.removeItem(at:directory)}
 let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
 let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(rate))!;pcm.frameLength=pcm.frameCapacity
 for ch in 0..<2{for n in 0..<Int(pcm.frameLength){pcm.floatChannelData![ch][n]=0.25}}
 do{let file=try AVAudioFile(forWriting:directory.appendingPathComponent("onset.wav"),settings:format.settings);try file.write(from:pcm)}
 let engine=AVAudioEngine(),capture=OnsetCapture();let audio=StemAudioPlayback(engine:engine,realtime:true)
 audio.open(directory:directory);defer{audio.prepareForClosing()}
 var project=Project.empty(name:"Transport start");var track=Track(id:UUID(),name:"Tone",role:.other)
 track.clips=[AudioClip(id:UUID(),name:"Tone",startTime:0,duration:1,audioFile:AudioFile(path:"onset.wav"))];project.songs[0].tracks=[track]
 var state=ShowSnapshot(project:project,transport:TransportState(playing:false,songId:project.songs[0].id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
 try audio.update(state,revision:1);engine.mainMixerNode.outputVolume=0
 let master=Mirror(reflecting:audio).children.first{$0.label=="masterBus"}!.value as! AVAudioMixerNode
 master.installTap(onBus:0,bufferSize:128,format:nil){b,t in capture.append(b,t)};defer{master.removeTap(onBus:0)}
 for position in [0.0,0.25,0.0]{
  state.transport.playing=false;state.transport.position=position;try audio.update(state,revision:1)
  try await Task.sleep(nanoseconds:150_000_000);capture.clear()
  let begin=Date();state.transport.playing=true;try audio.update(state,revision:1);let updateMS=Date().timeIntervalSince(begin)*1000;try await Task.sleep(nanoseconds:350_000_000)
  let samples=capture.read(),peak=samples.map{abs($0)}.max() ?? 0
  let step=zip([Float(0)]+samples,samples).map{abs($0-$1)}.max() ?? 1
  print("TRANSPORT_START rate=\(rate) position=\(position) peak=\(peak) maxStep=\(step) updateMS=\(updateMS) firstSoundMS=\((capture.firstSound ?? -1)*1000)")
  if step>=0.02 {let index=zip([Float(0)]+samples,samples).enumerated().max{abs($0.element.0-$0.element.1)<abs($1.element.0-$1.element.1)}!.offset;print("STEP_INDEX",index,"COUNT",samples.count,"SAMPLES",Array(samples[max(0,index-5)..<min(samples.count,index+8)]))}
  precondition(peak>0.2,"Play must produce audio");precondition(step<0.02,"Play must not jump abruptly out of silence")
 }
}
Task{@MainActor in do{try await run();exit(0)}catch{print(error);exit(1)}}
dispatchMain()
