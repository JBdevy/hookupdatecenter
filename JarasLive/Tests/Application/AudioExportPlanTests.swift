import XCTest
@testable import JarasApplication
final class AudioExportPlanTests: XCTestCase {
    func testContextExportPreservesExplicitParentAndChildrenAndIgnoresBlocks() {
        var project = Project.empty(name: "Live")
        let parent = Part(id: UUID(), name: "Whole", startTime: 0, endTime: 20)
        let first = Part(id: UUID(), name: "Song", startTime: 0, endTime: 8, parentRegionID: parent.id)
        let second = Part(id: UUID(), name: "Song", startTime: 8, endTime: 20, parentRegionID: parent.id)
        project.songs[0].parts = [parent, first, second]
        let song = project.songs[0], block = UUID()
        let selected: Set<UUID> = [parent.id, first.id, second.id, block]
        let regions = AudioExportPlan.contextRegions(clicked: first.id, selected: selected, in: song)
        XCTAssertEqual(regions, [parent.id, first.id, second.id])
        let plan = AudioExportPlan(project: project, song: song, source: .master, bounds: .regions,
            template: "%region", tracks: [], clips: [], regions: regions)
        XCTAssertEqual(plan.jobs.count, 3)
        XCTAssertEqual(plan.jobs.map(\.duration), [20, 8, 12])
        XCTAssertEqual(Set(plan.jobs.map(\.fileName)).count, 3)
        XCTAssertEqual(AudioExportPlan.contextRegions(clicked: second.id, selected: [parent.id, first.id], in: song), [second.id])
        XCTAssertEqual(AudioExportPlan.contextRegions(clicked: parent.id, selected: [], in: song), [parent.id])
        XCTAssertTrue(AudioExportPlan.contextRegions(clicked: block, selected: [block], in: song).isEmpty)
    }
    func testDrawerSongExportsExcludePreviousItemsOnlyForThatSong() {
        var project = Project.empty(name: "Drawer")
        var track = Track(id: UUID(), name: "Track", role: .other)
        let previous = AudioClip(id: UUID(), name: "Previous", startTime: 0, duration: 20, audioFile: AudioFile(path: "previous.wav"))
        let current = AudioClip(id: UUID(), name: "Current", startTime: 5, duration: 10, audioFile: AudioFile(path: "current.wav"))
        let later = AudioClip(id: UUID(), name: "Later", startTime: 8, duration: 2, audioFile: AudioFile(path: "later.wav"))
        track.clips = [previous, current, later]
        let parent = Part(id: UUID(), name: "Unified", startTime: 0, endTime: 20)
        let child = Part(id: UUID(), name: "Song two", startTime: 5, endTime: 15, parentRegionID: parent.id)
        project.songs[0].tracks = [track]; project.songs[0].parts = [parent, child]
        for source in [AudioExportSource.master, .tracks, .masterAndTracks] {
            let plan = AudioExportPlan(project: project, song: project.songs[0], source: source, bounds: .regions, template: "%region %track", tracks: [track.id], clips: [], regions: [child.id])
            XCTAssertEqual(plan.jobs.count, source == .masterAndTracks ? 2 : 1)
            for job in plan.jobs {
                XCTAssertEqual(job.start, 5); XCTAssertEqual(job.end, 15)
                XCTAssertFalse(job.includes(previous)); XCTAssertTrue(job.includes(current)); XCTAssertTrue(job.includes(later))
                XCTAssertTrue(job.fileName.contains("SONG TWO"))
            }
            let whole = AudioExportPlan(project: project, song: project.songs[0], source: source, bounds: .regions, template: "%region", tracks: [track.id], clips: [], regions: [parent.id])
            XCTAssertTrue(whole.jobs.allSatisfy { $0.minimumClipStart == nil && $0.includes(previous) })
            let secondary = AudioExportPlan.combining(primary: plan, secondary: plan)
            XCTAssertTrue(secondary.jobs.allSatisfy { !$0.includes(previous) && $0.includes(current) })
        }
    }
    func testSelectedRegionsWithNoSelectionProduceNoPreviewOrRenderJobs() {
        var project = Project.empty(name: "Selection")
        var track = Track(id: UUID(), name: "Track", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 10, audioFile: AudioFile(path: "Stems/audio.wav"))]
        project.songs[0].tracks = [track]
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 10)
        project.songs[0].parts = [region]
        for source in [AudioExportSource.master, .tracks, .masterAndTracks] {
            let primary = AudioExportPlan(project: project, song: project.songs[0], source: source, bounds: .regions, template: "%track", tracks: [track.id], clips: [], regions: [])
            let secondary = AudioExportPlan(project: project, song: project.songs[0], source: source, bounds: .regions, template: "%track", tracks: [track.id], clips: [], regions: [], format: .mp3)
            XCTAssertTrue(AudioExportPlan.combining(primary: primary, secondary: secondary).jobs.isEmpty)
            let selected = AudioExportPlan(project: project, song: project.songs[0], source: source, bounds: .regions, template: "%track", tracks: [track.id], clips: [], regions: [region.id])
            XCTAssertEqual(selected.jobs.count, source == .masterAndTracks ? 2 : 1)
        }
    }
    func testItemExportFiltersSpecialTracksAndUsesEachAudioItemsBounds() {
        var project = Project.empty(name: "Mixed selection")
        var tracks: [Track] = []
        for kind in TrackKind.allCases {
            var track = Track(id: UUID(), name: kind.rawValue, role: TrackRole(rawValue: kind.rawValue))
            track.clips = [AudioClip(id: UUID(), name: "Same.wav", startTime: 10, duration: 2, sourceOffset: 3, audioFile: AudioFile(path: "source.wav"))]
            tracks.append(track)
        }
        var inherited = Track(id: UUID(), name: "Inherited", role: .other)
        inherited.audioFile = AudioFile(path: "track.wav")
        inherited.clips = [AudioClip(id: UUID(), name: "Same.wav", startTime: 35, duration: 4)]
        tracks.append(inherited)
        project.songs[0].tracks = tracks
        let original = project
        let selection = Set(tracks.flatMap(\.clips).map(\.id))
        for format in AudioExportFormat.allCases {
            let plan = AudioExportPlan(project: project, song: project.songs[0], source: .stems, bounds: .project, template: "%stem", tracks: [], clips: selection, regions: [], format: format)
            XCTAssertEqual(plan.jobs.count, 2)
            XCTAssertEqual(plan.jobs.map(\.fileName), ["Same." + format.fileExtension, "Same (2)." + format.fileExtension])
            XCTAssertEqual(plan.jobs.map(\.start), [10, 35])
            XCTAssertEqual(plan.jobs.map(\.duration), [2, 4])
            XCTAssertTrue(plan.jobs.allSatisfy { job in tracks.first { $0.id == job.track }?.kind == .standard })
        }
        XCTAssertEqual(project, original)
    }

    func testTokensLiteralSuffixSelectionAndUniqueNames() {
        var project = Project.empty(name: "Sunday")
        var track = Track(id: UUID(),name: "Click",role: .click)
        let one = AudioClip(id:UUID(),name:"Count.wav",startTime:30,duration:5,audioFile:AudioFile(path:"count.wav"))
        let two = AudioClip(id:UUID(),name:"Count.wav",startTime:60,duration:5,audioFile:AudioFile(path:"count.wav"))
        track.clips = [one,two]; project.songs[0].tracks = [track]
        let region = Part(id:UUID(),name:"Song (original)",startTime:30,endTime:35)
        project.songs[0].parts = [region]
        let plan = AudioExportPlan(project:project,song:project.songs[0],source:.tracks,bounds:.regions,template:"%track for today — %region — %project",tracks:[track.id],clips:[],regions:[region.id])
        XCTAssertEqual(plan.jobs.map(\.fileName),["Click for today — SONG (original) — Sunday.wav"])
        XCTAssertEqual(plan.jobs.first?.start,30)
        XCTAssertTrue(AudioExportPlan(project:project,song:project.songs[0],source:.tracks,bounds:.project,template:"%track",tracks:[],clips:[],regions:[]).jobs.isEmpty)
        let stems = AudioExportPlan(project:project,song:project.songs[0],source:.stems,bounds:.area,template:"%stem",tracks:[],clips:[one.id,two.id],regions:[],area:0...1)
        XCTAssertEqual(stems.jobs.map(\.fileName),["Count.wav","Count (2).wav"])
        XCTAssertEqual(stems.jobs.map(\.duration),[5,5],"Stems ignores global bounds")
        XCTAssertEqual(stems.jobs.map(\.start),[30,60])
    }
    func testRegionMatrixAndAreaBounds() {
        var project = Project.empty(name:"Project")
        var track = Track(id:UUID(),name:"Track/../../outside",role:.other)
        track.clips = [AudioClip(id:UUID(),name:"item",startTime:4,duration:10,audioFile:AudioFile(path:"item.wav"))]
        project.songs[0].tracks = [track]
        project.songs[0].parts = [Part(id:UUID(),name:"One",startTime:4,endTime:8),Part(id:UUID(),name:"Two",startTime:9,endTime:12)]
        let all = AudioExportPlan(project:project,song:project.songs[0],source:.masterAndTracks,bounds:.allRegions,template:"%region %track",tracks:[track.id],clips:[],regions:[])
        XCTAssertEqual(all.jobs.count,4)
        XCTAssertTrue(all.jobs.allSatisfy { !$0.fileName.contains("/") && !$0.fileName.contains("\\") })
        let area = AudioExportPlan(project:project,song:project.songs[0],source:.master,bounds:.area,template:"%project",tracks:[],clips:[],regions:[],area:2...7)
        XCTAssertEqual(area.jobs.first?.start,2); XCTAssertEqual(area.jobs.first?.end,7)
        let complete = AudioExportPlan(project:project,song:project.songs[0],source:.master,bounds:.project,template:"%project",tracks:[],clips:[],regions:[])
        XCTAssertEqual(complete.jobs.first?.start,0); XCTAssertEqual(complete.jobs.first?.end,14)
    }
}
