import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
private func require(_ value:Bool,_ message:String){if !value {print("FINAL_GAIN_FAILURE",message);exit(1)}}
private func signal(_ format:AVAudioFormat, amplitude:Float = 0.08)->AVAudioSourceNode {
    AVAudioSourceNode(format:format){silent,_,frames,buffers in
        silent.pointee=false
        for b in UnsafeMutableAudioBufferListPointer(buffers){b.mData!.assumingMemoryBound(to:Float.self).update(repeating:amplitude,count:Int(frames))}
        return noErr
    }
}
@MainActor private func fixture()->(ShowSnapshot,UUID) {
    var p=Project.empty(name:"Final gain regression")
    let t=Track(id:UUID(),name:"Signal",role:.keys);p.songs[0].tracks=[t];p.songs[0].duration=60
    return (ShowSnapshot(project:p,transport:TransportState(playing:false,songId:p.songs[0].id,position:0,queue:QueueState(),loop:LoopState(enabled:false),subPlay:SubPlayState(playing:false,position:0))),t.id)
}
@MainActor private func manual() throws {
    let f=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!,e=AVAudioEngine()
    try e.enableManualRenderingMode(.offline,format:f,maximumFrameCount:512)
    let a=StemAudioPlayback(engine:e,realtime:true);a.open(directory:FileManager.default.temporaryDirectory)
    defer{a.prepareForClosing()}
    var (s,t)=fixture();try a.update(s,revision:1)
    let source=signal(f);e.attach(source);e.connect(source,to:a.effects(for:t)!.instrumentInput,format:f);a.setArmedInstrumentTracks([t])
    let out=AVAudioPCMBuffer(pcmFormat:f,frameCapacity:512)!
    func render(_ n:Int=20)throws->Float {
        var peak:Float=0
        for _ in 0..<n {
            require(try e.renderOffline(512,to:out) == .success,"render failed")
            for ch in 0..<2 {for i in 0..<512 {peak=max(peak,abs(out.floatChannelData![ch][i]))}}
        }
        return peak
    }
    a.setLicenseAllowed(true);require(try render()>0.07,"must reach final output PCM")
    let identities=Set(e.attachedNodes.map(ObjectIdentifier.init))
    e.mainMixerNode.outputVolume=0
    _=try render(30);let silent=try render();require(e.isRunning && silent==0,"must reproduce transient silence while graph runs")
    s.transport.playing=true;try a.update(s,revision:1)
    let repaired=try render();print("FINAL_PCM_AFTER_PLAY gain=\(e.mainMixerNode.outputVolume) peak=\(repaired)")
    require(e.mainMixerNode.outputVolume==1 && repaired>0.07,"running Play must restore allowed final gain")
    require(Set(e.attachedNodes.map(ObjectIdentifier.init))==identities,"gain repair must retain all nodes")
    a.setLicenseAllowed(false);try a.update(s,revision:1)
    _=try render(30);let denied=try render();require(e.mainMixerNode.outputVolume==0 && denied==0,"license denial must stay silent")
    a.setLicenseAllowed(true);s.project.masterPatch=OutputPatch(firstChannel:3,channelCount:2);try a.update(s,revision:2);_=try render(30)
    require(try render()==0,"out-of-range patch must stay silent, without fallback")
    s.project.masterPatch=OutputPatch(firstChannel:1,channelCount:2);s.project.masterVolume=0.25;try a.update(s,revision:3);_=try render(30)
    let reduced=try render();require(reduced>0.019 && reduced<0.021,"Master fader must remain unchanged")
    s.project.masterMute=true;try a.update(s,revision:4);_=try render(30);require(try render()==0,"Master mute must remain unchanged")
    print("FINAL_GAIN_MATRIX_LICENSE_MASTER_OK")
}
@MainActor private func manyTracks() throws {
    let f=AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!,e=AVAudioEngine()
    try e.enableManualRenderingMode(.offline,format:f,maximumFrameCount:512)
    let a=StemAudioPlayback(engine:e,realtime:true);a.open(directory:FileManager.default.temporaryDirectory)
    defer{a.prepareForClosing()}
    var (s,_)=fixture(), voices:[UUID]=[], groups:[UUID]=[]
    s.project.songs[0].tracks=[]
    for index in 0..<4 {
        var parent:UUID?
        if index<3 {
            var group=Track(id:UUID(),name:"Group \(index)",role:.other)
            group.volume=0.5;parent=group.id;groups.append(group.id)
            s.project.songs[0].tracks.append(group)
        }
        for copy in 0..<24 {
            var track=Track(id:UUID(),name:"Copy \(index)/\(copy)",role:.keys)
            track.parentTrackID=parent;voices.append(track.id)
            s.project.songs[0].tracks.append(track)
        }
    }
    // Silent branches and more than sixteen members per group exercise the
    // intermediate fanout mixers together with direct Master sends.
    s.project.songs[0].tracks += (0..<32).map { Track(id:UUID(),name:"Empty \($0)",role:.other) }
    try a.update(s,revision:1)
    for id in voices {
        let source=signal(f,amplitude:0.001);e.attach(source)
        e.connect(source,to:a.effects(for:id)!.instrumentInput,format:f)
    }
    a.setArmedInstrumentTracks(Set(voices));a.setLicenseAllowed(true)
    let out=AVAudioPCMBuffer(pcmFormat:f,frameCapacity:512)!
    func peak() throws -> Float {
        var result:Float=0
        for n in 0..<40 {
            require(try e.renderOffline(512,to:out) == .success,"many-track render failed")
            if n>=30 { for ch in 0..<2 { for i in 0..<512 { result=max(result,abs(out.floatChannelData![ch][i])) } } }
        }
        return result
    }
    require(abs(try peak()-0.06)<0.001,"all 96 signals must reach the final PCM")
    for _ in 0..<3 {
        s.transport.playing=false;try a.update(s,revision:1)
        e.mainMixerNode.outputVolume=0;require(try peak()==0,"many-track zero gain reproduction")
        s.transport.playing=true;try a.update(s,revision:1)
        require(abs(try peak()-0.06)<0.001,"many-track Play must restore final PCM")
    }
    a.previewMute(groups[0],muted:true)
    require(abs(try peak()-0.048)<0.001,"group mute must preserve the other sends")
    a.previewMute(groups[0],muted:false)
    require(abs(try peak()-0.06)<0.001,"unmuting must restore all group copies")
    print("FINAL_GAIN_96_SIGNALS_GROUP_FANOUT_EMPTY_BRANCHES_STOP_START_OK")
}
@MainActor private func hardware() async throws {
    let e=AVAudioEngine() // An independent engine; never the app's engine.
    let audio=StemAudioPlayback(engine:e,auxiliarySelectedHardware:true)
    audio.setLicenseAllowed(false);try audio.startDeviceSession();audio.open(directory:FileManager.default.temporaryDirectory)
    defer{audio.prepareForClosing()}
    var (s,t)=fixture();try audio.update(s,revision:1)
    let f=e.mainMixerNode.outputFormat(forBus:0)
    // Capture AFTER main-mixer gain, then emit only zeros to hardware. This
    // does not change system output volume, preferences, or another app.
    e.stop()
    let probe=JarasChannelRouter.makeNode();e.attach(probe)
    JarasChannelRouter.configure(probe,first:-1,count:2);JarasChannelRouter.setInputMeteringEnabled(probe,enabled:true)
    e.connect(e.mainMixerNode,to:probe,format:f);e.connect(probe,to:e.outputNode,format:f)
    let stereo=AVAudioFormat(standardFormatWithSampleRate:f.sampleRate,channels:2)!,source=signal(AVAudioFormat(standardFormatWithSampleRate:f.sampleRate,channels:2)!)
    e.attach(source);e.connect(source,to:audio.effects(for:t)!.instrumentInput,format:stereo);audio.setArmedInstrumentTracks([t]);try e.start()
    require(e.outputConnectionPoints(for:e.mainMixerNode,outputBus:0).allSatisfy{$0.node === probe},"physical output must remain behind the silent probe")
    audio.setLicenseAllowed(true);try await Task.sleep(nanoseconds:100_000_000)
    require(JarasChannelRouter.takeInputPeak(probe,channel:0)>0.07,"post-mixer hardware capture must receive PCM")
    e.mainMixerNode.outputVolume=0;try await Task.sleep(nanoseconds:60_000_000);_=JarasChannelRouter.takeInputPeak(probe,channel:0)
    try await Task.sleep(nanoseconds:60_000_000);require(JarasChannelRouter.takeInputPeak(probe,channel:0)==0,"post-mixer capture must see zero gain")
    s.transport.playing=true;try audio.update(s,revision:1);try await Task.sleep(nanoseconds:100_000_000)
    let peak=JarasChannelRouter.takeInputPeak(probe,channel:0)
    require(e.mainMixerNode.outputVolume==1 && peak>0.07,"valid running hardware must restore final PCM")
    audio.setLicenseAllowed(false);try audio.update(s,revision:1);try await Task.sleep(nanoseconds:80_000_000);_=JarasChannelRouter.takeInputPeak(probe,channel:0)
    try await Task.sleep(nanoseconds:80_000_000);require(e.mainMixerNode.outputVolume==0 && JarasChannelRouter.takeInputPeak(probe,channel:0)==0,"hardware license denial must stay silent")
    print("FINAL_GAIN_HARDWARE_MUTED_PROBE_OK rate=\(f.sampleRate)")
}
@MainActor private func unavailableOutput() async throws {
    // A separate process supplies "none" through volatile arguments only.
    // The system's default device and the app's preferences are unchanged.
    let e=AVAudioEngine()
    let guarded=StemAudioPlayback(engine:e,auxiliarySelectedHardware:true)
    guarded.setLicenseAllowed(true)
    require(AudioDeviceSettings.shared.selectedUID=="none","fixture must have no permitted output")
    guarded.open(directory:FileManager.default.temporaryDirectory)
    defer{guarded.prepareForClosing()}
    let f=e.outputNode.inputFormat(forBus:0),probe=JarasChannelRouter.makeNode()
    e.attach(probe);JarasChannelRouter.configure(probe,first:-1,count:2)
    JarasChannelRouter.setInputMeteringEnabled(probe,enabled:true)
    let source=signal(AVAudioFormat(standardFormatWithSampleRate:f.sampleRate,channels:2)!)
    e.attach(source);e.connect(source,to:e.mainMixerNode,format:source.outputFormat(forBus:0))
    e.connect(e.mainMixerNode,to:probe,format:f);e.connect(probe,to:e.outputNode,format:f)
    try e.start();guarded.setLicenseAllowed(true)
    try guarded.startDeviceSession()
    var (state,_)=fixture();state.transport.playing=true;try guarded.update(state,revision:1)
    try await Task.sleep(nanoseconds:80_000_000)
    require(e.mainMixerNode.outputVolume==0 && JarasChannelRouter.takeInputPeak(probe,channel:0)==0,
            "missing selected output must stay silent even with permission and a live default device")
    print("FINAL_GAIN_UNAVAILABLE_OUTPUT_NO_FALLBACK_OK")
}
Task{@MainActor in
    do {
        if CommandLine.arguments.contains("--unavailable-output") {
            UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled":false,"jaras.audioOutputUID":"none","catlive.followSystemOutput":false],forName:UserDefaults.argumentDomain)
            try await unavailableOutput()
        } else {
            UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled":false],forName:UserDefaults.argumentDomain)
            try manual();try manyTracks();if !CommandLine.arguments.contains("--manual-only"){try await hardware()}
        }
        exit(0)
    }
    catch{print("FINAL_GAIN_ERROR",error);exit(1)}
}
dispatchMain()
