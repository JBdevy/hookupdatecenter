import XCTest
import AVFoundation
@testable import JarasApplication

final class MediaDropRestrictionsTests: XCTestCase {
    private func video(_ root: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Video.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
        return url
    }
    func testVideoRequiresExistingVideoDestinationBeforeAnyCopiesAndMixedBatchesFail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await video(root.appendingPathComponent("Source"))
        let destination = root.appendingPathComponent("Project/Show.jl")
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([source], start: 0, destinationTracks: [], destination: destination)) { error in
            XCTAssertEqual(error.localizedDescription, "Create a Video track first, then drop the video on it")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([source], start: 0, destinationTracks: [UUID()], destination: destination, destinationKind: .standard, videoTrackAvailable: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        let audio = try StemImportTests().fixture(root, folder: "Source", file: "Audio.wav").appendingPathComponent("Audio.wav")
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([audio,source], start: 0, destinationTracks: [], destination: destination)) { error in
            XCTAssertEqual(error.localizedDescription, "Drop audio and video separately")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        let second = root.appendingPathComponent("Source/Second.mov")
        try FileManager.default.copyItem(at: source, to: second)
        let target = UUID()
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([source,second], start: 10, destinationTracks: [target], destination: destination, destinationKind: .video))
        let imported = try StemProjectImporter.prepareDroppedAudio([source,second], start: 10, destinationTracks: [target], destination: destination, layout: .sameTrack, gap: 3, destinationKind: .video)
        XCTAssertEqual(imported.tracks.count, 1); XCTAssertEqual(imported.tracks[0].id, target)
        XCTAssertEqual(imported.tracks[0].kind, .video)
        let clips = imported.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[1].startTime, clips[0].startTime + clips[0].duration + 3, accuracy: 0.00001)
        XCTAssertTrue(clips.allSatisfy { $0.audioFile?.path.hasPrefix("Videos/") == true && $0.waveform.isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appendingPathComponent("Steams").path))
        let tp = try StemProjectImporter.prepareDroppedAudio([source], start: 10, destinationTracks: [UUID()], destination: destination, destinationKind: .teleprompt)
        XCTAssertEqual(tp.tracks[0].kind, .teleprompt)
        XCTAssertEqual(tp.tracks[0].name, "Teleprompter 1")
        XCTAssertTrue(tp.tracks[0].clips[0].isProjectionMedia)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination.deletingLastPathComponent().appendingPathComponent(clips[0].audioFile!.path)))
    }
    func testAudioCannotEnterSpecialTracksAndUnknownFilesMakeNoProjectDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try StemImportTests().fixture(root, folder: "Source", file: "Audio.wav").appendingPathComponent("Audio.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        for kind: TrackKind in [.video,.timecode,.teleprompt] {
            XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([source], start: 0, destinationTracks: [UUID()], destination: destination, destinationKind: kind))
        }
        let unknown = root.appendingPathComponent("Source/Picture.png")
        try Data([1,2,3]).write(to: unknown)
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([source,unknown], start: 0, destinationTracks: [], destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testAudioOnlyMovieIsClassifiedFromItsTracksAndCopiedAsAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("Audio.m4a")
        do {
            let file = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410)!
            buffer.frameLength = 4410
            for frame in 0..<4410 { buffer.floatChannelData![0][frame] = 0.1 }
            try file.write(from: buffer)
        }
        let movie = root.appendingPathComponent("Audio.mp4")
        try FileManager.default.moveItem(at: audio, to: movie)
        let imported = try StemProjectImporter.prepareDroppedAudio([movie], start: 0, destinationTracks: [], destination: root.appendingPathComponent("Project/Show.jl"))
        XCTAssertEqual(imported.tracks[0].kind, .standard)
        XCTAssertTrue(imported.tracks[0].clips[0].audioFile!.path.hasPrefix("Steams/"))
        XCTAssertFalse(imported.tracks[0].clips[0].waveform.isEmpty)
    }
}
