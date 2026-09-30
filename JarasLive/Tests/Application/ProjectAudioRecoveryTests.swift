import XCTest
@testable import JarasApplication

final class ProjectAudioRecoveryTests: XCTestCase {
    func testPartialRecoveryKeepsUnresolvedItemsReferencedForNextOpening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("project")
        let search = root.appendingPathComponent("search")
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: search.appendingPathComponent("Click.wav"))

        var project = Project.empty(name: "Test")
        var track = Track(id: UUID(), name: "Click", role: .click)
        track.clips = [
            AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 5,
                      audioFile: AudioFile(path: "Stems/A/Click.wav")),
            AudioClip(id: UUID(), name: "Guide", startTime: 5, duration: 5,
                      audioFile: AudioFile(path: "Stems/A/Guide.wav"))
        ]
        track.volume = 0.6
        track.pan = -0.25
        track.mute = true
        track.clips[0].gain = 0.5
        track.clips[0].muted = true
        var fx = NativeFXSettings(); fx.inserted = ["EQ"]; fx.eqEnabled = true
        track.clips[0].fx = fx
        project.songs[0].tracks = [track]
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: project, directory: document).count, 2)

        let result = try ProjectAudioRecovery.restore(project, directory: document, searching: search)
        XCTAssertEqual(result.recovered, ["Stems/A/Click.wav"])
        XCTAssertEqual(result.remaining, ["Stems/A/Guide.wav"])
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: document.appendingPathComponent("Stems/A/Click.wav")), Data([1, 2, 3]))
        let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertEqual(ProjectAudioRecovery.missingPaths(in: reopened, directory: document), result.remaining)
        XCTAssertEqual(reopened.songs[0].tracks[0], track)

        project.songs[0].tracks[0].clips.removeLast()
        XCTAssertTrue(ProjectAudioRecovery.missingPaths(in: project, directory: document).isEmpty)
    }

    func testAmbiguousSameNameDoesNotRestoreWrongAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("project")
        let search = root.appendingPathComponent("search")
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(at: search.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: search.appendingPathComponent(name + "/Click.wav"))
        }
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var project = Project.empty(name: "Test")
        var track = Track(id: UUID(), name: "Click", role: .click)
        track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 5,
                                 audioFile: AudioFile(path: "Stems/Unknown/Click.wav"))]
        project.songs[0].tracks = [track]
        let result = try ProjectAudioRecovery.restore(project, directory: document, searching: search)
        XCTAssertTrue(result.recovered.isEmpty)
        XCTAssertEqual(result.remaining, ["Stems/Unknown/Click.wav"])
    }
}
