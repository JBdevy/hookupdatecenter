import XCTest
@testable import JarasApplication

final class PartialProjectPackageTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-partial-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func project() -> Project {
        var value = Project.empty(name: "Partial fixture")
        value.songs[0].tracks = [Track(id: UUID(), name: "Piano", role: .other)]
        return value
    }
    private func snapshot(_ project: Project) -> PartialProjectPackage.Snapshot {
        .init(project: project, files: [], instruments: [:])
    }
    private func file(_ path: String, _ content: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url); return url
    }
    func testNewReverbPreservesIPadEQAndEveryExistingTrackSetting() throws {
        var base = project(), eq = NativeFXSettings()
        eq.inserted = ["EQ"]; eq.eqEnabled = true; eq.bands[0].gain = 6
        base.songs[0].tracks[0].fx = eq
        var desktop = base
        desktop.songs[0].tracks[0].fx!.inserted.append("Reverb")
        desktop.songs[0].tracks[0].fx!.reverbEnabled = true
        desktop.songs[0].tracks[0].fx!.reverbMix = 37
        desktop.songs[0].tracks[0].fx!.bands[0].gain = -9
        desktop.songs[0].tracks[0].volume = 0.9
        var ipad = base
        ipad.songs[0].tracks[0].name = "Piano iPad"
        ipad.songs[0].tracks[0].volume = 0.25; ipad.songs[0].tracks[0].mute = true
        ipad.songs[0].tracks[0].solo = true; ipad.songs[0].tracks[0].pan = 0.4
        ipad.songs[0].tracks[0].fx!.bands[0].gain = 11
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        let merged = try PartialProjectPackage.merge(delta, into: ipad)
        var expected = ipad.songs[0].tracks[0]
        expected.fx!.inserted.append("Reverb"); expected.fx!.reverbEnabled = true; expected.fx!.reverbMix = 37
        XCTAssertEqual(merged.songs[0].tracks[0], expected)
        XCTAssertEqual(merged.masterVolume, ipad.masterVolume)
    }
    func testExistingFXParametersAndOrderAreNeverUpdated() throws {
        var base = project(), fx = NativeFXSettings(); fx.inserted = ["EQ", "Reverb"]
        base.songs[0].tracks[0].fx = fx
        var desktop = base; desktop.songs[0].tracks[0].fx!.inserted.reverse()
        desktop.songs[0].tracks[0].fx!.reverbMix = 95
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        XCTAssertTrue(delta.project.songs.isEmpty)
        XCTAssertEqual(try PartialProjectPackage.merge(delta, into: base).songs, base.songs)
    }
    func testNewNativeInstanceIsAppendedWithoutChangingExistingInstance() throws {
        var base = project(), fx = NativeFXSettings()
        let old = fx.appendNative("EQ", asInstance: true)
        base.songs[0].tracks[0].fx = fx
        var desktop = base
        let new = desktop.songs[0].tracks[0].fx!.appendNative("EQ", asInstance: true)
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        let merged = try PartialProjectPackage.merge(delta, into: base)
        XCTAssertEqual(merged.songs[0].tracks[0].fx!.inserted, [old, new])
        XCTAssertEqual(merged.songs[0].tracks[0].fx!.settings(for: old), fx.settings(for: old))
    }
    func testReorderedLegacyStageDoesNotDuplicateButExtraCopyIsAdded() throws {
        var base = project(), fx = NativeFXSettings(); fx.inserted = ["EQ", "Reverb"]
        base.songs[0].tracks[0].fx = fx
        var desktop = base
        _ = desktop.songs[0].tracks[0].fx!.reorderClipEffect("Reverb", before: "EQ")
        let new = desktop.songs[0].tracks[0].fx!.appendNative("EQ", asInstance: true)
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        let merged = try PartialProjectPackage.merge(delta, into: base)
        XCTAssertEqual(merged.songs[0].tracks[0].fx!.inserted.count, 3)
        XCTAssertTrue(merged.songs[0].tracks[0].fx!.inserted.contains(new))
    }
    func testImportsFXIntoEmptyChainAndPreservesBypass() throws {
        let base = project(); var desktop = base, fx = NativeFXSettings()
        fx.inserted = ["Limiter"]; fx.limiterEnabled = false
        desktop.songs[0].tracks[0].fx = fx
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        let merged = try PartialProjectPackage.merge(delta, into: base)
        XCTAssertEqual(merged.songs[0].tracks[0].fx?.inserted, ["Limiter"])
        XCTAssertEqual(merged.songs[0].tracks[0].fx?.limiterEnabled, false)
    }
    func testNewChildGoesIntoExistingGroupAndRemovedDestinationIsRejected() throws {
        var base = project()
        base.songs[0].tracks.append(Track(id: UUID(), name: "Other", role: .other))
        var desktop = base, child = Track(id: UUID(), name: "Child", role: .other)
        child.parentTrackID = base.songs[0].tracks[0].id
        desktop.songs[0].tracks.insert(child, at: 1)
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        XCTAssertEqual(try PartialProjectPackage.merge(delta, into: base).songs[0].tracks.map(\.id), desktop.songs[0].tracks.map(\.id))
        var removed = base; removed.songs[0].tracks.removeFirst()
        XCTAssertThrowsError(try PartialProjectPackage.merge(delta, into: removed))
    }
    func testPackageReusesIdenticalMediaWithDifferentPathAndImportsOnlyNewBytes() throws {
        var base = project()
        _ = try file("Stems/iPad.wav", "existing audio")
        base.songs[0].tracks[0].clips = [AudioClip(id: UUID(), name: "Existing", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/iPad.wav"))]
        let baseline = directory.appendingPathComponent("Inventory.jlpartial")
        try PartialProjectPackage.exportSnapshot(project: base, directory: directory, instruments: [:], to: baseline)
        _ = try file("Stems/desktop.wav", "existing audio")
        _ = try file("Stems/new.wav", "new audio")
        var desktop = base
        desktop.songs[0].tracks[0].clips += [AudioClip(id: UUID(), name: "Reused", startTime: 2, duration: 1, audioFile: AudioFile(path: "Stems/desktop.wav")), AudioClip(id: UUID(), name: "New", startTime: 4, duration: 1, audioFile: AudioFile(path: "Stems/new.wav"))]
        let archive = directory.appendingPathComponent("Update.ziplivepartial")
        try PartialProjectPackage.export(project: desktop, directory: directory, baselineURL: baseline, instruments: [:], to: archive)
        let zip = try StoredProjectZIPReader(url: archive, limits: .init())
        XCTAssertEqual(zip.entries.count, 3, "Only the new media, delta and manifest are transferred")
        let prepared = try PartialProjectPackage.prepareImport(archive, project: base, directory: directory, instruments: [:])
        try prepared.install()
        let merged = prepared.project
        XCTAssertEqual(merged.songs[0].tracks[0].clips.count, 3)
        XCTAssertEqual(merged.songs[0].tracks[0].clips[1].audioFile?.path, "Stems/iPad.wav")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(merged.songs[0].tracks[0].clips[2].audioFile!.path)), "new audio")
        XCTAssertThrowsError(try PartialProjectPackage.prepareImport(archive, project: merged, directory: directory, instruments: [:]))
        prepared.rollback()
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Stems/iPad.wav")), "existing audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(merged.songs[0].tracks[0].clips[2].audioFile!.path).path))
    }
    func testDifferentProjectIsRejectedAndRepeatDoesNotResurrectDeletedAdditions() throws {
        let base = project(); var desktop = base
        desktop.songs[0].tracks.append(Track(id: UUID(), name: "New", role: .other))
        let delta = try PartialProjectPackage.additions(from: desktop, baseline: snapshot(base))
        XCTAssertThrowsError(try PartialProjectPackage.merge(delta, into: project()))
        var merged = try PartialProjectPackage.merge(delta, into: base)
        merged.songs[0].tracks.removeLast()
        XCTAssertEqual(try PartialProjectPackage.merge(delta, into: merged), merged)
    }
    func testActualWindowsPackageImportsWithNativeDecoder() throws {
        guard let input = ProcessInfo.processInfo.environment["CATLIVE_COMPATIBILITY_INPUT"] else {
            throw XCTSkip("Requires the Windows release self-test artifacts")
        }
        let fixture = URL(fileURLWithPath: input).appendingPathComponent("partial-package")
        let destination = directory.appendingPathComponent("iPad")
        try FileManager.default.copyItem(at: fixture, to: destination)
        let snapshot = try PartialProjectPackage.readSnapshot(destination.appendingPathComponent("Baseline.jlpartial"))
        var ipad = snapshot.project
        ipad.songs[0].tracks[0].volume = 0.17
        ipad.songs[0].tracks[0].mute = true
        ipad.songs[0].tracks[0].fx!.bands[0].gain = 9
        let prepared = try PartialProjectPackage.prepareImport(destination.appendingPathComponent("Windows.ziplivepartial"), project: ipad, directory: destination, instruments: [:])
        try prepared.install()
        let track = prepared.project.songs[0].tracks[0]
        XCTAssertEqual(track.volume, 0.17)
        XCTAssertTrue(track.mute)
        XCTAssertEqual(track.fx?.bands[0].gain, 9)
        XCTAssertEqual(track.fx?.inserted, ["EQ", "Reverb"])
        XCTAssertEqual(track.fx?.reverbMix, 37)
        XCTAssertEqual(track.clips.count, 3)
        XCTAssertEqual(track.clips[1].audioFile?.path, "Stems/Piano.wav")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(track.clips[2].audioFile!.path)), "new audio")
        XCTAssertEqual(prepared.project.partialImportIDs?.count, 2)
    }
}
