import Foundation
import AVFoundation
@MainActor func run() throws {
    let engine=AVAudioEngine()
    let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
    try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:256)
    let renderer=StemAudioPlayback(engine:engine,realtime:false)
    let sf2=URL(fileURLWithPath:ProcessInfo.processInfo.environment["JARAS_TEST_SF2"]!)
    renderer.instrumentFile={_ in (sf2,false)}
    renderer.open(directory:FileManager.default.temporaryDirectory)
    var project=Project.empty(name:"MIDI playback test")
    var track=Track(id:UUID(),name:"Instrument",role:.keys)
    var fx=NativeFXSettings();fx.instrumentID="glide-moog";fx.inserted=["Instruments"];track.fx=fx
    track.clips=[AudioClip(id:UUID(),name:"MIDI",startTime:0,duration:2,midi:MIDIItem(notes:[MIDINote(start:0.2,length:0.8,pitch:60)]))]
    project.songs[0].tracks=[track];project.songs[0].duration=2
    var snapshot=ShowSnapshot(project:project,transport:TransportState(playing:false,songId:project.songs[0].id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0)))
    try renderer.update(snapshot,revision:1)
    let deadline=Date().addingTimeInterval(10)
    while !renderer.isInstrumentReady(track.id),Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    precondition(renderer.isInstrumentReady(track.id))
    snapshot.transport.playing=true
    try renderer.update(snapshot,revision:1)
    if !engine.isRunning {try engine.start()}
    let out=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:256)!
    var before=0.0,sounding=0.0
    for _ in 0..<150 {
        let time=Double(engine.manualRenderingSampleTime)/48000
        snapshot.transport.position=time;try renderer.update(snapshot,revision:1)
        guard try engine.renderOffline(256,to:out) == .success else {fatalError("render")}
        for f in 0..<Int(out.frameLength) {let v=abs(Double(out.floatChannelData![0][f]));if time<0.08{before=max(before,v)};if time>0.2&&time<0.4{sounding=max(sounding,v)}}
    }
    precondition(before<0.00001&&sounding>0.0001,"Full track MIDI route: silent=\(before) audible=\(sounding)")
    renderer.setLicenseAllowed(false)
    snapshot.transport.position=0.2;try renderer.update(snapshot,revision:1)
    var denied=0.0
    for _ in 0..<20 {try engine.renderOffline(256,to:out);for f in 0..<Int(out.frameLength){denied=max(denied,abs(Double(out.floatChannelData![0][f])))}}
    // Core Audio's mixer gain has a short dezipper; the final block must be zero.
    precondition((0..<Int(out.frameLength)).allSatisfy{abs(out.floatChannelData![0][$0])<0.000001},"License denial also silences MIDI")
    renderer.stop();engine.stop()
    print("MIDI_COMPLETE_TRACK_FX_AUDIO_ROUTING_NO_RECORD_ARM_AND_LICENSE_GATE_OK peak=\(sounding)")
}
try MainActor.assumeIsolated {try run()}
