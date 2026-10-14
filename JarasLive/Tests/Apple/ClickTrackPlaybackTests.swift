import Foundation
import AVFoundation
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func runClickTrackPlaybackTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let asset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Apple/Resources/Click.mp3")
    try FileManager.default.copyItem(at: asset, to: directory.appendingPathComponent("Click.mp3"))
    // The command-line harness has no Xcode resource phase. Put the shipped
    // asset beside its temporary executable to exercise Bundle.main as well.
    let bundleAsset = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Click.mp3")
    precondition(bundleAsset.deletingLastPathComponent().lastPathComponent.hasPrefix("jaras-audio."))
    try FileManager.default.copyItem(at: asset, to: bundleAsset)
    defer { try? FileManager.default.removeItem(at: bundleAsset) }
    let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4))!
    silence.frameLength = silence.frameCapacity
    for channel in 0..<2 { silence.floatChannelData![channel].initialize(repeating: 0, count: Int(silence.frameLength)) }
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("silent.wav"), settings: format.settings)
        try file.write(from: silence)
    }
    for realtime in [false, true] { for customSound in [false, true] {
        var project = Project.empty(name: "Native Click PCM")
        project.songs[0].duration = 4
        project.songs[0].bpm = 120
        project.songs[0].parts = [Part(id: UUID(), name: "Click span", startTime: 0, endTime: 3)]
        var track = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: TrackKind.click.rawValue))
        if customSound { track.clickSound = AudioFile(path: "Click.mp3") }
        project.songs[0].tracks = [track]
        precondition(project.insertClickItems(track: track.id) == 1)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: realtime)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var transport = TransportState(playing: false, songId: project.songs[0].id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 1)
        transport.playing = true
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 1)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func capture() throws -> Float {
            var peak: Float = 0
            for _ in 0..<Int(rate * 2 / 512) {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                for c in 0..<2 { for i in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![c][i])) } }
            }
            return peak
        }
        let peak = try capture()
        print("CLICK_TRACK_PLAYBACK_PCM", "realtime", realtime, "custom", customSound, "rate", rate, "peak", peak)
        guard peak > 0.1 else { throw ProjectError.invalid("Native Click track did not reach the output") }
        transport.playing = false
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 1)
        transport.playing = true
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 1)
        guard try capture() > 0.1 else { throw ProjectError.invalid("Native Click did not resume after Stop") }
        project.songs[0].tracks[0].clips.removeAll()
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 2)
        guard try capture() < 0.00001 else { throw ProjectError.invalid("Removed native Click items must be silent") }
        precondition(project.insertClickItems(track: track.id) == 1)
        transport.playing = false
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 3)
        transport.playing = true
        try audio.update(ShowSnapshot(project: project, transport: transport), revision: 3)
        guard try capture() > 0.1 else { throw ProjectError.invalid("Inserting native Click items again must restore their PCM") }
    } }
    // Production normally inserts the special track into an already running
    // project. Existing normal tracks and bus connections must remain valid.
    var project = Project.empty(name: "Insert native Click while playing")
    project.songs[0].duration = 4; project.songs[0].bpm = 120
    project.songs[0].parts = [Part(id: UUID(), name: "Span", startTime: 0, endTime: 3)]
    project.songs[0].tracks = (0..<24).map { index in
        var track = Track(id: UUID(), name: "Stem \(index)", role: .other)
        if index == 0 {
            track.clips = [AudioClip(id: UUID(), name: "Silent", startTime: 0, duration: 4,
                                    audioFile: AudioFile(path: "silent.wav"))]
        }
        return track
    }
    let core = JarasCoreBridge()
    try core.load(projectData: JSONEncoder().encode(project))
    try core.execute(command: "play", target: nil, value: 0)
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    defer { audio.prepareForClosing() }
    func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
    try audio.update(snapshot(), revision: 1)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    for _ in 0..<16 { _ = try engine.renderOffline(512, to: output) }
    print("CLICK_DYNAMIC_EXISTING_GRAPH_RENDERED", rate)
    let clickID = UUID()
    try core.addTrack(id: clickID.uuidString, name: "Click", role: TrackKind.click.rawValue)
    try audio.update(snapshot(), revision: 2)
    print("CLICK_DYNAMIC_TRACK_ADDED", rate)
    project = try snapshot().project
    precondition(project.insertClickItems(track: clickID) == 1)
    try core.applyProjectEdit(JSONEncoder().encode(project))
    try audio.update(snapshot(), revision: 3)
    print("CLICK_DYNAMIC_ITEMS_INSERTED", rate)
    var peak: Float = 0
    for _ in 0..<Int(rate * 2 / 512) {
        let status = try engine.renderOffline(512, to: output)
        precondition(status == .success)
        for channel in 0..<2 { for frame in 0..<Int(output.frameLength) {
            peak = max(peak, abs(output.floatChannelData![channel][frame]))
        } }
    }
    print("CLICK_INSERT_IN_RUNNING_PROJECT_PCM", "rate", rate, "peak", peak)
    guard peak > 0.1 else { throw ProjectError.invalid("Native Click inserted into a running project did not reach the output") }
}
try MainActor.assumeIsolated { try runClickTrackPlaybackTests() }
