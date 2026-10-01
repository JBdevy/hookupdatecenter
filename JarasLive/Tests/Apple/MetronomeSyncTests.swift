import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
final class SyncCapture: @unchecked Sendable {
    let lock = NSLock()
    var left: [Float] = [], right: [Float] = []
    func append(_ b: AVAudioPCMBuffer) {
        guard let p = b.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        left.append(contentsOf: UnsafeBufferPointer(start:p[0],count:Int(b.frameLength)))
        right.append(contentsOf: UnsafeBufferPointer(start:p[1],count:Int(b.frameLength)))
    }
    func take() -> ([Float],[Float]) {
        lock.lock(); defer { lock.unlock() }
        let result = (left,right); left=[]; right=[]; return result
    }
}
final class TrackSyncCapture: @unchecked Sendable {
    let channel: Int
    init(channel: Int = 0) { self.channel = channel }
    let lock=NSLock()
    var hits:[Int64]=[]
    var last:Int64 = -1_000_000
    func append(_ buffer:AVAudioPCMBuffer,_ time:AVAudioTime) {
        guard let samples=buffer.floatChannelData?[channel] else { return }
        lock.lock(); defer {lock.unlock()}
        for i in 0..<Int(buffer.frameLength) where abs(samples[i])>0.005 {
            let frame=time.sampleTime+Int64(i)
            if frame-last>Int64(buffer.format.sampleRate*0.15) {hits.append(frame)}
            last=frame
        }
    }
    func take()->[Int64] {lock.lock();defer{lock.unlock()};let value=hits;hits=[];last = -1_000_000;return value}
}
@MainActor func run() async throws {
    let settings = MetronomeSettings.shared
    let saved = (settings.enabled,settings.preset,settings.mode,settings.gainA,settings.gainB,settings.output)
    defer { settings.enabled=saved.0; settings.preset=saved.1; settings.mode=saved.2; settings.gainA=saved.3; settings.gainB=saved.4; settings.output=saved.5 }
    settings.output = .stereo; settings.enabled=true; settings.preset="Digital"; settings.mode=1; settings.gainA = -6; settings.gainB = -6
    let engine = AVAudioEngine(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let rate = engine.outputNode.outputFormat(forBus:0).sampleRate
    let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
    let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(rate*4))!
    buffer.frameLength=buffer.frameCapacity
    let sound = try settings.sounds(sampleRate:rate).0
    let click = sound.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
    for c in 0..<2 {
        buffer.floatChannelData![c].initialize(repeating:0,count:Int(buffer.frameLength))
        for beat in 0..<8 { for i in click.indices { buffer.floatChannelData![c][Int(Double(beat)*rate/2)+i]=click[i]*0.25 } }
    }
    do { let file=try AVAudioFile(forWriting:directory.appendingPathComponent("click.wav"),settings:format.settings); try file.write(from:buffer) }
    let audio=StemAudioPlayback(engine:engine,realtime:true)
    audio.open(directory:directory)
    defer { audio.prepareForClosing() }
    var project=Project.empty(name:"Click sync")
    project.songs[0].bpm=120
    project.songs[0].parts=[Part(id:UUID(),name:"Test",startTime:0,endTime:4)]
    var track=Track(id:UUID(),name:"Click",role:.click)
    track.pan=1
    track.clips=[AudioClip(id:UUID(),name:"Click",startTime:0,duration:4,audioFile:AudioFile(path:"click.wav"))]
    let tempo = Double(ProcessInfo.processInfo.environment["JARAS_SYNC_TEMPO"] ?? "120")!
    if tempo != 120 {
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0, color: 0x999999, tempoBPM: tempo, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .relative, tempoReferenceBPM: 120)]
    }
    let changing = ProcessInfo.processInfo.environment["JARAS_SYNC_MARKERS"] == "1"
    if changing {
        project.songs[0].markers = [(0.0,120.0),(1.0,150.0),(2.6,90.0)].map { position,bpm in
            TimelineMarker(id:UUID(),name:"TEMPO",position:position,color:0x999999,tempoBPM:bpm,tempoBeats:4,tempoUnit:4,tempoTimebase:.relative,tempoReferenceBPM:120)
        }
    }
    let trackCount = Int(ProcessInfo.processInfo.environment["JARAS_SYNC_TRACKS"] ?? "1")!
    project.songs[0].tracks = (0..<trackCount).map { _ in
        var copy = track; copy.id = UUID(); copy.volume = 1 / Double(trackCount)
        copy.clips[0].id = UUID(); return copy
    }
    var snapshot=ShowSnapshot(project:project,transport:TransportState(playing:false,songId:project.songs[0].id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
    try audio.update(snapshot,revision:1)
    let members = Mirror(reflecting: audio).children
    let master = members.first { $0.label == "masterBus" }!.value as! AVAudioMixerNode
    let direct = members.first { $0.label == "metronomeRoute" }!.value as! AVAudioUnitEffect
    engine.mainMixerNode.outputVolume = 0
    let capture = TrackSyncCapture(channel: 1), clickCapture = TrackSyncCapture()
    master.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, time in capture.append(buffer, time) }
    direct.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, time in clickCapture.append(buffer, time) }
    let buses=Mirror(reflecting:audio).children.first{$0.label=="trackBuses"}!.value
    let trackCaptures=Mirror(reflecting:buses).children.map { entry -> (AVAudioMixerNode,TrackSyncCapture) in
        let bus=Array(Mirror(reflecting:entry.value).children)[1].value
        let mix=Mirror(reflecting:bus).children.first{$0.label=="mix"}!.value as! AVAudioMixerNode
        let capture=TrackSyncCapture()
        mix.installTap(onBus:0,bufferSize:512,format:nil){buffer,time in capture.append(buffer,time)}
        return (mix,capture)
    }
    defer { master.removeTap(onBus:0); direct.removeTap(onBus: 0); for (mix,_) in trackCaptures {mix.removeTap(onBus:0)} }
    for attempt in 0..<2 {
        try await Task.sleep(nanoseconds:700_000_000)
        _=capture.take(); _=clickCapture.take(); for (_,capture) in trackCaptures {_=capture.take()}
        snapshot.transport.playing=true; snapshot.transport.position=0
        let start=ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime-start < (changing ? 3.8 : 2.2) {
            snapshot.transport.position=ProcessInfo.processInfo.systemUptime-start
            try audio.update(snapshot,revision:1)
            try await Task.sleep(nanoseconds:16_666_667)
        }
        let metronome = clickCapture.take(), item = capture.take()
        print("SYNC_ONSETS attempt=\(attempt) metronome=\(metronome) item=\(item)")
        let trackHits=trackCaptures.map{$0.1.take()}
        var spread=0.0
        for hits in trackHits.dropFirst() {
            for (a,b) in zip(trackHits[0],hits) { spread=max(spread,abs(Double(a-b))/rate*1000) }
        }
        print("TRACK_ONSET_SPREAD_MS \(spread) counts=\(trackHits.map(\.count))")
        precondition(trackHits.allSatisfy { $0.count == metronome.count },"Every track must retain every attack")
        precondition(spread<0.1,"Tracks must follow the same timing at every marker")
        precondition(metronome.count>=3 && item.count>=3,"Both clicks must reach the final output mix")
        let offsets=metronome.map { beat in Double(item.min(by: { abs($0-beat) < abs($1-beat) })! - beat)/rate*1000 }
        print("CLICK_ITEM_ALIGNMENT_MS \(offsets)")
        // The time stretcher can reshape a transient by several milliseconds,
        // but must not add its whole processing window to the musical beat.
        precondition(offsets.allSatisfy{abs($0)<10},"Click file and metronome must share their audible beat")
        snapshot.transport.playing=false; try audio.update(snapshot,revision:1)
    }
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
