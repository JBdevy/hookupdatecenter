import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor func runCatStemProjectCloseTests() async throws {
    guard let executablePath = ProcessInfo.processInfo.environment["JARAS_TEST_PYTHON"] else {
        throw ProjectError.invalid("The fixture needs JARAS_TEST_PYTHON")
    }
    let executable = URL(fileURLWithPath: executablePath)
    let worker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Apple/CatStemIdentityWorker.py")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    func ready(_ node: AVAudioUnitEffect) async throws {
        for _ in 0..<300 {
            if JarasStemSeparator.status(node)["ready"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProjectError.invalid("Fake worker did not become ready: \(JarasStemSeparator.status(node))")
    }
    func startAfterPreviousExit(_ node: AVAudioUnitEffect) async throws {
        var latest: Error?
        for _ in 0..<300 {
            do {
                try JarasStemSeparator.start(node, executable: executable, worker: worker, modelCache: directory)
                return
            } catch { latest = error }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw latest ?? ProjectError.invalid("The preceding worker did not release its admission")
    }
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
        settings.stemMix = NativeStemMix(); settings.stemSeparatorEnabled = false
        audio.previewFX(master ? nil : track.id, settings: settings)
        let nodes = engine.attachedNodes.compactMap { $0 as? AVAudioUnitEffect }.filter {
            $0.auAudioUnit.componentDescription.componentSubType == 0x43537435 // CSt5
        }
        precondition(nodes.count == 1)
        let node = nodes[0]
        // Start the actual retained processor with a tiny protocol peer. This
        // exercises worker lifetime without loading an AI model or audio device.
        try await startAfterPreviousExit(node)
        defer { JarasStemSeparator.stop(node) }
        try await ready(node)
        let start = ProcessInfo.processInfo.systemUptime
        audio.prepareForClosing()
        let stopped = JarasStemSeparator.status(node)["state"] as? String == "stopped"
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        // Clean up even on the pre-fix run before reporting its regression.
        JarasStemSeparator.stop(node)
        let next = JarasStemSeparator.makeNode()
        JarasStemSeparator.setOfflineRendering(next, enabled: true)
        try await startAfterPreviousExit(next)
        defer { JarasStemSeparator.stop(next) }
        try await ready(next)
        JarasStemSeparator.stop(next)
        guard stopped else {
            throw ProjectError.invalid("Closing the project retained the \(master ? "master" : "track") CatStem worker")
        }
        precondition(elapsed < 0.5, "Project close must signal cancellation without waiting for its worker")
        precondition(!engine.isRunning)
        print("CATSTEM_PROJECT_CLOSE_CANCELS_WORKER_AND_RELEASES_ADMISSION_OK master=\(master) rate=\(rate)")
    }
}

Task { @MainActor in
    do { try await runCatStemProjectCloseTests(); exit(0) }
    catch { print("CATSTEM_PROJECT_CLOSE_ERROR", error); exit(1) }
}
dispatchMain()
