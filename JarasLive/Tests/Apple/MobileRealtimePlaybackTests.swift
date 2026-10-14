import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func verifyRealtimeMobileDriver() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!
    let hardware = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-patch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(rate * 15))!
    source.frameLength = source.frameCapacity
    source.floatChannelData![0].update(repeating: 0.08, count: Int(source.frameLength))
    source.floatChannelData![1].update(repeating: 0.12, count: Int(source.frameLength))
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("stereo.wav"), settings: stereo.settings)
        try file.write(from: source)
    }
    let engine = AVAudioEngine()
    let driver = JarasMobileAudioOutput(engine: engine)
    _ = try driver.configure(withSampleRate: rate, channels: 6)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    audio.open(directory: directory)
    defer { driver.stop(); audio.prepareForClosing() }
    var project = Project.empty(name: "iPad shared Patch PCM")
    let folder = Track(id: UUID(), name: "Folder", role: .other, volume: 0.5)
    var child = Track(id: UUID(), name: "Stereo source", role: .other)
    child.parentTrackID = folder.id
    child.outputs = [.masterGroup]
    child.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 15, audioFile: AudioFile(path: "stereo.wav"))]
    project.songs[0].tracks = [folder, child]
    try project.validate()
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 512)!
    buffer.frameLength = 512
    func check(_ expected: [Float], _ label: String) throws {
        var actual = Array(repeating: Float(0), count: 6)
        for block in 0..<30 {
            var stamp = AudioTimeStamp()
            stamp.mHostTime = mach_absolute_time()
            stamp.mSampleTime = Double(engine.manualRenderingSampleTime)
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            var flags = AudioUnitRenderActionFlags()
            precondition(driver.renderFrames(512, time: &stamp, flags: &flags, buffers: buffer.mutableAudioBufferList) == noErr)
            if block >= 16 {
                let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in 0..<6 { for frame in 0..<512 {
                    let samples = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    actual[channel] = max(actual[channel], abs(samples[frame]))
                } }
            }
            usleep(UInt32(512 / rate * 1_000_000))
        }
        precondition(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00005 }, "\(label): \(actual), expected \(expected)")
        print("MOBILE_REALTIME_GRAPH_PCM rate=\(rate) \(label): \(actual)")
    }
    try check([0.04, 0.06, 0, 0, 0, 0], "first Play group to Master")
    audio.previewPatches(child.id, patches: [OutputPatch(firstChannel: 3, channelCount: 2)])
    try check([0, 0, 0.08, 0.12, 0, 0], "direct 3+4")
    audio.previewPatches(child.id, patches: [.masterGroup, OutputPatch(firstChannel: 3, channelCount: 2)])
    try check([0.04, 0.06, 0.08, 0.12, 0, 0], "four simultaneous outputs")
    driver.gate(); driver.stop()
    audio.suspendDeviceSession()
    var stopped = snapshot; stopped.transport.playing = false
    audio.prepareAfterDeviceChange = { try audio.update(stopped, revision: 2) }
    try audio.reconfigureDevice()
    try check([0, 0, 0, 0, 0, 0], "stopped route recreation")
    var resumed = stopped; resumed.transport.playing = true
    try audio.update(resumed, revision: 2)
    try check([0.04, 0.06, 0, 0, 0, 0], "Play after reconnect")
}
try MainActor.assumeIsolated { try verifyRealtimeMobileDriver() }
