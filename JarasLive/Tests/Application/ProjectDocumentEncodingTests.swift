import XCTest
@testable import JarasApplication

final class ProjectDocumentEncodingTests: XCTestCase {
    private func fixture(_ clips: [AudioClip]) -> Project {
        var project = Project.empty(name: "Encoding")
        project.songs[0].duration = 10_000
        var track = Track(id: UUID(), name: "Track", role: .other)
        track.clips = clips
        project.songs[0].tracks = [track]
        return project
    }
    private func clip(_ waveform: [Double], channels: [[Double]]? = nil) -> AudioClip {
        AudioClip(id: UUID(), name: "Clip", startTime: 0, duration: 2, waveform: waveform, waveformChannels: channels)
    }
    func testCompactWaveformsKeepAllMetadataEscapingAndOpaqueJSON() throws {
        let text = "Órgão 🎹 \\\"waveform\\\":[0.8] \n\t \\ / }], \"songs\":[{\"tracks\":[]}]"
        var source = fixture([clip([0.1, 0.7], channels: [[0.2, 0.3], [], [0.9]])])
        source.name = text
        source.songs[0].name = text
        source.songs[0].tracks[0].name = text
        source.songs[0].tracks[0].clips[0].name = text
        source.reductionDraft = .object([
            "waveform": .array([.number(0.6)]),
            "songs": .array([.object(["tracks": .array([.object(["clips": .array([.object([
                "waveformChannels": .array([.array([.number(0.4)])]), "name": .string(text)
            ])])])])])]),
            "string": .string(text)
        ])
        var fx = NativeFXSettings(); fx.eqEnabled = true; fx.bands[2].gain = 5
        source.songs[0].tracks[0].clips[0].fx = fx
        let original = source
        let compact = try ProjectDocumentJSON.encode(source)
        let generic = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: compact) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: generic) as? NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: compact), source)
        XCTAssertEqual(source, original, "Encoding must not strip previews from the live project")
    }
    func testChannelNilEmptyAndEmptyChannelsRetainTheirShape() throws {
        for nonempty in [false, true] {
            let source = fixture([
                clip(nonempty ? [0.1] : []), clip([], channels: []),
                clip([], channels: [[], []]), clip([0.1], channels: [[0.2], [], [0.3]])
            ].dropLast(nonempty ? 0 : 1).map { $0 })
            let decoded = try JSONDecoder().decode(Project.self, from: ProjectDocumentJSON.encode(source))
            XCTAssertEqual(decoded, source)
            XCTAssertNil(decoded.songs[0].tracks[0].clips[0].waveformChannels)
            XCTAssertEqual(decoded.songs[0].tracks[0].clips[1].waveformChannels, [])
            XCTAssertEqual(decoded.songs[0].tracks[0].clips[2].waveformChannels, [[], []])
        }
    }
    func testExtremesSignedZeroAndRepeatedArraysRoundTripExactBits() throws {
        let values: [Double] = [0, -0.0, .leastNonzeroMagnitude, .leastNormalMagnitude, .ulpOfOne, 1.nextDown, 1]
        let source = fixture([clip(values, channels: [values, values]), clip(values), clip([-0.0]), clip([0.0])])
        let compact = try ProjectDocumentJSON.encode(source)
        let decoded = try JSONDecoder().decode(Project.self, from: compact)
        for (before, after) in zip(source.songs[0].tracks[0].clips, decoded.songs[0].tracks[0].clips) {
            XCTAssertEqual(before.waveform.map(\.bitPattern), after.waveform.map(\.bitPattern))
            XCTAssertEqual(before.waveformChannels?.map { $0.map(\.bitPattern) }, after.waveformChannels?.map { $0.map(\.bitPattern) })
        }
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(source)), source)
    }
    func testUniqueArraysBeyondCacheLimitsStillRoundTrip() throws {
        let clips = (0..<1100).map { index in
            clip((0..<1024).map { Double(index * 1024 + $0) / 2_000_000 })
        }
        let source = fixture(clips)
        let encoded = try ProjectDocumentJSON.encode(source)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: encoded), source)
    }
    func testEncryptionNonceAuthenticationAndInvalidNumbersAreUnchanged() throws {
        let source = fixture([clip([0.1, 0.8], channels: [[0.2]])])
        let first = try ProjectDocumentCodec.encode(source)
        let second = try ProjectDocumentCodec.encode(source)
        XCTAssertNotEqual(first, second, "Every save must keep its fresh authenticated nonce")
        XCTAssertEqual(try ProjectDocumentCodec.decode(first), source)
        var damaged = first; damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(damaged))
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try ProjectDocumentCodec.encode(fixture([clip([invalid])])))
            XCTAssertThrowsError(try ProjectDocumentCodec.encode(fixture([clip([], channels: [[invalid]])])))
        }
    }
}
