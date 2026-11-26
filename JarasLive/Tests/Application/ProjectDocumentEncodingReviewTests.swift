import XCTest
@testable import JarasApplication

final class ProjectDocumentEncodingReviewTests: XCTestCase {
    func testMultipleSongsEmptyContainersRandomPeakBitsAndOpaqueFieldsSurvive() throws {
        var random: UInt64 = 0x6d3a_710c_902f_42b9
        let peaks = (0..<4096).map { _ -> Double in
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Double(bitPattern: random & 0x3fef_ffff_ffff_ffff)
        } + [0, -0.0, 1]
        let tricky = "\u{0000}\u{001F}\n\r\t🧩 música café e\u{0301} \\\" \\\\\" }}]},\"waveform\":[0.25],\"songs\":[{\"tracks\":[]}]}"
        var source = Project.empty(name: tricky)
        source.songs = [0, 3, 2, 0].enumerated().map { songIndex, trackCount in
            var song = Project.empty(name: "Song").songs[0]
            song.name = tricky + String(songIndex)
            song.tracks = (0..<trackCount).map { trackIndex in
                var track = Track(id: UUID(), name: tricky, role: .other)
                track.instrumentIcon = "future-icon-" + tricky
                track.pan = -0.125; track.heightScale = 1.25
                track.clips = (0..<(trackIndex == 0 ? 0 : 4)).map { clipIndex in
                    var clip = AudioClip(id: UUID(), name: tricky, startTime: Double(clipIndex) * 2, duration: 1,
                                         waveform: clipIndex == 1 ? [] : peaks)
                    clip.waveformChannels = clipIndex == 0 ? nil : clipIndex == 1 ? [] : [[], peaks, Array(peaks.reversed())]
                    clip.text = tricky; clip.playbackRate = 1.1598765432109876
                    clip.audioFile = AudioFile(path: "Stems/piano.wav")
                    clip.sourceOffset = 0.125; clip.pan = 0.375; clip.gain = 0.75
                    return clip
                }
                return track
            }
            return song
        }
        let opaque: PortableProjectJSON = .object([
            "songs": .array([.object(["tracks": .array([.object(["clips": .array([.object([
                "waveform": .array([.number(0.123)]), "waveformChannels": .array([.array([.number(0.25)])])])])])])])]),
            "waveform": .string(tricky), "waveformChannels": .null,
            "largeInteger": .integer(9_007_199_254_740_993), "largeUnsigned": .unsignedInteger(UInt64.max)
        ])
        source.windowsLighting = opaque; source.reductionDraft = opaque
        let before = source
        let bytes = try ProjectDocumentJSON.encode(source)
        let decoded = try JSONDecoder().decode(Project.self, from: bytes)
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(source, before, "saving cannot modify the live project's shared waveform storage")
        for (left, right) in zip(source.songs.flatMap(\.tracks).flatMap(\.clips), decoded.songs.flatMap(\.tracks).flatMap(\.clips)) {
            XCTAssertEqual(left.waveform.map(\.bitPattern), right.waveform.map(\.bitPattern))
            XCTAssertEqual(left.waveformChannels?.map { $0.map(\.bitPattern) }, right.waveformChannels?.map { $0.map(\.bitPattern) })
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? NSDictionary)
    }
}
