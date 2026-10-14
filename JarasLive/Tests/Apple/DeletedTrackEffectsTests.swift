import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor func runDeletedTrackEffectsTests() async throws {
    guard let executablePath = ProcessInfo.processInfo.environment["JARAS_TEST_PYTHON"] else {
        throw ProjectError.invalid("The fixture needs JARAS_TEST_PYTHON")
    }
    let executable = URL(fileURLWithPath: executablePath)
    let worker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Apple/CatStemIdentityWorker.py")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deleted-track-fx-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Deleted track FX")
    var track = Track(id: UUID(), name: "Removable", role: .other)
    var settings = NativeFXSettings()
    settings.inserted = [NativeFXSettings.stemSeparator]
    settings.stemMix = NativeStemMix(); settings.stemSeparatorEnabled = false
    var delaySettings = NativeFXSettings(); delaySettings.delayEnabled = true; delaySettings.delayMix = 0
    let delay = NativeFXInstance(kind: "Delay", settings: delaySettings)
    settings.instances = [delay]; settings.inserted.append(delay.effectKey)
    track.fx = settings
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.01, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: directory.appendingPathComponent("source.wav"), settings: format.settings).write(from: pcm)
    var clip = AudioClip(id: UUID(), name: "Deleted item", startTime: 0, duration: 2, audioFile: AudioFile(path: "source.wav"))
    var itemFX = NativeFXSettings(); itemFX.instances = [delay]; itemFX.inserted = [delay.effectKey]
    clip.fx = itemFX; track.clips = [clip]
    project.songs[0].tracks = [track]
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    func stemNodes() -> [AVAudioUnitEffect] {
        engine.attachedNodes.compactMap { $0 as? AVAudioUnitEffect }.filter {
            $0.auAudioUnit.componentDescription.componentSubType == 0x43537435
        }
    }
    func ready(_ node: AVAudioUnitEffect) async throws {
        for _ in 0..<300 {
            if JarasStemSeparator.status(node)["ready"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProjectError.invalid("Fake worker did not become ready")
    }
    func startAfterPreviousExit(_ node: AVAudioUnitEffect) async throws {
        for _ in 0..<300 {
            do {
                try JarasStemSeparator.start(node, executable: executable, worker: worker, modelCache: directory)
                return
            } catch { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        throw ProjectError.invalid("Deleted track retained CatStem worker admission")
    }
    audio.open(directory: directory)
    try audio.update(snapshot, revision: 1)
    let chain = audio.effects(for: track.id)!
    let node = stemNodes().first!
    try await startAfterPreviousExit(node)
    defer { JarasStemSeparator.stop(node) }
    try await ready(node)
    let count = engine.attachedNodes.count
    snapshot.project.songs[0].tracks = []
    let began = ProcessInfo.processInfo.systemUptime
    try audio.update(snapshot, revision: 2)
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    guard JarasStemSeparator.status(node)["state"] as? String == "stopped", stemNodes().isEmpty else {
        throw ProjectError.invalid("Deleting a track left its CatStem worker connected and admitted")
    }
    precondition(engine.attachedNodes.count <= count - 2, "Delete must release CatStem and repeated native insert nodes")
    precondition(engine.attachedNodes.allSatisfy { !($0 is AVAudioPlayerNode) }, "Removed track item voices must not remain in the idle pool")
    precondition(audio.effects(for: track.id) == nil, "A removed track cannot expose a live effects chain to stale UI")
    precondition(elapsed < 0.5, "Delete must cancel the model asynchronously")
    let retiredCount = engine.attachedNodes.count
    // A delayed editor callback must not reactivate a deleted track's inserts.
    audio.previewFX(track.id, settings: settings)
    precondition(engine.attachedNodes.count == retiredCount && stemNodes().isEmpty)
    for revision in UInt64(3)...5 { try audio.update(snapshot, revision: revision) }
    precondition(engine.attachedNodes.count == retiredCount, "Unrelated edits cannot recreate retired processors")
    let replacement = JarasStemSeparator.makeNode()
    JarasStemSeparator.setOfflineRendering(replacement, enabled: true)
    try await startAfterPreviousExit(replacement)
    defer { JarasStemSeparator.stop(replacement) }
    try await ready(replacement)
    JarasStemSeparator.stop(replacement)
    // Undo reconstructs processors from the stored snapshot without rebuilding
    // the surrounding track connections or changing its saved settings.
    snapshot.project.songs[0].tracks = [track]
    try audio.update(snapshot, revision: 6)
    precondition(audio.effects(for: track.id) === chain)
    precondition(stemNodes().count == 1 && stemNodes()[0] !== node)
    precondition(engine.attachedNodes.count == count)
    print("DELETED_TRACK_RELEASES_FX_AND_CATSTEM_LEASE_STALE_EDITOR_IGNORED_UNDO_RESTORES_OK rate=\(rate)")
}

Task { @MainActor in
    do { try await runDeletedTrackEffectsTests(); exit(0) }
    catch { print("DELETED_TRACK_FX_ERROR", error); exit(1) }
}
dispatchMain()
