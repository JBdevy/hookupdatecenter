// Linked against the app's release objects to exercise both passes and file resolution.
import AVFoundation
import Foundation

private func verifyClickAfterAdjust(in folder: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16 * 48000)!
    buffer.frameLength = buffer.frameCapacity
    let samples = buffer.floatChannelData![0]
    samples.update(repeating: 0, count: Int(buffer.frameLength))
    for beat in 0..<32 {
        let start = 4800 + beat * 24000 + (beat % 3 - 1) * 640
        for i in 0..<128 { samples[start+i] = 0.6 * Float(128-i) / 128 }
    }
    let file = folder.appendingPathComponent("irregular-click.wav")
    do { let writer = try AVAudioFile(forWriting: file, settings: format.settings); try writer.write(from: buffer) }
    var project = Project.empty(name: "Recorded beat timing")
    var song = project.songs[0]; song.duration = 30
    let part = Part(id: UUID(), name: "A", startTime: 0, endTime: 16)
    song.parts = [part, Part(id: UUID(), name: "B", startTime: 19, endTime: 25)]
    song.markers = [(0.0,119.5),(8.0,121.5)].map { position,bpm in
        TimelineMarker(id: UUID(), name: "TEMPO", position: position, color: 0, regionOwnerID: part.id, tempoBPM: bpm, tempoPlaybackRate: 1)
    }
    song.tracks = ["Click","Percussion"].map { name in
        var track = Track(id: UUID(), name: name, role: name == "Click" ? .click : .other)
        track.clips = [AudioClip(id: UUID(), name: name, startTime: 0, duration: 16, audioFile: AudioFile(path: file.lastPathComponent))]
        return track
    }
    project.songs = [song]
    let target = 119.85
    let plan = try RegionBPMPlan.make(project: project, song: song, region: part.id, bpm: target)
    let adjusted = try plan.render(project: project, song: song, folder: folder, cancellation: AudioExportCancellation()) { _,_ in }
    let region = adjusted.song.parts[0]
    precondition(abs(adjusted.song.parts[1].startTime-region.endTime-3) < 1e-8)
    for track in adjusted.song.tracks {
        let path = track.clips[0].audioFile!.path
        let beats = try TimelineAudioWaveform.clickTransients(folder.projectMedia(path))
        precondition(beats.count == 32)
        for (i,pulse) in beats.enumerated() {
            precondition(abs(pulse.position-beats[0].position-Double(i)*60/target) < 0.003)
        }
    }
    let measured = try ClickTempoDetector.markersWithMeter(song: adjusted.song, region: region) { file in
        try TimelineAudioWaveform.clickTransients(folder.projectMedia(file.path)).map { .init(position: $0.position, peak: $0.peak) }
    }
    precondition(!measured.markers.isEmpty && measured.markers.allSatisfy { abs($0.tempoBPM!-target) < 0.03 })
    print("DETECT_RENDERED_CLICK_AND_ACCOMPANIMENT_FIXED_BEATS_OK")
}

@_cdecl("CatLiveRegionBPMTest")
func catLiveRegionBPMTest() -> Int32 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-bpm-qa-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        let stems = dir.appendingPathComponent("Stems")
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        let wav = stems.appendingPathComponent("Original.wav")
        let clock = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: clock, frameCapacity: 96000)!
        buffer.frameLength=96000
        for channel in 0..<2 { for i in 0..<96000 {
            buffer.floatChannelData![channel][i]=0.25 * Float(sin(Double(i) * 2 * .pi * Double(channel == 0 ? 440 : 220) / 48000))
        }}
        do { let source = try AVAudioFile(forWriting: wav,settings: clock.settings); try source.write(from: buffer) }
        var project=Project.empty(name: "QA")
        var song=project.songs[0];song.duration=10;song.bpm=120
        let part=Part(id: UUID(), name: "A", startTime: 0, endTime: 2)
        song.parts=[part,Part(id: UUID(), name: "B", startTime: 5, endTime: 8)]
        let a=TimelineMarker(id: UUID(),name:"90.5",position:0,color:0,regionOwnerID:part.id,tempoBPM:90.5,tempoPlaybackRate:1)
        var b=a;b.id=UUID();b.position=1;b.tempoBPM=150
        song.markers=[a,b]
        var track=Track(id: UUID(),name:"Music",role:.other)
        let clip=AudioClip(id: UUID(),name:"Original",startTime:0,duration:2,audioFile:AudioFile(path:"Stems/Original.wav"))
        let note = MIDINote(start: 0.25, length: 0.5, pitch: 61, velocity: 79)
        var keys = Track(id: UUID(), name: "Keys", role: .other)
        let loop = AudioClip(id: UUID(), name: "Keys loop", startTime: 0, duration: 2,
                             loopStart: 0, loopLength: 1, midi: MIDIItem(notes: [note]))
        keys.clips = [loop]
        track.clips=[clip];song.tracks=[track, keys];project.songs=[song]
        let plan=try RegionBPMPlan.make(project:project,song:song,region:part.id,bpm:120)
        var progress=0.0
        let result=try plan.render(project:project,song:song,folder:dir,cancellation:AudioExportCancellation()) { fraction,_ in
            precondition(fraction >= progress);progress=fraction
        }
        let adjusted=result.song.tracks[0].clips[0]
        let expected=(90.5+150.0)/120.0
        precondition(abs(adjusted.duration-expected)<1e-8 && abs(result.song.parts[1].startTime-expected-3)<1e-8)
        precondition(adjusted.id==clip.id && adjusted.name==clip.name && progress==1)
        let adjustedLoop = result.song.tracks[1].clips[0]
        let notes = adjustedLoop.midi!.notes
        precondition(adjustedLoop.loopLength == nil && notes.count == 2 && notes[0].id == note.id && notes[1].id != note.id)
        precondition(abs(notes[0].start - 0.25 * 90.5/120) < 1e-8 && abs(notes[1].start - 2*(90.5 + 0.125*150)/120) < 1e-8)
        let pcm=try AVAudioFile(forReading:dir.appendingPathComponent(adjusted.audioFile!.path))
        precondition(abs(Double(pcm.length)-expected*pcm.processingFormat.sampleRate)<1.1)
        let partBuffer=AVAudioPCMBuffer(pcmFormat:pcm.processingFormat,frameCapacity:4800)!
        for start in [0.3,1.3] {
            pcm.framePosition=Int64(start*pcm.processingFormat.sampleRate);try pcm.read(into:partBuffer,frameCount:4800)
            for ch in 0..<2 { var crossings=0;let data=partBuffer.floatChannelData![ch]
                for i in 1..<Int(partBuffer.frameLength) where data[i-1]<=0 && data[i]>0 { crossings+=1 }
                precondition(abs(crossings-(ch == 0 ? 44 : 22))<=2)
            }
        }
        let link=try LinkedStemMedia.shared.reference(to: wav, accessRoot: stems, video: false)
        precondition(dir.projectMedia(link).resolvingSymlinksInPath().standardizedFileURL.path==wav.resolvingSymlinksInPath().standardizedFileURL.path)
        var ready = false
        Task { @MainActor in
            await TimelineAudioWaveform.shared.preload([wav], cachedOnly: true)
            ready = true
        }
        let deadline=Date().addingTimeInterval(15)
        while !ready && Date()<deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        precondition(ready && TimelineAudioWaveform.hasCurrentPeakFile(wav))
        precondition(TimelineAudioWaveform.diskCacheURL(wav).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == stems.appendingPathComponent("WF",isDirectory:true).resolvingSymlinksInPath().standardizedFileURL.path)
        let voice = JarasPreparedClip(format: clock, timing: nil)
        try voice.prepare(wav, sourceFrame: 0, endFrame: 96000, rate: 1.05, pitch: 3, loopStart: 0, loopEnd: 0)
        try voice.prepare(wav, sourceFrame: 4800, endFrame: 96000, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
        project.songs=[result.song];_ = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        let stored = try FileManager.default.contentsOfDirectory(atPath:stems.path)
        precondition(stored.filter { $0.hasSuffix(".wav") }.count==2)
        try verifyClickAfterAdjust(in: dir)
        print("MAC_ADJUST_BPM_AND_LIVE_STRETCH_STEREO_REOPEN_STEMS_FRAMES_FREQUENCIES_FOLLOWING_GAP_OK")
        return 0
    } catch { fputs((error.localizedDescription+"\n"),stderr);return 1 }
}
