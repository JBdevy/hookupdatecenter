import XCTest
import AVFoundation
@testable import JarasApplication

final class StemImportTests: XCTestCase {
    func fixture(_ root: URL, folder: String, file: String, seconds: Double = 0.1) throws -> URL {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1)) * 0.3 }
        try output.write(from: buffer)
        return directory
    }
    func testCleanupSuggestionsProtectHookCenterInstrumentVocabularyAndGroups() throws {
        let js = try StemProjectImporter.context()
        let names = js.evaluateScript("CREATE_PROJECT_TRACK_RULES.map(rule => rule.name).concat(CREATE_PROJECT_TRACK_GROUPS.map(group => group.name))")!.toArray() as! [String]
        for name in names + ["GTR", "Pno", "Metronome", "Accordion", "Drums", "Electric Piano", "Hi-Hat"] {
            let suggestions = try StemProjectImporter.call("suggestImportRemovals", args: [[name, name], ["limit": 12]], context: js, as: [ImportSuggestion].self)
            XCTAssertTrue(suggestions.isEmpty, "Instrument or group name must not be proposed for removal: \(name)")
        }
        let sourceNames = ["Fornecedor - Click", "Fornecedor - Sanfona", "Fornecedor - Bateria", "Fornecedor - Piano", "Clube do VS - Click", "Clube do VS - Piano"]
        let suggestions = try StemProjectImporter.call("suggestImportRemovals", args: [sourceNames, ["limit": 12]], context: js, as: [ImportSuggestion].self)
        XCTAssertTrue(suggestions.contains { $0.text == "Fornecedor" })
        XCTAssertTrue(suggestions.contains { $0.text == "Clube do VS" })
        XCTAssertFalse(suggestions.contains { $0.text.contains("Click") || $0.text.contains("Sanfona") })
    }
    func testFolderReviewRetainsSelectionOrderAcrossSearchAndSelectAll() {
        let urls = ["Zulu", "Alpha", "Middle"].map { URL(fileURLWithPath: "/songs/" + $0) }
        var selection = FolderImportSelection(urls + [urls[0]])
        XCTAssertEqual(selection.folders, urls)
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggle(urls[2]); selection.toggle(urls[0])
        XCTAssertEqual(selection.matching("ALP"), [urls[1]])
        XCTAssertEqual(selection.selected, [urls[2], urls[0]])
        selection.toggleAll()
        XCTAssertTrue(selection.allSelected)
        XCTAssertEqual(selection.selected, [urls[2], urls[0], urls[1]])
        selection.toggle(urls[0]); selection.toggle(urls[0])
        XCTAssertEqual(selection.position(of: urls[0]), 3)
        selection.toggleAll()
        XCTAssertTrue(selection.selected.isEmpty)
        selection.toggleAll()
        XCTAssertEqual(selection.selected, urls)
        selection.toggle(URL(fileURLWithPath: "/not-in-selection"))
        XCTAssertEqual(selection.selected, urls)
    }
    func testCreateAndAppendFollowCheckedFolderOrderBeyondTenFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Zulu", "Alpha", "Quebec", "Bravo", "Yankee", "Charlie", "Xray", "Delta", "Whiskey", "Echo", "Victor", "Foxtrot"]
        let folders = try names.map { try fixture(root, folder: $0, file: "Click.wav") }
        var selection = FolderImportSelection(folders)
        for folder in folders.reversed() { selection.toggle(folder) }
        let scan = try StemProjectImporter.scan(selection.selected)
        XCTAssertEqual(scan.folders.map(\.url), selection.selected)
        let destination = root.appendingPathComponent("Project/Show.jl")
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Order"), destination: destination)
        XCTAssertEqual(first.songs[0].parts.map(\.name), Array(names.reversed()))
        let click = try XCTUnwrap(first.songs[0].tracks.first { $0.name == "Click" })
        let clickGroup = try XCTUnwrap(first.songs[0].tracks.first { $0.id == click.parentTrackID })
        XCTAssertNotEqual(click.color, clickGroup.color, "Folder colors remain stronger than their children")
        for pair in zip(first.songs[0].parts, first.songs[0].parts.dropFirst()) {
            XCTAssertEqual(pair.1.startTime - pair.0.endTime, 30, accuracy: 0.00001)
        }
        let nextScan = try StemProjectImporter.scan([folders[3], folders[0]])
        let appended = try StemProjectImporter.build(scan: nextScan, remove: "", base: first, destination: destination)
        XCTAssertEqual(Array(appended.songs[0].parts.suffix(2)).map(\.name), [names[3], names[0]])
        XCTAssertEqual(appended.songs[0].parts[12].startTime - first.songs[0].parts.last!.endTime, 30, accuracy: 0.00001)
    }
    func testDroppedAudioCopiesMediaAndKeepsPlacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "Source", file: "One.wav", seconds: 0.2).appendingPathComponent("One.wav")
        let two = try fixture(root, folder: "Source", file: "Two.wav", seconds: 0.3).appendingPathComponent("Two.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let track = UUID()
        let imported = try StemProjectImporter.prepareDroppedAudio([one, two, one], start: 12.5, destinationTracks: [track], destination: destination)
        XCTAssertEqual(imported.tracks.count, 2)
        XCTAssertEqual(imported.tracks[0].id, track)
        XCTAssertNotEqual(imported.tracks[1].id, track)
        XCTAssertTrue(imported.tracks.allSatisfy { $0.color == Track.defaultStandardColor })
        for (index, source) in [one, two].enumerated() {
            let clip = imported.tracks[index].clips[0]
            XCTAssertEqual(clip.startTime, 12.5)
            XCTAssertEqual(clip.duration, index == 0 ? 0.2 : 0.3, accuracy: 0.00001)
            let copy = destination.deletingLastPathComponent().appendingPathComponent(clip.audioFile!.path)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
            XCTAssertFalse(clip.waveform.isEmpty)
        }
        let bad = root.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: bad)
        let existing = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Project/Steams").path)
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([one, bad], start: 0, destinationTracks: [], destination: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Project/Steams").path), existing)
    }
    func testSameTrackDropUsesGapAndExtensionFreeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "Source", file: "Song.One.WAV", seconds: 0.2).appendingPathComponent("Song.One.WAV")
        let two = try fixture(root, folder: "Source", file: "Second.wav", seconds: 0.3).appendingPathComponent("Second.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let target = UUID()
        for gap in [0.0, 12.0, 60.0] {
            let result = try StemProjectImporter.prepareDroppedAudio([one,two], start: 30, destinationTracks: [target], destination: destination, layout: .sameTrack, gap: gap)
            XCTAssertEqual(result.tracks.count, 1)
            XCTAssertEqual(result.tracks[0].id, target)
            XCTAssertEqual(result.tracks[0].name, "Song.One")
            XCTAssertEqual(result.tracks[0].clips.map(\.name), ["Song.One", "Second"])
            XCTAssertEqual(result.tracks[0].clips[1].startTime, 30.2 + gap, accuracy: 0.000001)
        }
        let emptyArea = try StemProjectImporter.prepareDroppedAudio([one], start: 10, destinationTracks: [], destination: destination)
        XCTAssertEqual(emptyArea.tracks[0].name, "Song.One")
        XCTAssertNotEqual(emptyArea.tracks[0].id, target)
        XCTAssertThrowsError(try StemProjectImporter.prepareDroppedAudio([one,two], start: 0, destinationTracks: [], destination: destination, layout: .sameTrack, gap: 61))
    }

    func testVectorOverviewMatchesSamplePeaks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav", seconds: 0.2)
        let url = folder.appendingPathComponent("Click.wav")
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let result = try StemProjectImporter.audioOverview(url, duration: duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var expected = Array(repeating: 0.0, count: result.waveform.count)
        var peak = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let value = abs(Double(buffer.floatChannelData![0][frame]))
            let index = frame * expected.count / Int(file.length)
            expected[index] = max(expected[index], min(1, value)); peak = max(peak, value)
        }
        XCTAssertEqual(result.channels, [expected])
        XCTAssertEqual(result.waveform, expected)
        XCTAssertEqual(result.peak, peak, accuracy: 0.0000001)
    }
    func testStereoOverviewKeepsIndependentChannels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
            buffer.frameLength = 4410
            for i in 0..<4410 { buffer.floatChannelData![0][i] = 0.2; buffer.floatChannelData![1][i] = 0.7 }
            try output.write(from: buffer)
        }
        let result = try StemProjectImporter.audioOverview(url, duration: 0.1)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.channels[0].max()!, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result.channels[1].max()!, 0.7, accuracy: 0.00001)
    }
    func testImportGroupingMediaNamesAndThirtySecondGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try fixture(root, folder: "01 - Song One - MultiTracks", file: "Click.wav")
        _ = try fixture(root, folder: one.lastPathComponent, file: "Sanfona.wav", seconds: 0.2)
        let two = try fixture(root, folder: "02 - Song Two - MultiTracks", file: "Click.wav")
        _ = try fixture(root, folder: two.lastPathComponent, file: "Accordion.wav")
        let scan = try StemProjectImporter.scan([one, two])
        XCTAssertTrue(scan.suggestions.contains { $0.text == "MultiTracks" })
        let destination = root.appendingPathComponent("Show.jl")
        let project = try StemProjectImporter.build(scan: scan, remove: "MultiTracks", base: .empty(name: "Show"), destination: destination)
        let song = project.songs[0]
        XCTAssertEqual(song.parts.map(\.name), ["Song One", "Song Two"])
        XCTAssertEqual(song.parts[0].startTime, 30)
        XCTAssertEqual(song.parts[1].startTime - song.parts[0].endTime, 30, accuracy: 0.000001)
        XCTAssertEqual(Set(song.tracks.map(\.name)), ["Interno", "Click", "Sanfonas", "Sanfona"])
        XCTAssertEqual(song.tracks.filter { !$0.clips.isEmpty }.map { $0.clips.count }, [2, 2])
        for clip in song.tracks.flatMap(\.clips) {
            XCTAssertNotNil(clip.audioFile)
            XCTAssertTrue(clip.audioFile!.path.hasPrefix("Steams/"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.audioFile!.path).path))
            XCTAssertGreaterThan(clip.waveform.max()!, 0)
        }
        let next = try StemProjectImporter.build(scan: scan, remove: "MultiTracks", base: project, destination: destination)
        XCTAssertEqual(next.songs[0].tracks.count, 4)
        XCTAssertEqual(next.songs[0].parts[2].startTime - song.parts[1].endTime, 30, accuracy: 0.000001)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(next)), next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.appendingPathComponent("Click.wav").path))
    }
    func testSameSongDuplicateTracksAndUnsafeClipPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Metronome.wav")
        let scan = try StemProjectImporter.scan([folder])
        var project = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Show"), destination: root.appendingPathComponent("Show.jl"))
        XCTAssertEqual(Set(project.songs[0].tracks.map(\.name)), ["Interno", "Click", "Click 2"])
        let child = try XCTUnwrap(project.songs[0].tracks.firstIndex { !$0.clips.isEmpty })
        project.songs[0].tracks[child].clips[0].audioFile = AudioFile(path: "../outside.wav")
        XCTAssertThrowsError(try project.validate())
    }
    func testImportedFamiliesBecomeFoldersAndAppendKeepsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "One", file: "Piano.wav")
        _ = try fixture(root, folder: "One", file: "Pad.wav")
        _ = try fixture(root, folder: "One", file: "Guitarra 1.wav")
        _ = try fixture(root, folder: "One", file: "Guitarra 2.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let scan = try StemProjectImporter.scan([folder])
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Groups"), destination: destination)
        let tracks = first.songs[0].tracks
        XCTAssertEqual(tracks.filter { $0.parentTrackID != nil }.count, 4)
        XCTAssertEqual(Set(tracks.filter { $0.parentTrackID == nil }.map(\.name)), ["Guitarras", "Teclados"])
        for child in tracks where child.parentTrackID != nil {
            let parent = try XCTUnwrap(tracks.first { $0.id == child.parentTrackID })
            XCTAssertEqual(parent.name, child.name.hasPrefix("Guitarra") ? "Guitarras" : "Teclados")
            XCTAssertTrue(parent.clips.isEmpty)
            XCTAssertEqual(child.primaryOutput, .masterGroup)
        }
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.map(\.parentTrackID), tracks.map(\.parentTrackID))
        XCTAssertEqual(second.songs[0].tracks.count, tracks.count)
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(second))
        XCTAssertEqual(reopened, second)
        try reopened.validate()
    }
    func testPercussiveFolderContainsDrumsAndCongaAndIsReusedOnAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "One", file: "Conga.wav")
        _ = try fixture(root, folder: "One", file: "Bateria.wav")
        let destination = root.appendingPathComponent("Project/Show.jl")
        let scan = try StemProjectImporter.scan([folder])
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Groups"), destination: destination)
        let tracks = first.songs[0].tracks
        let group = try XCTUnwrap(tracks.first { $0.name == "Percussivo" })
        XCTAssertNil(group.parentTrackID)
        XCTAssertTrue(group.clips.isEmpty)
        XCTAssertEqual(Set(tracks.filter { $0.parentTrackID == group.id }.map(\.name)), ["Conga", "Bateria"])
        XCTAssertTrue(tracks.filter { $0.parentTrackID == group.id }.allSatisfy { $0.primaryOutput == .masterGroup })
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.count, tracks.count)
        XCTAssertEqual(second.songs[0].tracks.first { $0.name == "Percussivo" }?.id, group.id)
        XCTAssertEqual(second.songs[0].tracks.first { $0.name == "Bateria" }?.clips.count, 2)
    }
    func testEveryHookCenterAuditGroupIncludingOthersIsCreatedAndReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Click", "Guitarra", "Violão", "Sanfona", "Piano", "Pad", "Metais", "Bateria", "Conga", "Backing Vocal", "Baixo", "Mystery Sound"]
        let folder = try fixture(root, folder: "One", file: names[0] + ".wav")
        for name in names.dropFirst() { _ = try fixture(root, folder: "One", file: name + ".wav") }
        let scan = try StemProjectImporter.scan([folder]), destination = root.appendingPathComponent("Project/Show.jl")
        let js = try StemProjectImporter.context()
        let virtual: [[String: Any]] = [["path": "/0/One", "files": scan.folders[0].files.map { ["name": $0.name, "duration": $0.duration, "peakDb": NSNull()] as [String: Any] }]]
        let reference = try StemProjectImporter.call("analyzeImport", args: [virtual], context: js, as: ImportAudit.self)
        let first = try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Audit"), destination: destination)
        let tracks = first.songs[0].tracks
        XCTAssertEqual(tracks.filter { $0.parentTrackID == nil }.map(\.name), (reference.groups.filter { $0.key != "percussivo" } + reference.groups.filter { $0.key == "percussivo" }).map(\.name))
        XCTAssertEqual(tracks.filter { $0.parentTrackID == nil }.count, 9)
        for group in reference.groups {
            let folder = try XCTUnwrap(tracks.first { $0.name == group.name && $0.parentTrackID == nil })
            let members = tracks.filter { $0.parentTrackID == folder.id }
            XCTAssertEqual(members.map(\.name), group.tracks.map(\.name))
            XCTAssertTrue(members.allSatisfy { $0.color != folder.color && $0.primaryOutput == .masterGroup })
        }
        let second = try StemProjectImporter.build(scan: scan, remove: "", base: first, destination: destination)
        XCTAssertEqual(second.songs[0].tracks.map(\.id), tracks.map(\.id))
        XCTAssertTrue(second.songs[0].tracks.filter { !$0.clips.isEmpty }.allSatisfy { $0.clips.count == 2 })
    }
    func testAppendUsesHookCenterCanonicalAliasesAndCreatesMissingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Guitarra.wav")
        var base = Project.empty(name: "Existing")
        var existing = Track(id: UUID(), name: "GTR", role: .guitar)
        existing.clips = [AudioClip(id: UUID(), name: "Old", startTime: 0, duration: 0.1)]
        base.songs[0].tracks = [existing]
        let appended = try StemProjectImporter.build(scan: StemProjectImporter.scan([folder]), remove: "", base: base, destination: root.appendingPathComponent("Show.jl"))
        let group = try XCTUnwrap(appended.songs[0].tracks.first { $0.name == "Guitarras" })
        XCTAssertEqual(appended.songs[0].tracks.count, 2)
        XCTAssertEqual(appended.songs[0].tracks.first { $0.id == existing.id }?.parentTrackID, group.id)
        XCTAssertEqual(appended.songs[0].tracks.first { $0.id == existing.id }?.clips.count, 2)
    }
    func testParallelImportFailureRollsBackOnlyItsOwnMediaDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Piano.wav")
        let scan = try StemProjectImporter.scan([folder])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Piano.wav"))
        let existing = root.appendingPathComponent("Steams/old.wav")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: existing)
        XCTAssertThrowsError(try StemProjectImporter.build(scan: scan, remove: "", base: .empty(name: "Rollback"), destination: root.appendingPathComponent("Show.jl")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path), ["old.wav"])
    }
    func testCleaningCollisionDoesNotCreateMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, folder: "Song", file: "Click.wav")
        _ = try fixture(root, folder: "Song", file: "Provider Click.wav")
        let scan = try StemProjectImporter.scan([folder])
        XCTAssertThrowsError(try StemProjectImporter.build(scan: scan, remove: "Provider", base: .empty(name: "Show"), destination: root.appendingPathComponent("Show.jl")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Steams").path))
    }
}
