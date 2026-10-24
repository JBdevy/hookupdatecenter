import AVFoundation
import Foundation

@MainActor func runInputMonitorMeterTests() async throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.onError = { fatalError($0.localizedDescription) }
    audio.open(directory: FileManager.default.temporaryDirectory)
    var project = Project.empty(name: "Armed input meters")
    let first = Track(id: UUID(), name: "Input one", role: .keys)
    let second = Track(id: UUID(), name: "Input two", role: .keys)
    project.songs[0].tracks = [first, second]
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0, queue: QueueState(),
        loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let firstMeter = audio.meter(for: first.id), secondMeter = audio.meter(for: second.id)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func source(_ value: Float) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { silent, _, frames, buffers in
            silent.pointee = false
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData!.assumingMemoryBound(to: Float.self).initialize(repeating: value, count: Int(frames))
            }
            return noErr
        }
    }
    func pump(_ seconds: Double) async throws {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            try audio.update(snapshot, revision: 1)
            try await Task.sleep(nanoseconds: 12_000_000)
        } while Date() < until
    }
    let firstInput = source(0.25), secondInput = source(0.125)
    audio.setInputMonitor(first.id, source: firstInput, format: format)
    try await pump(0.18)
    precondition(!snapshot.transport.playing && firstMeter.levels.x > 0.05,
                 "An armed audio input must meter while transport and recording are stopped")
    audio.setInputMonitor(second.id, source: secondInput, format: format)
    try await pump(0.18)
    precondition(secondMeter.levels.x > 0.03)
    audio.setInputMonitor(first.id, source: nil)
    try await pump(1.6)
    precondition(firstMeter.levels == .zero,
                 "Disarming one input must decay its level while another input remains armed")
    precondition(secondMeter.levels.x > 0.03,
                 "Disarming another track must preserve the active input meter")
    let beforeDisarm = secondMeter.level
    audio.setInputMonitor(second.id, source: nil)
    precondition(secondMeter.level == beforeDisarm, "The last input should descend rather than snap off")
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(secondMeter.level > 0 && secondMeter.level < beforeDisarm, "Idle UI clock must continue the short release without rendering audio")
    try await Task.sleep(nanoseconds: 500_000_000)
    precondition(firstMeter.levels == .zero && secondMeter.levels == .zero, "The idle release must end without leaving a stuck meter")
    try await pump(0.08)
    precondition(firstMeter.levels == .zero && secondMeter.levels == .zero,
                 "A stale render peak must not restore the disarmed meter")
    audio.setInputMonitor(first.id, source: source(0.08), format: format)
    try await pump(0.18)
    precondition(firstMeter.levels.x > 0.015 && firstMeter.levels.x < 0.12,
                 "Rearming must use the current signal rather than a stale held input")
    let beforeStop = firstMeter.level
    audio.setInputMonitor(first.id, source: nil)
    audio.stop()
    precondition(firstMeter.level == beforeStop, "Stop must preserve the first animation frame")
    try await Task.sleep(nanoseconds: 80_000_000)
    precondition(firstMeter.level > 0 && firstMeter.level < beforeStop, "Stop must finish the display descent without further audio callbacks")
    try await Task.sleep(nanoseconds: 550_000_000)
    precondition(firstMeter.levels == .zero && audio.masterMeter.levels == .zero)
    audio.prepareForClosing()
    print("INPUT_MONITOR_STOPPED_TRANSPORT_DISARM_ONE_LAST_AND_REARM_PCM_OK rate=\(rate)")
}

try await runInputMonitorMeterTests()
