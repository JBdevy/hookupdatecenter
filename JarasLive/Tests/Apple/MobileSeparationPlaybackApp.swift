// Physical-device regression for silent live graphs after separation.
// Build with scripts/build-mobile-separation-playback-app.py, then sign/install
// the isolated test bundle. Documents/result.txt records PASS/FAIL and render
// diagnostics. CATLIVE_PROBE_COREML=1 additionally runs the bundled model;
// CATLIVE_PROBE_COREML_REPEATS=3 exercises longer idle inference. The default
// cold mode performs no test-only graph resets, so recovery must be production.
import Foundation
import AVFoundation
import Darwin
import UIKit

struct MobileSeparationPlaybackRegression {
@MainActor static func run(log: @escaping (String) -> Void) async throws {
    setbuf(stdout, nil)
    UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
    let rate = 44100.0
    let settings = AudioDeviceSettings.shared
    settings.mobileSessionEvent = { event in log("SESSION_EVENT \(event)") }
    try AVAudioSession.sharedInstance().setPreferredSampleRate(48000)
    try settings.activateLocalSession()
    try await Task.sleep(nanoseconds: 500_000_000)
    settings.finishLocalRouteChange()
    let hardwareRate = AVAudioSession.sharedInstance().sampleRate
    log("SESSION rate=\(hardwareRate) channels=\(AVAudioSession.sharedInstance().outputNumberOfChannels) outputs=\(AVAudioSession.sharedInstance().currentRoute.outputs)")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-separation-playback-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![channel][frame] = (channel == 0 ? 0.08 : 0.12) * sin(Float(frame) * 0.07)
    } }
    do { let file = try AVAudioFile(forWriting: directory.appendingPathComponent("input.wav"), settings: format.settings); try file.write(from: buffer) }
    var project = Project.empty(name: "Separation live graph regression")
    var track = Track(id: UUID(), name: "Original", role: .other)
    let original = AudioClip(id: UUID(), name: "Input", startTime: 0, duration: 10, audioFile: AudioFile(path: "input.wav"))
    track.clips = [original]; project.songs[0].tracks = [track]
    let engine = settings.engine
    let driver = JarasMobileAudioOutput(engine: engine)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    audio.open(directory: directory)
    try audio.startDeviceSession()
    defer { driver.stop(); audio.prepareForClosing() }
    var revision: UInt64 = 1
    var state = TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func update() throws { try audio.update(ShowSnapshot(project: project, transport: state), revision: revision) }
    func check(_ label: String, audible: Bool, requiredTrack: UUID? = nil) async throws {
        var peak = 0.0, trackPeak = 0.0, requiredTrackPeak = 0.0
        log("DRIVER_BEFORE \(label) \(driver.diagnostics())")
        log("SESSION_FLAGS output=\(settings.selectedUID) enabled=\(settings.localSessionEnabled) license=\(AudioLicenseAccess.shared.allowed) masterVolume=\(engine.mainMixerNode.outputVolume) sync=\(ProcessInfo.processInfo.environment["CATLIVE_AUDIO_SYNC_DIAGNOSTICS"] ?? "unset")")
        let beforeClock = driver.renderTime
        let beforeRender = engine.manualRenderingSampleTime
        let started = ProcessInfo.processInfo.systemUptime
        for tick in 0..<90 {
            try update()
            if tick >= 35 {
                peak = max(peak, audio.masterMeter.level)
                for track in project.songs[0].tracks { trackPeak = max(trackPeak, audio.meter(for: track.id).level) }
                if let requiredTrack { requiredTrackPeak = max(requiredTrackPeak, audio.meter(for: requiredTrack).level) }
            }
            if state.playing { state.position = ProcessInfo.processInfo.systemUptime - started }
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        let properties = Mirror(reflecting: audio).children.filter { ["tracks", "clips", "voices", "directory", "deviceSessionActive", "renderEnabled", "transportWasRunning", "songID", "revision", "lastPosition", "missingAudioPaths"].contains($0.label ?? "") }.map { entry in
            let value = Mirror(reflecting: entry.value)
            return (entry.label ?? "?") + ": " + ((value.displayStyle == .dictionary || value.displayStyle == .collection || value.displayStyle == .set) ? "count=\(value.children.count)" : String(describing: entry.value))
        }
        log("GRAPH_PROPERTIES \(label) " + properties.joined(separator: "; "))
        log("DRIVER_AFTER \(label) \(driver.diagnostics())")
        let afterClock = driver.renderTime
        let rendered = engine.manualRenderingSampleTime - beforeRender
        log("MOBILE_SEPARATION_GRAPH \(label) masterPeak=\(peak) trackPeak=\(trackPeak) engine=\(engine.isRunning) renderFrames=\(rendered) hardwareClockBefore=\(beforeClock?.description ?? "nil") hardwareClockAfter=\(afterClock?.description ?? "nil") sessionEnabled=\(settings.localSessionEnabled) interrupted=\(settings.localSessionInterrupted) reconfiguring=\(settings.localSessionReconfiguring)")
        guard rendered > 0, afterClock?.hostTime != beforeClock?.hostTime else { throw NSError(domain: "AudioProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No render callbacks: " + label]) }
        if requiredTrack != nil {
            log("REQUIRED_TRACK_PEAK \(label) \(requiredTrackPeak)")
            guard requiredTrackPeak > 0.005 else { throw NSError(domain: "AudioProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "New track is not rendering: " + label]) }
        }
        guard audible ? peak > 0.01 : peak < 0.0001 else { throw NSError(domain: "AudioProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected level: " + label]) }
    }
    try update()
    let baselineMode = ProcessInfo.processInfo.environment["CATLIVE_PROBE_BASELINE_MODE"] ?? "cold"
    log("BASELINE_MODE " + baselineMode)
    if baselineMode != "cold" { try await check("initial stopped graph preparation", audible: false) }
    // Separate idle preparation from a deliberate baseline rebuild. No graph
    // reset is permitted after the mock separation has inserted its five tracks.
    if baselineMode == "restart" {
        driver.stop()
        try audio.reconfigureDevice()
    } else if baselineMode == "prepare" {
        engine.prepare()
    } else if baselineMode == "reconnect" {
        _ = try JarasAudioOutputConnection.connect(engine)
    } else if baselineMode == "pause" {
        driver.stop()
        engine.pause()
        engine.prepare()
        try engine.start()
        try driver.start()
    } else if baselineMode == "engine-restart" {
        driver.stop()
        engine.stop()
        engine.prepare()
        try engine.start()
        try driver.start()
    }
    state.playing = true
    try await check("before separation", audible: true)
    state.playing = false; state.position = 0
    try await check("stopped before offline export", audible: false)
    let job = AudioExportJob(id: original.id.uuidString, fileName: "prepared.wav", start: 0, end: 10, track: track.id, clip: original.id)
    let exportProject = project
    let exportTask = Task.detached {
        try OfflineAudioExport.run(project: exportProject, song: exportProject.songs[0], plan: AudioExportPlan(jobs: [job]), mediaDirectory: directory, outputDirectory: directory, sampleRate: rate, encoding: AudioExportEncoding(format: .wav, bitDepth: 32, sampleRate: rate), cancellation: AudioExportCancellation()) { _ in }
    }
    let idlePump = Task { @MainActor in
        while !Task.isCancelled { try update(); try await Task.sleep(nanoseconds: 16_666_667) }
    }
    defer { idlePump.cancel() }
    try await exportTask.value
    idlePump.cancel()
    try await check("after offline render before insertion", audible: false)
    let coreML = ProcessInfo.processInfo.environment["CATLIVE_PROBE_COREML"] == "1"
    let repeats = max(1, min(5, Int(ProcessInfo.processInfo.environment["CATLIVE_PROBE_COREML_REPEATS"] ?? "1") ?? 1))
    if coreML {
        let cancellation = AudioExportCancellation()
        let model = try CatStemRealtimeRuntime.modelURL()
        let coreMLTask = Task.detached {
            for iteration in 1...repeats {
                try Task.checkCancellation()
                try JarasStemSeparator.separateAudio(directory.appendingPathComponent("prepared.wav"),
                    outputDirectory: directory, coreMLModel: model,
                    cancellation: { cancellation.cancelled }, progress: { fraction in
                        Task { @MainActor in log("COREML iteration=\(iteration)/\(repeats) fraction=\(fraction)") }
                    })
            }
        }
        let coreMLIdlePump = Task { @MainActor in
            while !Task.isCancelled { try update(); try await Task.sleep(nanoseconds: 16_666_667) }
        }
        defer { coreMLIdlePump.cancel(); cancellation.cancel() }
        try await coreMLTask.value
        coreMLIdlePump.cancel()
        log("COREML_COMPLETED \(driver.diagnostics())")
    }
    var stems: [Track] = []
    for stem in CatStem.allCases {
        let path = coreML ? stem.rawValue + ".wav" : "prepared.wav"
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(path))
        guard file.length == 441000 else { throw NSError(domain: "AudioProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Wrong separated duration"]) }
        var item = AudioClip(id: UUID(), name: stem.rawValue + " - Input", startTime: 0, duration: 10, audioFile: AudioFile(path: path))
        item.gain = coreML ? 1 : 0.2; item.renderedTempo = true
        var stemTrack = Track(id: UUID(), name: item.name, role: stem.role)
        stemTrack.clips = [item]; stems.append(stemTrack)
    }
    try project.insertSeparatedStems(stems, song: project.songs[0].id, sourceTrack: track.id, original: original)
    revision += 1; try update()
    try await check("stopped after insertion", audible: false)
    state.playing = true; state.position = 0
    try await check("after five-track insertion", audible: true)
    state.playing = false; state.position = 0
    try await check("Stop after insertion", audible: false)
    state.playing = true
    try await check("second Play without reopening", audible: true)
    state.playing = false; state.position = 0
    try await check("Stop before later track insertion", audible: false)
    var laterTrack = Track(id: UUID(), name: "Track added after playback", role: .other)
    var laterItem = original
    laterItem.id = UUID(); laterItem.gain = 0.1
    laterTrack.clips = [laterItem]
    project.songs[0].tracks.append(laterTrack)
    revision += 1; try update()
    try await check("stopped after later track insertion", audible: false)
    state.playing = true
    try await check("Play after later track insertion", audible: true, requiredTrack: laterTrack.id)
    log("MOBILE_SEPARATION_OFFLINE_INPUT_DYNAMIC_FIVE_TRACK_INSERT_AND_PLAY_OK")
}
}

@main final class App: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Audio regression", sessionRole: session.role)
        config.delegateClass = Scene.self
        return config
    }
}
final class Scene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var started = false
    let text = UITextView()
    var lines = [String]()
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene)
        let controller = UIViewController()
        text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.frame = window.bounds; text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(text)
        window.rootViewController = controller
        self.window = window; window.makeKeyAndVisible()
    }
    func append(_ line: String) {
        lines.append(line); print(line); text.text = lines.joined(separator: "\n")
        try? text.text.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }; started = true
        Task { @MainActor in
            append("MOBILE_SEPARATION_START os=\(UIDevice.current.systemVersion)")
            do { try await MobileSeparationPlaybackRegression.run(log: append); append("PASS") }
            catch { append("FAIL \(error)") }
        }
    }
}
