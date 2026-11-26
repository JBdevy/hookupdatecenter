import XCTest
@testable import JarasApplication

final class ProjectValidationCacheTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Validation reuse")
        project.songs[0].duration = 100
        var folder = Track(id: UUID(), name: "Folder", role: .other)
        folder.clips = [AudioClip(id: UUID(), name: "A", startTime: 10, duration: 20)]
        var child = Track(id: UUID(), name: "Child", role: .keys)
        child.parentTrackID = folder.id
        child.clips = [AudioClip(id: UUID(), name: "B", startTime: 40, duration: 20)]
        project.songs[0].tracks = [folder, child]
        return project
    }

    func testCachedMetadataStillValidatesGlobalRelationshipsAndChangedFields() throws {
        let baseline = fixture(), cache = ProjectValidationCache()
        try cache.validate(baseline)
        let changes: [(inout Project) -> Void] = [
            { $0.songs[0].duration = 50 },
            { $0.songs[0].tracks.removeFirst() },
            { $0.songs[0].tracks[1].id = $0.songs[0].tracks[0].id },
            { $0.songs[0].tracks[1].clips[0].id = $0.songs[0].tracks[0].clips[0].id },
            { $0.id = $0.songs[0].tracks[0].clips[0].id },
            { $0.songs[0].markers = [TimelineMarker(id: $0.songs[0].tracks[0].clips[0].id, name: "Duplicate", position: 0, color: 0)] },
            { $0.songs[0].tracks[0].clips[0].playbackRate = .nan },
            { $0.songs[0].tracks[0].clips[0].waveform = [.nan] },
            { $0.songs[0].tracks[0].clips[0].audioFile = AudioFile(path: "../outside.wav") },
            { $0.songs[0].tracks[0].clips[0].startTime = -1 },
            { $0.songs[0].tracks[0].pan = 2 },
            { $0.songs[0].tracks[0].color = 0xffffffff },
            { $0.songs[0].tracks[1].parentTrackID = UUID() }
        ]
        for (index, change) in changes.enumerated() {
            var invalid = baseline; change(&invalid)
            XCTAssertThrowsError(try invalid.validate(), "fixture \(index)")
            XCTAssertThrowsError(try cache.validate(invalid), "cached fixture \(index)")
            XCTAssertThrowsError(try cache.validate(invalid), "a rejected document cannot seed the cache")
            XCTAssertNoThrow(try cache.validate(baseline))
        }
    }

    func testWaveformCertificateNeverAllowsChangedSamplesAndMetadataRemainsReusable() throws {
        var original = fixture()
        original.songs[0].tracks[0].clips[0].waveform = [0.25, 0.75]
        let cache = ProjectValidationCache()
        try cache.validate(original)
        var metadata = original
        metadata.songs[0].tracks[0].clips[0].waveform = []
        try cache.validate(metadata)
        var corrupt = metadata
        corrupt.songs[0].tracks[0].clips[0].waveform = [0.25, 1.01]
        XCTAssertThrowsError(try cache.validate(corrupt))
        try cache.validate(original)
        try cache.validate(metadata)
        var copy = metadata
        _ = try copy.duplicateTracks([copy.songs[0].tracks[1].id], song: copy.songs[0].id)
        try cache.validate(copy)
        try cache.validate(metadata)
        var other = metadata; other.id = UUID()
        try cache.validate(other)
        try cache.validate(metadata)
        XCTAssertEqual(original.songs[0].tracks[0].clips[0].waveform, [0.25, 0.75])
    }
}
