import XCTest
@testable import JarasApplication
final class ProjectEncryptionTests: XCTestCase {
    func testCrossPlatformReleaseFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["CATLIVE_COMPATIBILITY_INPUT"],
              let output = environment["CATLIVE_COMPATIBILITY_OUTPUT"] else {
            throw XCTSkip("Cross-platform fixtures are supplied by the desktop release workflow.")
        }
        let inputDirectory = URL(fileURLWithPath: input, isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        func write(_ project: Project, folder: String) throws {
            let directory = outputDirectory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ProjectDocumentCodec.write(project, to: directory.appendingPathComponent("Show.jl"))
        }
        // Real BCrypt ciphertext from the Windows executable, read with CryptoKit.
        var windows = try ProjectDocumentCodec.decode(Data(contentsOf: inputDirectory.appendingPathComponent("fixture.jl")))
        let expected = try JSONDecoder().decode(Project.self, from: Data(contentsOf: inputDirectory.appendingPathComponent("fixture.json")))
        XCTAssertEqual(windows, expected)
        XCTAssertNotNil(windows.windowsLighting)
        windows.name = "Edited on Mac"
        try write(windows, folder: "WindowsReturn")
        try JSONEncoder().encode(windows).write(to: outputDirectory.appendingPathComponent("windows-returned.json"))
        // An independent, Mac-created document must open and save on Windows too.
        var mac = Project.empty(name: "Mac → Windows 🎹")
        var audioTrack = Track(id: UUID(), name: "Piano", role: .keys)
        audioTrack.volume = 0.73; audioTrack.pan = -0.2; audioTrack.heightScale = 1.25
        audioTrack.phaseInverted = true; audioTrack.outputs = [.master, OutputPatch(firstChannel: 3, channelCount: 2)]
        var audio = AudioClip(id: UUID(), name: "Café take", startTime: 10, duration: 8)
        audio.audioFile = AudioFile(path: "Stems/Café.wav")
        audio.sourceOffset = 1; audio.waveform = [0.1, 0.4, 0.2]
        audio.gain = 0.7; audio.fadeIn = 0.25; audio.fadeOut = 0.5
        audio.automation = TrackAutomation(); audioTrack.clips = [audio]
        var midiTrack = Track(id: UUID(), name: "MIDI", role: .keys)
        var midi = AudioClip(id: UUID(), name: "Notas", startTime: 10, duration: 4)
        midi.midi = MIDIItem(notes: [MIDINote(start: 0, length: 1, pitch: 60)])
        midiTrack.clips = [midi]
        let first = TimelineMarker(id: UUID(), name: "A", position: 12, color: 0xffdc52)
        let second = TimelineMarker(id: UUID(), name: "B", position: 16, color: 0xffdc52)
        var part = Part(id: UUID(), name: "Música", startTime: 10, endTime: 30)
        part.multiLoops = [MultiLoop(name: "Repetir", marker1: first.id, marker2: second.id)]
        mac.songs[0].tracks = [audioTrack, midiTrack]
        mac.songs[0].parts = [part]; mac.songs[0].markers = [first, second]
        mac.savedCursor = SavedProjectCursor(songID: mac.songs[0].id, position: 12.5)
        mac.masterOutputs = [OutputPatch(firstChannel: 3, channelCount: 2)]
        mac.resolume = ResolumeSettings()
        mac.resolume?.withMarkers = ["region:\(part.id.uuidString)": "0:0"]
        try write(mac, folder: "MacOrigin")
        try JSONEncoder().encode(mac).write(to: outputDirectory.appendingPathComponent("mac-origin.json"))
        // Also exercise the independent AES implementation used by the Windows tests.
        let independent = try ProjectDocumentCodec.decode(Data(contentsOf: inputDirectory.appendingPathComponent("external-crypto.jl")))
        XCTAssertEqual(independent, expected)
    }
    func testWindowsLightingSurvivesMacEditingAndEncryptedSave() async throws {
        // Model a Windows document, including reserved destinations and settings
        // introduced after this Mac version. Saving must not reset the MA map.
        let metadata = Data(#"""
        {"assignments":{"region:existing":0,"region:removed":7},
         "starts":{"existing":0,"later":123.125},"committed":true,
         "grandMA2":{"sequence":4,"page":2,"executor":7,"timecode":9,"slot":2},
         "future":{"label":"São João 🎵","values":[null,false,0,-1,1.25,9007199254740993]}}
        """#.utf8)
        let opaque = try JSONDecoder().decode(PortableProjectJSON.self, from: metadata)
        let project = Project.empty(name: "Windows project")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        root["windowsLighting"] = try JSONSerialization.jsonObject(with: metadata)
        var opened = try ProjectDocumentCodec.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(opened.windowsLighting, opaque)
        opened.name = "Edited on Mac"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Show.jl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProjectStore(url: url)
        try await store.save(opened)
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.windowsLighting, opaque)
        XCTAssertEqual(saved.name, "Edited on Mac")
        let encoded = try JSONEncoder().encode(saved)
        let encodedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let returnedMetadata = try JSONSerialization.data(withJSONObject: XCTUnwrap(encodedRoot["windowsLighting"]))
        XCTAssertEqual(try JSONDecoder().decode(PortableProjectJSON.self, from: returnedMetadata), opaque)
    }
    func testLegacyProjectsDoNotRequireWindowsSettings() throws {
        let original = Project.empty(name: "Existing Mac project")
        XCTAssertNil(original.windowsLighting)
        let decoded = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.windowsLighting)
    }
    func testEncryptedRoundTripAndUniqueCiphertext() throws {
        let project = Project.empty(name: "Private song name")
        let first = try ProjectDocumentCodec.encode(project)
        let second = try ProjectDocumentCodec.encode(project)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: Data(project.name.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: first))
        XCTAssertEqual(try ProjectDocumentCodec.decode(first), project)
        XCTAssertEqual(try ProjectDocumentCodec.decode(second), project)
    }
    func testCorruptionTruncationAndUnknownVersionsAreRejected() throws {
        let data = try ProjectDocumentCodec.encode(.empty(name: "Test"))
        var tampered = data; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(tampered))
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(data.prefix(20)))
        var future = data; future[8] = 2
        XCTAssertThrowsError(try ProjectDocumentCodec.decode(future))
    }
    func testExistingDocumentBecomesEncryptedWhenSaved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jl")
        defer { try? FileManager.default.removeItem(at: url) }
        let project = Project.empty(name: "Existing project")
        try JSONEncoder().encode(project).write(to: url)
        let store = ProjectStore(url: url)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, project)
        try await store.save(project)
        XCTAssertNotEqual(try Data(contentsOf: url).first, 123)
        let reopened = try await store.load()
        XCTAssertEqual(reopened, project)
    }
}
