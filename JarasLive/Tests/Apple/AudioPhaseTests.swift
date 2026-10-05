import Foundation
import AVFoundation
import Darwin

@MainActor func verifyPolarity() throws {
    setbuf(stdout, nil)
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(rate))!
    source.frameLength = source.frameCapacity
    for i in 0..<Int(source.frameLength) {
        source.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 431 * Double(i) / rate))
        source.floatChannelData![1][i] = Float(0.13 * cos(2 * .pi * 797 * Double(i) / rate))
    }
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("phase.wav"), settings: stereo.settings)
        try file.write(from: source)
    }
    func render(inverted: Bool, grouped: Bool, parentInverted: Bool = false,
                hardware: Bool, duplicate: Bool = false, live: Bool = false) throws -> [[Float]] {
        let engine = AVAudioEngine()
        let output = AVAudioFormat(standardFormatWithSampleRate: rate,
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Polarity verification")
        var track = Track(id: UUID(), name: "Stereo", role: .other)
        track.phaseInverted = live ? false : inverted
        track.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 1, audioFile: AudioFile(path: "phase.wav"))]
        track.patch = hardware ? OutputPatch(firstChannel: 3, channelCount: 2) : .master
        var tracks = [track]
        if duplicate {
            var copy = track; copy.id = UUID(); copy.clips[0].id = UUID(); copy.phaseInverted = !inverted
            tracks.append(copy)
        }
        if grouped {
            var parent = Track(id: UUID(), name: "Folder", role: .other)
            parent.phaseInverted = parentInverted; parent.patch = track.patch
            for i in tracks.indices { tracks[i].parentTrackID = parent.id; tracks[i].patch = .masterGroup }
            tracks.insert(parent, at: 0)
        }
        project.songs[0].tracks = tracks
        let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        try audio.update(snapshot, revision: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
        var samples = [[Float]](repeating: [], count: 4)
        for block in 0..<32 {
            if live && block == 8 { audio.previewPhase(track.id, inverted: inverted) }
            let status = try engine.renderOffline(512, to: buffer)
            precondition(status == .success)
            for ch in 0..<4 { samples[ch] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength))) }
        }
        return samples
    }
    for grouped in [false, true] { for hardware in [false, true] {
        let normal = try render(inverted: false, grouped: grouped, hardware: hardware)
        let reversed = try render(inverted: true, grouped: grouped, hardware: hardware)
        let live = try render(inverted: true, grouped: grouped, hardware: hardware, live: true)
        let null = try render(inverted: false, grouped: grouped, hardware: hardware, duplicate: true)
        let channels = hardware ? [2, 3] : [0, 1]
        for ch in channels {
            precondition(normal[ch].contains { abs($0) > 0.05 }, "both routed stereo channels must be audible")
            let error = zip(normal[ch], reversed[ch]).map { abs($0 + $1) }.max()!
            precondition(error < 0.00001, "polarity must reverse every PCM sample without changing its time: \(error)")
            precondition(null[ch].map(abs).max()! < 0.00001, "opposite tracks must cancel in both channels")
            precondition(zip(normal[ch].suffix(4096), live[ch].suffix(4096)).allSatisfy { abs($0 + $1) < 0.00001 }, "live polarity must settle to the same reversal")
        }
        if grouped {
            let twice = try render(inverted: true, grouped: true, parentInverted: true, hardware: hardware)
            for ch in channels { precondition(zip(normal[ch], twice[ch]).allSatisfy { abs($0 - $1) < 0.00001 }, "child and parent inversions must restore polarity") }
        }
    } }
    print("TRACK_POLARITY_STEREO_SAMPLE_NULL_LIVE_FOLDER_AND_HARDWARE_PCM_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try verifyPolarity() }
