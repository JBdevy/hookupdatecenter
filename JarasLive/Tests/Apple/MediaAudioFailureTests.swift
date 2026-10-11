import Foundation
import AVFoundation

// Run with CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/MediaAudioFailureTests.swift
// bash scripts/test-offline-export.sh. Covers the actual live and export graphs.
@MainActor func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Videos"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let previousNoAudio = VideoMediaSettings.shared.noAudio
    VideoMediaSettings.shared.noAudio = false
    defer { VideoMediaSettings.shared.noAudio = previousNoAudio }
    let movie = root.appendingPathComponent("Videos/Silent.mov")
    let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
    writer.add(input)
    precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    for frame in 0..<3 {
        let deadline = Date().addingTimeInterval(2)
        while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(input.isReadyForMoreMediaData)
        precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
    }
    input.markAsFinished()
    await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
    precondition(writer.status == .completed)

    func project(_ path: String) -> Project {
        var value = Project.empty(name: "Media failure fixture")
        var track = Track(id: UUID(), name: "Media", role: .other)
        track.clips = [AudioClip(id: UUID(), name: path, startTime: 0, duration: 1, audioFile: AudioFile(path: path))]
        value.songs[0].tracks = [track]; value.songs[0].duration = 1
        return value
    }
    func snapshot(_ value: Project, playing: Bool) -> ShowSnapshot {
        ShowSnapshot(project: value, transport: TransportState(playing: playing, songId: value.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    for rate in [44100.0, 48000.0] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let tone = root.appendingPathComponent("tone-\(Int(rate)).wav")
        do {
            let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
            data.frameLength = data.frameCapacity
            for c in 0..<2 { for i in 0..<Int(data.frameLength) { data.floatChannelData![c][i] = 0.1 * sin(Float(i) * 0.13) } }
            let output = try AVAudioFile(forWriting: tone, settings: format.settings); try output.write(from: data)
        }
        for idle in [false, true] {
            for corrupt in [false, true] {
                let path = "Videos/\(Int(rate))-\(idle)-\(corrupt).wav"
                let url = root.appendingPathComponent(path)
                if corrupt { try Data("invalid media".utf8).write(to: url) }
                let value = project(path)
                let engine = AVAudioEngine(); try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
                let audio = StemAudioPlayback(engine: engine, realtime: false); audio.open(directory: root)
                defer { audio.prepareForClosing() }
                var reported: [Error] = []
                audio.onError = { reported.append($0) }
                if idle {
                    try audio.update(snapshot(value, playing: false), revision: 1)
                    let deadline = Date().addingTimeInterval(3)
                    while reported.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                    precondition(reported.count == 1, "Stopped prewarming must report inaccessible/undecodable movie soundtracks")
                } else {
                    do { try audio.update(snapshot(value, playing: true), revision: 1); fatalError("Broken video audio must throw during scheduling") }
                    catch { precondition(!AudioFileRead.isVideoWithoutAudio(error)) }
                    try audio.update(snapshot(value, playing: false), revision: 1)
                }
                if corrupt { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: tone, to: url)
                try audio.update(snapshot(value, playing: true), revision: 2)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
                var peak: Float = 0
                for _ in 0..<48 {
                    if try engine.renderOffline(256, to: pcm) == .success {
                        for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(pcm.floatChannelData![0][i])) }
                    }
                }
                precondition(peak > 0.09, "Fixing the same file must restore PCM; errors must never poison the silent-video cache")
                print("MEDIA_LIVE_ERROR_REPAIR_PCM_OK", rate, idle, corrupt, peak)
            }
        }
        // A real silent movie and an image must remain valid visual items.
        for path in ["Videos/Silent.mov", "Videos/Visual.png"] {
            let value = project(path)
            let engine = AVAudioEngine(); try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
            let audio = StemAudioPlayback(engine: engine, realtime: false); audio.open(directory: root)
            try audio.update(snapshot(value, playing: true), revision: 1)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
            for _ in 0..<8 {
                if try engine.renderOffline(256, to: pcm) == .success {
                    precondition((0..<Int(pcm.frameLength)).allSatisfy { abs(pcm.floatChannelData![0][$0]) < 1e-7 })
                }
            }
            audio.prepareForClosing()
        }
        func export(_ value: Project, _ folder: String) throws -> [Float] {
            let song = value.songs[0]
            let plan = AudioExportPlan(project: value, song: song, source: .master, bounds: .area, template: "%track", tracks: [], clips: [], regions: [], area: 0...0.4)
            try OfflineAudioExport.run(project: value, song: song, plan: plan, mediaDirectory: root, outputDirectory: root.appendingPathComponent(folder), sampleRate: rate, cancellation: AudioExportCancellation()) { _ in }
            let file = try AVAudioFile(forReading: root.appendingPathComponent(folder).appendingPathComponent(plan.jobs[0].fileName))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        for (i, path) in ["Videos/Missing.mov", "Videos/Corrupt.mov", "Stems/Missing.wav"].enumerated() {
            if path.contains("Corrupt") { try Data("invalid movie".utf8).write(to: root.appendingPathComponent(path)) }
            let folder = "bad-export-\(Int(rate))-\(i)"
            do { _ = try export(project(path), folder); fatalError("Invalid media must fail export instead of creating silent audio") }
            catch { precondition(!AudioFileRead.isVideoWithoutAudio(error)) }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
            precondition(remaining.isEmpty, "Failed export must roll back its output")
        }
        for (i, path) in ["Videos/Silent.mov", "Videos/Visual.png"].enumerated() {
            let samples = try export(project(path), "silent-\(Int(rate))-\(i)")
            precondition(samples.count == Int(rate * 0.4) && samples.allSatisfy { abs($0) < 1e-7 })
        }
        var click = Project.empty(name: "Custom click")
        var track = Track(id: UUID(), name: "Generated click", role: TrackRole(rawValue: "generatedClick"))
        track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 1)]
        track.clickSound = AudioFile(path: "MissingCustomClick.wav")
        click.songs[0].tracks = [track]; click.songs[0].duration = 1
        let missingFolder = "missing-click-\(Int(rate))"
        do { _ = try export(click, missingFolder); fatalError("Missing custom click must fail export") }
        catch { precondition(error.localizedDescription.contains("MissingCustomClick.wav"), "Missing click error must identify the file") }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(missingFolder).path)
        precondition(remaining.isEmpty)
        click.songs[0].tracks[0].clickSound = AudioFile(path: tone.lastPathComponent)
        let clickPCM = try export(click, "valid-click-\(Int(rate))")
        precondition(clickPCM.contains { abs($0) > 0.01 }, "Valid custom click must still render actual audio")
        print("MEDIA_EXPORT_ERRORS_ROLLBACK_VALID_SILENT_VIDEO_IMAGE_AND_CUSTOM_CLICK_OK", rate)
    }
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
