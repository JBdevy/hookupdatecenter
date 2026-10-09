import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
final class Hits: @unchecked Sendable {
 let lock=NSLock(); var values:[Double]=[]; var last = -Double.infinity
 func append(_ b: AVAudioPCMBuffer, _ t: AVAudioTime) {
  guard let data=b.floatChannelData else {return}
  lock.lock(); defer {lock.unlock()}
  for i in 0..<Int(b.frameLength) where abs(data[0][i]) > 0.06 {
   let when=AVAudioTime.seconds(forHostTime:t.hostTime)+Double(i)/b.format.sampleRate
   if when-last > 0.15 { values.append(when) }; last=when
  }
 }
 func take()->[Double] {lock.lock();defer{lock.unlock()};return values}
}
@MainActor func field(_ name:String,_ value:Any)->Any? {Mirror(reflecting:value).children.first{$0.label==name}?.value}
@MainActor func run() async throws {
 let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
 defer{try? FileManager.default.removeItem(at:directory)}
 let sourceRate=Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "48000")!
 let format=AVAudioFormat(standardFormatWithSampleRate:sourceRate,channels:2)!
 let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(sourceRate*80))!
 pcm.frameLength=pcm.frameCapacity
 for ch in 0..<2 {pcm.floatChannelData![ch].initialize(repeating:0,count:Int(pcm.frameLength))}
 var time=0.5
 for (tempo,count) in [(120.0,1),(130.0,52),(138.125,120)] {
  for _ in 0..<count {
   let first=Int((time*sourceRate).rounded())
   for ch in 0..<2 {for i in 0..<Int(sourceRate*0.015) {
    pcm.floatChannelData![ch][first+i]=Float(0.7*exp(-Double(i)/(sourceRate*0.004))*cos(Double(i)*0.3))
   }}
   time += 60/tempo
  }
 }
 do {let file=try AVAudioFile(forWriting:directory.appendingPathComponent("click.wav"),settings:format.settings);try file.write(from:pcm)}
 var p=Project.empty(name:"Continuous fractional-rate clock regression")
 let region=Part(id:UUID(),name:"Test",startTime:0,endTime:75)
 let rate=61.0/60.0
 let clip=AudioClip(id:UUID(),name:"Click",startTime:0,duration:75,audioFile:AudioFile(path:"click.wav"),playbackRate:rate,regionOwnerID:region.id)
 var track=Track(id:UUID(),name:"CLICK",role:.click);track.clips=[clip]
 p.songs[0].parts=[region];p.songs[0].tracks=[track];p.songs[0].duration=75
 p.songs[0].markers=[(0.5,120.0),(1.0,130.0),(25.0,138.125)].map { position,bpm in
  TimelineMarker(id:UUID(),name:"TEMPO",position:position/rate,color:0,tempoBPM:bpm*rate,tempoBeats:4,tempoUnit:4,tempoTimebase:.global,tempoReferenceBPM:bpm*rate)
 }
 let s=MetronomeSettings.shared
 let old=(s.enabled,s.preset,s.mode,s.gainA,s.gainB,s.output)
 defer{s.enabled=old.0;s.preset=old.1;s.mode=old.2;s.gainA=old.3;s.gainB=old.4;s.output=old.5}
 s.enabled=true;s.preset="Digital";s.mode=1;s.gainA=0;s.gainB=0;s.output = .stereo
 let engine=AVAudioEngine(), audio=StemAudioPlayback(engine:engine,realtime:true)
 audio.open(directory:directory)
 defer{audio.prepareForClosing()}
 let start=region.startTime+20
 var state=ShowSnapshot(project:p,transport:TransportState(playing:false,songId:p.songs[0].id,position:start,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
 try audio.update(state,revision:1)
 engine.mainMixerNode.outputVolume=0
 let master=field("masterBus",audio) as! AVAudioMixerNode
 let route=field("metronomeRoute",audio) as! AVAudioUnitEffect
 let items=Hits(), clicks=Hits()
 master.installTap(onBus:0,bufferSize:512,format:nil){items.append($0,$1)}
 route.installTap(onBus:0,bufferSize:512,format:nil){clicks.append($0,$1)}
 defer{master.removeTap(onBus:0);route.removeTap(onBus:0)}
 let began=ProcessInfo.processInfo.systemUptime
 state.transport.playing=true
 while ProcessInfo.processInfo.systemUptime-began<45 {
  state.transport.position=start+ProcessInfo.processInfo.systemUptime-began
  try audio.update(state,revision:1)
  try await Task.sleep(nanoseconds:20_000_000)
 }
 let a=items.take(),b=clicks.take()
 precondition(a.count > 80 && b.count > 80, "both outputs must contain the continuous clicks")
 let offsets=b.dropFirst(3).dropLast(3).map { beat in (a.min(by:{abs($0-beat)<abs($1-beat)})! - beat)*1000 }
 precondition(offsets.allSatisfy{abs($0)<10}, "file and metronome must stay aligned through the marker, without restarting: \(offsets)")
 precondition(offsets.max()! - offsets.min()! < 6, "fractional rate must not accumulate drift: \(offsets)")
 print("ITEMS",a.count,"METRONOME",b.count,"RATE",clip.audioRate)
 for (i,beat) in b.enumerated() where i % 8 == 0 {
  if let item=a.min(by:{abs($0-beat)<abs($1-beat)}) {print("ALIGN",i,"elapsed",beat-b[0],"ms",(item-beat)*1000)}
 }
 print("CONTINUOUS_METRONOME_FRACTIONAL_RATE_AND_TEMPO_CHANGE_OK sourceRate=\(sourceRate)")
}
Task{@MainActor in do{try await run();exit(0)}catch{print(error);exit(1)}}
dispatchMain()
