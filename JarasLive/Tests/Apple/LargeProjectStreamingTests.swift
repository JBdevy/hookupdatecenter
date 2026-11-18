// Opt-in hardware benchmark. Inputs are a local decoded project JSON and its
// original media directory; the fixture never writes into either location.
import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
@MainActor func run() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let json = env["CATLIVE_STRESS_PROJECT_JSON"], let folder = env["CATLIVE_STRESS_MEDIA_DIRECTORY"] else {
        fatalError("Set CATLIVE_STRESS_PROJECT_JSON and CATLIVE_STRESS_MEDIA_DIRECTORY")
    }
    let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: json)))
    guard let song = project.songs.first else { fatalError("The project must contain a song") }
    let position = Double(env["CATLIVE_STRESS_START_SECONDS"] ?? "0") ?? 0
    let seconds = max(5, min(120, Double(env["CATLIVE_STRESS_SECONDS"] ?? "20") ?? 20))
    let loopSeconds = max(0, Double(env["CATLIVE_STRESS_LOOP_SECONDS"] ?? "0") ?? 0)
    let baseline = env["CATLIVE_PREPARED_PLAYER_BASELINE"] == "1"
    let engine = AVAudioEngine()
    let audio = StemAudioPlayback(engine: engine, auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false) // Silence physical output, retaining the graph's actual processing.
    var failures: [String] = []
    audio.onError = { failures.append($0.localizedDescription) }
    try audio.startDeviceSession()
    let opening = ProcessInfo.processInfo.systemUptime
    try await audio.openPreparedProject(directory: URL(fileURLWithPath: folder), project: project)
    print("LARGE_OPEN_MS", (ProcessInfo.processInfo.systemUptime - opening) * 1000)
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: song.id, position: position, queue: QueueState(), loop: LoopState(enabled: loopSeconds > 0, start: position, end: position + loopSeconds),
        subPlay: SubPlayState(playing: false, position: 0)))
    let began = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1)
    if let task = try audio.pendingPlaybackPreparation(state, revision: 1) { await task.value }
    let graph = Mirror(reflecting: audio).children.first { $0.label == "engine" }!.value as! AVAudioEngine
    let master = Mirror(reflecting: audio).children.first { $0.label == "masterBus" }!.value as! AVAudioMixerNode
    let capture = JarasCaptureRing(channels: 2, capacity: 262144)
    capture.beginCapture()
    master.installTap(onBus: 0, bufferSize: 512, format: master.outputFormat(forBus: 0)) { buffer, _ in capture.push(buffer) }
    var samples = [Float](repeating: 0, count: 32768)
    var capturedFrames = 0, nonzeroFrames = 0
    var silentFrames = 0, longestSilence = 0
    var capturedPeak: Float = 0
    func drainCapture() {
        while true {
            let frames = samples.withUnsafeMutableBufferPointer { capture.readFrames($0.baseAddress!, maximum: 16384) }
            if frames == 0 { return }
            capturedFrames += Int(frames)
            for n in 0..<Int(frames) {
                let level = max(abs(samples[n * 2]), abs(samples[n * 2 + 1]))
                capturedPeak = max(capturedPeak, level)
                if level > 0.000001 { nonzeroFrames += 1; silentFrames = 0 }
                else if nonzeroFrames > 0 {
                    silentFrames += 1; longestSilence = max(longestSilence, silentFrames)
                }
            }
        }
    }
    for track in song.tracks { _ = audio.meter(for: track.id) }
    try await Task.sleep(nanoseconds: 250_000_000)
    let players = graph.attachedNodes.filter { $0 is AVAudioPlayerNode }.count
    precondition(baseline || players == 0, "Prepared voices must own no unused legacy player nodes")
    print("LARGE_PREPARED baseline=\(baseline) tracks=\(song.tracks.count) nodes=\(graph.attachedNodes.count) players=\(players) seconds=\(ProcessInfo.processInfo.systemUptime - began) footprint=\(footprint()) pcm=\(JarasPreparedClip.memoryDiagnostics()) failures=\(failures.count)")
    print("LARGE_OUTPUT_BEFORE", audio.bufferedAudioDiagnostics() ?? [:])
    let start = ProcessInfo.processInfo.systemUptime
    state.transport.playing = true
    try audio.update(state, revision: 1, sampledAt: start)
    print("LARGE_PLAY_START_MS", (ProcessInfo.processInfo.systemUptime - start) * 1000)
    var lastReport = start
    while ProcessInfo.processInfo.systemUptime - start < seconds {
        try await Task.sleep(nanoseconds: 40_000_000)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - start
        state.transport.position = position + (loopSeconds > 0 ? elapsed.truncatingRemainder(dividingBy: loopSeconds) : elapsed)
        if loopSeconds > 0 { state.transport.sectionJumpSerial = UInt64(elapsed / loopSeconds) }
        let updateBegan = ProcessInfo.processInfo.systemUptime
        try audio.update(state, revision: 1, sampledAt: now)
        let updateMs = (ProcessInfo.processInfo.systemUptime - updateBegan) * 1000
        if updateMs > 30 { print("LARGE_SLOW_UPDATE seconds=\(elapsed) updateMs=\(updateMs) loop=\(state.transport.sectionJumpSerial ?? 0)") }
        drainCapture()
        if now - lastReport >= 5 {
            lastReport = now
            print("LARGE_PLAYING seconds=\(now - start) audible=\(song.tracks.filter { audio.meter(for: $0.id).level > 0.0001 }.count) footprint=\(footprint()) pcm=\(JarasPreparedClip.memoryDiagnostics())")
            print("LARGE_OUTPUT", audio.bufferedAudioDiagnostics() ?? [:])
        }
    }
    print("LARGE_OUTPUT_FINAL", audio.bufferedAudioDiagnostics() ?? [:])
    drainCapture()
    print("LARGE_CAPTURE frames=\(capturedFrames) nonzeroFrames=\(nonzeroFrames) peak=\(capturedPeak) longestSilenceFrames=\(longestSilence)")
    precondition(capturedFrames > 0 && nonzeroFrames > 0, "Moving meters alone do not prove actual output PCM")
    if env["CATLIVE_STRESS_REQUIRE_HEALTHY"] == "1" {
        let diagnostics = audio.bufferedAudioDiagnostics() ?? [:]
        precondition((diagnostics["underruns"] as? NSNumber)?.intValue == 0, "The output must meet every hardware deadline")
        precondition((diagnostics["renderFailures"] as? NSNumber)?.intValue == 0, "Every graph render must succeed")
        precondition(failures.isEmpty, "Playback must not report source/preparation failures")
    }
    state.transport.playing = false
    try audio.update(state, revision: 1)
    audio.stop()
    master.removeTap(onBus: 0)
    print("LARGE_STOPPED footprint=\(footprint()) failures=\(failures)")
    // Exit the isolated benchmark after Stop; do not include disposal of
    // thousands of platform nodes in the measured playback/preparation times.
    exit(0)
}
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("LARGE_ERROR", error); exit(1) }
}
dispatchMain()
