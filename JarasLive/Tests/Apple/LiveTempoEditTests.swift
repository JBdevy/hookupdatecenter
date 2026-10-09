// Run with JARAS_AUDIO_TEST_SOURCE=Tests/Apple/LiveTempoEditTests.swift bash scripts/test-audio.sh.
// Capture real-time output silently: repeated BPM increases/decreases must
// preserve sound across both fragment splits and subsequent merges.
import Foundation
import AVFoundation
import Darwin
setbuf(stdout,nil)
final class Capture: @unchecked Sendable {
 let lock=NSLock(); var samples=[Float](); var rate=0.0; var firstHost: UInt64 = 0
 func append(_ b:AVAudioPCMBuffer, _ time: AVAudioTime) {lock.lock();defer{lock.unlock()};if firstHost == 0 { firstHost = time.hostTime };rate=b.format.sampleRate;samples += Array(UnsafeBufferPointer(start:b.floatChannelData![0],count:Int(b.frameLength)))}
 func take()->([Float],Double) {lock.lock();defer{lock.unlock()};return(samples,rate)}
}
@MainActor func field(_ name:String,_ value:Any)->Any? {Mirror(reflecting:value).children.first{$0.label==name}?.value}
@MainActor func activePlayers(_ audio: StemAudioPlayback) -> Set<ObjectIdentifier> {
 guard let anchor=(field("headAudioClock",audio) as! [Int:(position:Double,host:UInt64)])[0],let voices=field("voices",audio) else{return []}
 let host=mach_absolute_time()
 let position=anchor.position+(host>=anchor.host ? AVAudioTime.seconds(forHostTime:host-anchor.host) : -AVAudioTime.seconds(forHostTime:anchor.host-host))
 var result=Set<ObjectIdentifier>()
 for entry in Mirror(reflecting:voices).children {
  guard let voice=Mirror(reflecting:entry.value).children.first(where:{$0.label=="value"})?.value ?? Mirror(reflecting:entry.value).children.dropFirst().first?.value,
        let clip=field("clip",voice) as? AudioClip,let player=field("player",voice) as? AVAudioPlayerNode,
        clip.startTime<=position,position<clip.startTime+clip.duration else{continue}
  result.insert(ObjectIdentifier(player))
 }
 return result
}
@MainActor func run() async throws {
 let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
 let rate=Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
 let rapid=ProcessInfo.processInfo.environment["JARAS_TEST_RAPID_TEMPO"]=="1"
 let descending=ProcessInfo.processInfo.environment["JARAS_TEST_DESCENDING_TEMPO"]=="1"
 let boundary=ProcessInfo.processInfo.environment["JARAS_TEST_BOUNDARY_TEMPO"]=="1"
 let baseline=ProcessInfo.processInfo.environment["JARAS_TEST_BASELINE_TEMPO"]=="1"
 let fmt=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
 let pcm=AVAudioPCMBuffer(pcmFormat:fmt,frameCapacity:AVAudioFrameCount(rate*24))!;pcm.frameLength=pcm.frameCapacity
 // A rising tone also makes a replay of older source audio observable in PCM.
 for ch in 0..<2 {for i in 0..<Int(pcm.frameLength) {let t=Double(i)/rate;pcm.floatChannelData![ch][i]=Float(0.15*sin(2*Double.pi*(220*t+60*t*t)))}}
 do{let f=try AVAudioFile(forWriting:dir.appendingPathComponent("tone.wav"),settings:fmt.settings);try f.write(from:pcm)}
 var p=Project.empty(name:"Live tempo PCM")
 let region=Part(id:UUID(),name:"Song",startTime:0.2,endTime:22.2)
 var track=Track(id:UUID(),name:"Audio",role:.other)
 track.clips=[AudioClip(id:UUID(),name:"Tone",startTime:0.2,duration:22,audioFile:AudioFile(path:"tone.wav"),regionOwnerID:region.id)]
 p.songs[0].parts=[region]
 p.songs[0].tracks=(0..<24).map { index in
  var copy=track;copy.id=UUID();copy.name="Stem \(index)"
  // Observe one source on the left while exercising all other players on
  // the right. Summing identical chirps can cancel through tiny differences
  // in stretch latency and falsely look like a playback interruption.
  copy.volume=index == 0 ? 1 : 1.0/24;copy.pan=index == 0 ? -1 : 1
  copy.clips[0].id=UUID();return copy
 }
 p.songs[0].markers=[(0.2,120.0),(3.2,140.0),(6.2,130.0),(rapid ? 14.2 : 10.2,150.0)].map { pos,bpm in TimelineMarker(id:UUID(),name:"Tempo",position:pos,color:0,tempoBPM:bpm,tempoTimebase:.global,tempoReferenceBPM:bpm)}
 let engine=AVAudioEngine(),audio=StemAudioPlayback(engine:engine,realtime:true);audio.open(directory:dir);defer{audio.prepareForClosing()}
 var state=ShowSnapshot(project:p,transport:TransportState(playing:false,songId:p.songs[0].id,position:rapid ? 7 : 0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
 try audio.update(state,revision:1);engine.mainMixerNode.outputVolume=0
 // Let stopped-state source preparation finish, as with an opened project.
 try await Task.sleep(nanoseconds:1_500_000_000)
 let master=field("masterBus",audio) as! AVAudioMixerNode, capture=Capture()
 master.installTap(onBus:0,bufferSize:512,format:nil){b,t in capture.append(b,t)};defer{master.removeTap(onBus:0)}
 var last=ProcessInfo.processInfo.systemUptime,edits=0
 let began=last;state.transport.playing=true
 let times=baseline ? [] : boundary ? [2.85,3.0,3.15,3.3,3.45,3.6] : rapid ? (0..<(descending ? 30 : 36)).map{1.0+Double($0)*0.04} : [1.0,1.35,1.7,4.5,4.85,5.2]
 var maximumEditDuration=0.0, maximumUpdateDuration=0.0
 while ProcessInfo.processInfo.systemUptime-began<(descending ? 24 : 8) {
  let now=ProcessInfo.processInfo.systemUptime;state.transport.position += now-last;last=now
  var didEdit=false
  var previousPlayers=Set<ObjectIdentifier>()
  var previousClocks=[ObjectIdentifier:AVAudioFramePosition]()
  if edits<times.count && now-began>=times[edits] {
   previousPlayers=activePlayers(audio)
   if !boundary { precondition(previousPlayers.count==24,"Exercise every sounding stem") }
   for case let player as AVAudioPlayerNode in engine.attachedNodes where previousPlayers.contains(ObjectIdentifier(player)) {
    if let node=player.lastRenderTime,let clock=player.playerTime(forNodeTime:node) {previousClocks[ObjectIdentifier(player)]=clock.sampleTime}
   }
   let before=state.project.songs[0];var after=before
   for i in after.markers!.indices {after.markers![i].tempoBPM! += descending ? -2 : rapid ? (edits.isMultiple(of:2) ? 1 : -1) : (edits < 3 ? 1 : -1)}
   let map=TempoEditMap(before:before,after:after);map.apply(to:&after);map.apply(to:&state.transport)
   state.project.songs[0]=after;edits+=1;didEdit=true
  }
  // A delayed UI tick during an edit must not be mistaken for a seek.
  // Only do this once: the following ordinary tick still advances its clock.
  if !rapid && !boundary && edits == 1 && maximumEditDuration == 0 { Thread.sleep(forTimeInterval:0.22) }
  let updateStart=ProcessInfo.processInfo.systemUptime
  try audio.update(state,revision:UInt64(edits+1))
  if didEdit {
   let retained=activePlayers(audio)
   print("PLAYERS_RETAINED",edits,previousPlayers.intersection(retained).count,"OF",previousPlayers.count)
   if !boundary { precondition(previousPlayers.isSubset(of:retained),"Changing BPM must keep the sounding player, including when pending fragments merge into it") }
   for case let player as AVAudioPlayerNode in engine.attachedNodes {
    if let previous=previousClocks[ObjectIdentifier(player)],let node=player.lastRenderTime,let clock=player.playerTime(forNodeTime:node) {
     if !boundary { precondition(clock.sampleTime>=previous,"Changing BPM must not rewind a sounding player's source clock") }
    }
   }
  }
  let updateDuration=ProcessInfo.processInfo.systemUptime-updateStart
  maximumUpdateDuration=max(maximumUpdateDuration,updateDuration)
  if didEdit {maximumEditDuration=max(maximumEditDuration,updateDuration);print("EDIT",edits,"POSITION",state.transport.position,"SECONDS",updateDuration)}
  try await Task.sleep(nanoseconds:10_000_000)
 }
 let(samples,outputRate)=capture.take();let window=Int(outputRate*0.01)
 if let path=ProcessInfo.processInfo.environment["JARAS_TEST_CAPTURE_PATH"] {
  try samples.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:path))
 }
 var minimum=1.0,quiet=0
 for start in stride(from:Int(outputRate*0.7),to:min(samples.count-window,Int(outputRate*(descending ? 23.8 : 7.8))),by:window) {
  let rms=sqrt(samples[start..<start+window].reduce(0.0){$0+Double($1*$1)}/Double(window));minimum=min(minimum,rms)
  if rms<0.002 {quiet+=1;print("GAP",Double(start)/outputRate,rms)}
 }
 if descending, let anchor=(field("headAudioClock",audio) as! [Int:(position:Double,host:UInt64)])[0] {
  let song=state.project.songs[0]
  let fragments=song.tempoAudioSegments(song.tracks[0].clips[0])
  var alignmentSamples=0, maximumSourceError=0.0
  for second in stride(from: 5.0, through: 23.0, by: 1.0) {
   let start=Int(second*outputRate), count=Int(outputRate*0.2)
   guard start+count<samples.count else {continue}
   let crossings=(start+1..<start+count).reduce(0){$0+(samples[$1-1]<=0 && samples[$1]>0 ? 1:0)}
   let measuredSource=(Double(crossings)/0.2-220)/120
   let host=capture.firstHost+AVAudioTime.hostTime(forSeconds:second+0.1)
   let position=anchor.position+(host>=anchor.host ? AVAudioTime.seconds(forHostTime:host-anchor.host) : -AVAudioTime.seconds(forHostTime:anchor.host-host))
   if let clip=fragments.first(where:{$0.startTime<=position && position<$0.startTime+$0.duration}) {
    let expectedSource=clip.sourceOffset+(position-clip.startTime)*clip.audioRate
    alignmentSamples += 1; maximumSourceError=max(maximumSourceError,abs(measuredSource-expectedSource))
    print("AUDIO_ALIGNMENT",second,"SOURCE_ERROR_SECONDS",measuredSource-expectedSource,"RATE",clip.audioRate)
   }
  }
  precondition(alignmentSamples == 19, "Measure audio alignment through the next tempo boundary")
  precondition(maximumSourceError < 0.15, "The audible source must stay aligned with the audio timeline after a large BPM descent")
 }
 let frequencyWindow=Int(outputRate*0.1)
 var frequencies=[Double](), largestBackwardStep=0.0
 for start in stride(from:Int(outputRate*0.7),to:min(samples.count-frequencyWindow,Int(outputRate*(descending ? 23.8 : 7.8))),by:frequencyWindow) {
  let crossings=(start+1..<start+frequencyWindow).reduce(0){$0+(samples[$1-1]<=0 && samples[$1]>0 ? 1:0)}
  let frequency=Double(crossings)*outputRate/Double(frequencyWindow)
  if ProcessInfo.processInfo.environment["JARAS_TEST_CAPTURE_PATH"] != nil { print("FREQUENCY",Double(start)/outputRate,frequency) }
  frequencies.append(frequency)
 }
 // Reject replay over successive windows rather than a single transition's
 // zero-crossing artifact. Silence is checked separately without smoothing.
 let smoothed=(1..<frequencies.count-1).map { frequencies[($0-1)...($0+1)].sorted()[1] }
 for (previous,current) in zip(smoothed,smoothed.dropFirst()) { largestBackwardStep=max(largestBackwardStep,previous-current) }
 print("SOURCE_BACKWARD_FREQUENCY_STEP",largestBackwardStep,"RAPID",rapid)
 precondition(largestBackwardStep<60,"Captured audio must not return to an earlier point of the rising source tone")
 print("LIVE_TEMPO",rate,"MIN_RMS",minimum,"QUIET_WINDOWS",quiet,"MAX_EDIT_SECONDS",maximumEditDuration,"MAX_UPDATE_SECONDS",maximumUpdateDuration)
 precondition(edits==times.count,"Every requested tempo edit must be processed without a long UI stall")
 precondition(maximumUpdateDuration<1,"Audio update must not stall the UI for a second")
 precondition(quiet==0,"Live BPM edits and tempo boundaries must not interrupt output")
 // Tempo clock protection must not swallow an actual user seek.
 let previousClock=(field("headAudioClock",audio) as! [Int:(position:Double,host:UInt64)])[0]!
 state.transport.position=0.5
 try audio.update(state,revision:UInt64(edits+1))
 let seekClock=(field("headAudioClock",audio) as! [Int:(position:Double,host:UInt64)])[0]!
 precondition(seekClock.host != previousClock.host && abs(seekClock.position-0.5)<0.000001,"Explicit seek must still reposition playback")
 state.transport.playing=false
 try audio.update(state,revision:UInt64(edits+1))
 precondition(engine.attachedNodes.compactMap{$0 as? AVAudioPlayerNode}.allSatisfy{!$0.isPlaying},"Tempo edits must not leave idle players rendering silence")
}
Task{@MainActor in do{try await run();exit(0)}catch{print(error);exit(1)}}
dispatchMain()
