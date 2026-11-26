import XCTest
@testable import JarasApplication
final class ProjectReductionTests: XCTestCase {
    func testUnfinishedDraftSurvivesProjectSaveAndReorder() throws {
        var project = Project.empty(name: "Draft")
        let a = Track(id: UUID(), name: "Voz", role: .other)
        let b = Track(id: UUID(), name: "Base", role: .other)
        let c = Track(id: UUID(), name: "Click", role: .other)
        project.songs[0].tracks = [a,b,c]
        var groups = [ProjectReductionTrack(name: "Voz", sources: [a.id]), ProjectReductionTrack(name: "Base", sources: [b.id])]
        let first = groups[0].id
        ProjectReduction.move(first, to: 2, in: &groups)
        XCTAssertEqual(groups.map(\.name), ["Base", "Voz"])
        groups[1].name = "Voz principal"
        let draft = ProjectReduction.Draft(groups: groups, checked: [c.id])
        project.reductionDraft = try draft.encoded()
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(ProjectReduction.Draft.read(from: restored), draft)
        XCTAssertEqual(ProjectReduction.Draft.read(from: restored)?.cleaned(for: restored), draft)
        let selected = ProjectReduction.Draft(groups: groups, checked: [c.id], selected: first).cleaned(for: project)
        XCTAssertEqual(selected.checked, [a.id])
        project.songs[0].tracks.removeAll { $0.id == a.id }
        XCTAssertTrue(selected.cleaned(for: project).checked.isEmpty)
    }
    func testVerticalOverlapKeepsTouchingItemsAndGapsSeparate() {
        var a = Track(id: UUID(), name: "A", role: .other)
        var b = Track(id: UUID(), name: "B", role: .other)
        a.clips = [AudioClip(id: UUID(), name: "a", startTime: 0, duration: 5, audioFile: AudioFile(path: "a.wav")), AudioClip(id: UUID(), name: "b", startTime: 5, duration: 5, audioFile: AudioFile(path: "b.wav"))]
        b.clips = [AudioClip(id: UUID(), name: "c", startTime: 1, duration: 3, audioFile: AudioFile(path: "c.wav")), AudioClip(id: UUID(), name: "d", startTime: 20, duration: 2, audioFile: AudioFile(path: "d.wav"))]
        XCTAssertEqual(ProjectReduction.spans([a,b]).map(\.start), [0,5,20])
        XCTAssertEqual(ProjectReduction.spans([a,b]).map(\.end), [5,10,22])
    }
    func testRegionsPartitionCrossingAudioWithoutDuplicatingIt() {
        var project = Project.empty(name: "Regions")
        var a = Track(id: UUID(), name: "A", role: .other)
        a.clips = [AudioClip(id: UUID(), name: "long", startTime: 0, duration: 20, audioFile: AudioFile(path: "a.wav"))]
        let parent = UUID()
        project.songs[0].parts = [Part(id: parent, name: "Unified", startTime: 0, endTime: 20),
            Part(id: UUID(), name: "One", startTime: 0, endTime: 10, parentRegionID: parent),
            Part(id: UUID(), name: "Two", startTime: 10, endTime: 20, parentRegionID: parent)]
        let spans = ProjectReduction.spans([a], in: project.songs[0])
        XCTAssertEqual(spans.map(\.start), [0,10]); XCTAssertEqual(spans.map(\.end), [10,20])
        XCTAssertEqual(spans.reduce(0) { $0 + $1.end - $1.start }, 20)
    }
    func testOnlyDestinationTracksSurviveWithoutFolders() {
        var project = Project.empty(name: "Selection")
        var folder = Track(id: UUID(), name: "Group", role: .other); folder.volume = 0.5
        folder.clips = [AudioClip(id: UUID(), name: "unselected", startTime: 0, duration: 2, audioFile: AudioFile(path: "unused.wav"))]
        var chosen = Track(id: UUID(), name: "Chosen", role: .other); chosen.parentTrackID = folder.id; chosen.outputs = [.masterGroup]
        let other = Track(id: UUID(), name: "Other", role: .other)
        project.songs[0].tracks = [folder, chosen, other]
        ProjectReduction.retain([chosen.id], in: &project)
        XCTAssertEqual(project.songs[0].tracks.map(\.id), [chosen.id])
        XCTAssertNil(project.songs[0].tracks[0].parentTrackID)
        XCTAssertEqual(project.songs[0].tracks[0].outputs, [.master])
        XCTAssertTrue(project.songs[0].tracks[0].clips.isEmpty)
    }
    func testSampleAlignmentRemovesFloatingPointFragmentsAtRegionEdges() {
        var project = Project.empty(name: "Sample edges")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 4.000000000002, audioFile: AudioFile(path: "audio.wav"))]
        project.songs[0].parts = [Part(id: UUID(), name: "One", startTime: 0, endTime: 2), Part(id: UUID(), name: "Two", startTime: 2, endTime: 4)]
        let raw = ProjectReduction.spans([track], in: project.songs[0])
        XCTAssertEqual(raw.count, 3, "Fixture must reproduce the sub-sample residue")
        let aligned = ProjectReduction.sampleAligned(raw)
        XCTAssertEqual(aligned.map(\.start), [0,2]); XCTAssertEqual(aligned.map(\.end), [2,4])
        XCTAssertTrue(aligned.allSatisfy { (($0.end - $0.start) * 48000).rounded() > 0 })
    }
    func testEstimateUsesRegionDurationsAndCountsCopiedFilesOnce() {
        var project = Project.empty(name: "Estimate")
        var a = Track(id: UUID(), name: "A", role: .other)
        var b = Track(id: UUID(), name: "B", role: .other)
        a.clips = [AudioClip(id: UUID(), name: "a", startTime: 0, duration: 2, audioFile: AudioFile(path: "input.wav"))]
        b.clips = a.clips
        project.songs[0].tracks = [a,b]
        project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 10)]
        let mixed = [ProjectReductionTrack(name: "Mix", sources: [a.id,b.id])]
        let estimate = ProjectReduction.estimate(mixed, project: project) { _ in XCTFail("Rendered originals should not be copied"); return 999 }
        XCTAssertEqual(estimate.frames, 96000)
        XCTAssertEqual(estimate.files, 1)
        XCTAssertEqual(estimate.bytes(for: .wav), estimate.bytes(for: .aiff))
        XCTAssertEqual(estimate.bytes(for: .wav) - estimate.bytes(for: .mp3), 688000)
        var reads = 0
        let copies = ProjectReduction.estimate([ProjectReductionTrack(name: "One", sources: [a.id]), ProjectReductionTrack(name: "Two", sources: [b.id])], project: project) { path in
            XCTAssertEqual(path, "input.wav"); reads += 1; return 123456
        }
        XCTAssertEqual(reads, 1); XCTAssertEqual(copies.copiedBytes, 123456); XCTAssertEqual(copies.frames, 0)
        XCTAssertEqual(copies.bytes(for: .wav), copies.bytes(for: .mp3))
    }
    func testIPadFiltersItemsWithoutRemovingMixedTrack() {
        var project = Project.empty(name: "Mixed")
        var track = Track(id: UUID(), name: "Mixed", role: .other)
        let audio = AudioClip(id: UUID(), name: "audio", startTime: 0, duration: 2, audioFile: AudioFile(path: "Stems/audio.wav"))
        track.clips = [audio, AudioClip(id: UUID(), name: "video", startTime: 5, duration: 2, audioFile: AudioFile(path: "Videos/video.mp4"))]
        project.songs[0].tracks = [track]
        let copy = PortableProjectPackage.iPadCopy(project)
        XCTAssertEqual(copy.songs[0].tracks.count, 1)
        XCTAssertEqual(copy.songs[0].tracks[0].clips, [audio])
        XCTAssertEqual(copy.mediaPaths, ["Stems/audio.wav"])
        XCTAssertEqual(project.songs[0].tracks[0].clips.count, 2)
    }
}
