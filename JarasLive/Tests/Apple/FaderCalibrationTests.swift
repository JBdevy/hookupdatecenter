import Foundation
import AVFoundation

@MainActor func checkFaders() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 20))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0.1, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    var p = Project.empty(name: "Fader calibration")
    let group = Track(id: UUID(), name: "Group", role: .other)
    var track = Track(id: UUID(), name: "Track", role: .other)
    track.parentTrackID = group.id; track.outputs = [.masterGroup]
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 20, audioFile: AudioFile(path: "tone.wav"))]
    p.songs[0].tracks = [group,track]
    var time = p.songs[0].projectTime; time.timebase = .free; p.songs[0].timeSettings = time
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    audio.open(directory: folder)
    let state = ShowSnapshot(project: p, transport: TransportState(playing: true, songId: p.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    for (trackDB,groupDB,masterDB) in [(0.0,0.0,0.0),(-3,0,0),(-6,0,0),(-12,0,0),(6,0,0),(0,-3,0),(-3,-3,0),(0,0,-3)] {
        audio.previewVolume(track.id,gain:pow(10,trackDB/20))
        audio.previewVolume(group.id,gain:pow(10,groupDB/20))
        audio.previewVolume(nil,gain:pow(10,masterDB/20))
        for _ in 0..<64 { let status=try engine.renderOffline(512,to:buffer); precondition(status == .success) }
        let measured=20*log10(Double(abs(buffer.floatChannelData![0][400]))/0.1)
        precondition(abs(measured-trackDB-groupDB-masterDB)<0.01,"fader mismatch: measured \(measured), target \(trackDB+groupDB+masterDB)")
        print("FADER_PCM_DB_OK rate=\(rate) track=\(trackDB) group=\(groupDB) master=\(masterDB) measured=\(measured)")
    }
}
try MainActor.assumeIsolated { try checkFaders() }
