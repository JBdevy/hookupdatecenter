import XCTest
import AVFoundation
import ImageIO
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
    func testVideoUsesAnyExistingTrackOrCreatesStandardTrackAndMixedBatchesFail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await video(root.appendingPathComponent("Source"))
        let destination = root.appendingPathComponent("Project/Show.jl")
        let audio = try StemImportTests().fixture(root, folder: "Source", file: "Audio.wav").appendingPathComponent("Audio.wav")
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([audio, source], start: 0, destinationTracks: [], destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        let created = try StemProjectImporter.prepareDroppedAudio([source], start: 0, destinationTracks: [], destination: destination)
        XCTAssertEqual(created.tracks[0].kind, .standard)
        for kind in TrackKind.allCases {
            let id = UUID()
            let imported = try StemProjectImporter.prepareDroppedAudio([source], start: 10, destinationTracks: [id], destination: destination, destinationKind: kind)
            XCTAssertEqual(imported.tracks[0].id, id)
            XCTAssertEqual(imported.tracks[0].kind, kind == .video ? .standard : kind)
            var project = Project.empty(name: "Video destination")
            project.songs[0].duration = 100
            project.songs[0].tracks = imported.tracks
            if kind != .standard && kind != .video { project.songs[0].tracks[0].name = kind.title }
            XCTAssertNoThrow(try project.validate(), "Video must be accepted on \(kind)")
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination.deletingLastPathComponent().appendingPathComponent(imported.tracks[0].clips[0].audioFile!.path)))
        }
        let second = root.appendingPathComponent("Source/Second.mov")
        try FileManager.default.copyItem(at: source, to: second)
        let target = UUID()
        let imported = try StemProjectImporter.prepareDroppedAudio([source,second], start: 10, destinationTracks: [target], destination: destination, layout: .sameTrack, gap: 3, destinationKind: .standard)
        XCTAssertEqual(imported.tracks.count, 1)
        let clips = imported.tracks[0].clips
        XCTAssertEqual(clips[1].startTime, clips[0].startTime + clips[0].duration + 3, accuracy: 0.00001)
        XCTAssertTrue(clips.allSatisfy { $0.isProjectionMedia && $0.waveform.isEmpty })
    }
    func testProjectionPriorityIsTrackOrderWithMutedAndInactiveItemsSkipped() {
        var project = Project.empty(name: "Projection order")
        let first = AudioClip(id: UUID(), name: "Top", startTime: 10, duration: 5, audioFile: AudioFile(path: "Videos/top.mov"))
        let second = AudioClip(id: UUID(), name: "Bottom", startTime: 10, duration: 5, audioFile: AudioFile(path: "Videos/bottom.mov"))
        var top = Track(id: UUID(), name: "Top track", role: .other); top.clips = [first]
        var bottom = Track(id: UUID(), name: "Bottom track", role: .other); bottom.clips = [second]
        project.songs[0].tracks = [top, bottom]
        XCTAssertEqual(project.songs[0].firstProjectionItem(at: 10)?.id, first.id)
        project.songs[0].tracks.reverse()
        XCTAssertEqual(project.songs[0].firstProjectionItem(at: 14.99)?.id, second.id)
        project.songs[0].tracks[0].clips[0].muted = true
        XCTAssertEqual(project.songs[0].firstProjectionItem(at: 10)?.id, first.id)
        project.songs[0].tracks[1].mute = true
        XCTAssertNil(project.songs[0].firstProjectionItem(at: 10))
        XCTAssertNil(project.songs[0].firstProjectionItem(at: 15))
        XCTAssertNil(project.songs[0].firstProjectionItem(at: .nan))
        XCTAssertNil(project.songs[0].firstProjectionItem(at: 10, trackKind: .teleprompt))
    }
    func testMovieAndImageResizeOnSpecialAndStandardTracks() throws {
        for kind: TrackKind in [.standard, .teleprompt, .chords, .timecode, .click] {
            var project = Project.empty(name: "Resize media")
            project.songs[0].duration = 100
            var track = Track(id: UUID(), name: kind.title, role: TrackRole(rawValue: kind.rawValue))
            let movie = AudioClip(id: UUID(), name: "Movie", startTime: 10, duration: 5, audioFile: AudioFile(path: "Videos/movie.mov"))
            let image = AudioClip(id: UUID(), name: "Image", startTime: 30, duration: 5, audioFile: AudioFile(path: "Videos/image.png"))
            track.clips = [movie, image]; project.songs[0].tracks = [track]
            project.resizeItem(movie.id, start: 11, end: 18)
            XCTAssertEqual(project.songs[0].tracks[0].clips[0].sourceOffset, 1)
            XCTAssertEqual(project.songs[0].tracks[0].clips[0].duration, 7)
            XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: project.songs[0].tracks[0].clips[0], visible: 0...100)), [15])
            project.resizeItem(image.id, start: 27, end: 38)
            XCTAssertEqual(project.songs[0].tracks[0].clips[1].duration, 11)
            XCTAssertEqual(project.songs[0].tracks[0].clips[1].sourceOffset, 2)
            XCTAssertEqual(project.songs[0].tracks[0].clips[1].loopLength, 5)
            XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: project.songs[0].tracks[0].clips[1], visible: 0...100)), [30,35])
            XCTAssertNoThrow(try project.validate())
            XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        }
    }
    func testMovieSoundtrackIsDecodedOnceAndSurvivesRemovingOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = try await video(root.appendingPathComponent("Source"))
        let sound = try StemImportTests().fixture(root, folder: "Source", file: "Sound.wav").appendingPathComponent("Sound.wav")
        let composition = AVMutableComposition()
        let movie = AVURLAsset(url: picture), audio = AVURLAsset(url: sound)
        let span = CMTimeRange(start: .zero, duration: movie.duration)
        let visual = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let acoustic = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try visual.insertTimeRange(span, of: movie.tracks(withMediaType: .video)[0], at: .zero)
        try acoustic.insertTimeRange(span, of: audio.tracks(withMediaType: .audio)[0], at: .zero)
        let combined = root.appendingPathComponent("Source/WithSound.mov")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        export.outputURL = combined; export.outputFileType = .mov
        await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let imported = try StemProjectImporter.prepareDroppedAudio([combined], start: 0, destinationTracks: [], destination: destination)
        let copied = destination.deletingLastPathComponent().appendingPathComponent(imported.tracks[0].clips[0].audioFile!.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Source"))
        let file = try AudioFileRead.openMedia(copied)
        XCTAssertGreaterThan(file.length, 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        XCTAssertTrue(try AudioFileRead.read(file, into: buffer))
        XCTAssertTrue((0..<Int(buffer.frameLength)).contains { abs(buffer.floatChannelData![0][$0]) > 0.0001 })
        let reopened = try AudioFileRead.openMedia(copied)
        XCTAssertEqual(reopened.length, file.length)
        XCTAssertEqual(reopened.url, file.url, "The movie soundtrack must reuse its decoded disk cache.")
    }
    func testImageAndVideoCopiesRemainUsableAfterOriginalRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = try await video(root.appendingPathComponent("Source"))
        let picture = root.appendingPathComponent("Source/image.png")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let writer = CGImageDestinationCreateWithURL(picture as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, nil); XCTAssertTrue(CGImageDestinationFinalize(writer))
        let document = root.appendingPathComponent("Project/Show.jl")
        for original in [movie, picture] {
            let data = try Data(contentsOf: original)
            let imported = try StemProjectImporter.prepareDroppedAudio([original], start: 0, destinationTracks: [UUID()], destination: document, layout: .sameTrack, destinationKind: .video)
            let path = try XCTUnwrap(imported.tracks.first?.clips.first?.audioFile?.path)
            XCTAssertTrue(path.hasPrefix("Videos/"))
            try FileManager.default.removeItem(at: original)
            XCTAssertEqual(try Data(contentsOf: document.deletingLastPathComponent().appendingPathComponent(path)), data)
        }
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
        XCTAssertTrue(imported.tracks[0].clips[0].audioFile!.path.hasPrefix("Stems/"))
        XCTAssertFalse(imported.tracks[0].clips[0].waveform.isEmpty)
    }
}
