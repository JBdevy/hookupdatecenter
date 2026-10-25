import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor func runCatStemProjectCloseTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    for master in [true, false] {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: true)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Close CatStem")
        let track = Track(id: UUID(), name: "Track", role: .other)
        project.songs[0].tracks = [track]
        let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        audio.open(directory: directory)
        try audio.update(snapshot, revision: 1)
        var settings = NativeFXSettings()
        settings.inserted = [NativeFXSettings.stemSeparator]
        settings.stemMix = NativeStemMix(); settings.stemSeparatorEnabled = true
        audio.previewFX(master ? nil : track.id, settings: settings)
        let nodes = engine.attachedNodes.compactMap { $0 as? AVAudioUnitEffect }.filter {
            $0.auAudioUnit.componentDescription.componentSubType == 0x43537435 // CSt5
        }
        precondition(nodes.isEmpty, "Opening a legacy project cannot start the removed realtime stage")
        precondition(audio.effects(for: master ? nil : track.id)?.stemSeparatorLatency == 0)
        let start = ProcessInfo.processInfo.systemUptime
        audio.prepareForClosing()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 0.5, "Project close must signal cancellation without waiting for its worker")
        precondition(!engine.isRunning)
        print("CATSTEM_LEGACY_PROJECT_CLOSE_WITHOUT_WORKER_OR_LATENCY_OK master=\(master) rate=\(rate)")
    }
}

Task { @MainActor in
    do { try await runCatStemProjectCloseTests(); exit(0) }
    catch { print("CATSTEM_PROJECT_CLOSE_ERROR", error); exit(1) }
}
dispatchMain()
