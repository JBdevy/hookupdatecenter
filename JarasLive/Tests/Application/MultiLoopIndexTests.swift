import XCTest
@testable import JarasApplication

@MainActor private final class LoopIndexExecutor: CommandExecutor {
    var project = Project.empty(name: "Indexed loop mixer")
    var transport = TransportState(playing: true, position: 0, queue: QueueState(),
        loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var commands: [ShowCommand] = []
    func load(_ project: Project) throws {
        self.project = project
        transport.songId = project.songs[0].id; transport.multiLoop = nil
    }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        for s in project.songs.indices {
            guard let t = project.songs[s].tracks.firstIndex(where: { $0.id == target }) else { continue }
            if command == .mute { project.songs[s].tracks[t].mute.toggle() }
            if command == .solo { project.songs[s].tracks[t].solo.toggle() }
            if command == .volume { project.songs[s].tracks[t].volume = value }
        }
    }
    func reorderTrack(_ track: UUID, before: UUID?) throws {
        for s in project.songs.indices {
            guard let old = project.songs[s].tracks.firstIndex(where: { $0.id == track }) else { continue }
            let row = project.songs[s].tracks.remove(at: old)
            let destination = before.flatMap { id in project.songs[s].tracks.firstIndex(where: { $0.id == id }) } ?? project.songs[s].tracks.count
            project.songs[s].tracks.insert(row, at: destination)
            return
        }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class MultiLoopIndexTests: XCTestCase {
    private func loop(_ tracks: [Track]) -> MultiLoopPlayback {
        MultiLoopPlayback(id: UUID(), start: 10, end: 20, amount: 0.5, gates: false, released: false,
            tracks: tracks.map { track in
                var rule = MultiLoopTrack(id: track.id, gain: 0.1); rule.autoFader = true; return rule
            })
    }

    #if DEBUG
    @MainActor func testAutomaticMixerLookupWorkScalesLinearlyAt100500And1000Tracks() throws {
        for count in [100, 500, 1000] {
            var project = Project.empty(name: "\(count) automatic faders")
            project.songs[0].tracks = (0..<count).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
            let executor = LoopIndexExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            executor.transport.multiLoop = loop(project.songs[0].tracks)
            show.tick()
            let before = show.loopMixerLookupWork
            XCTAssertEqual(before.indexedTracks, count)
            let frames = 40
            for frame in 0..<frames {
                executor.transport.multiLoop?.amount = Double(frame) / Double(frames)
                show.tick()
            }
            let after = show.loopMixerLookupWork
            XCTAssertEqual(after.indexedTracks, before.indexedTracks, "continuous fades reuse the index")
            XCTAssertEqual(after.lookups - before.lookups, count * frames * 2,
                "each rule makes two constant-time lookups instead of scanning the track array")
            XCTAssertTrue(executor.commands.isEmpty)
            XCTAssertEqual(show.snapshot.project, project)
            print("LOOP_MIXER_LINEAR_LOOKUPS tracks=\(count) frames=\(frames) indexed=\(after.indexedTracks) lookups=\(after.lookups - before.lookups)")
        }
    }
    #endif

    @MainActor func testReorderingCannotReadAnotherTracksCachedMixerState() throws {
        var project = Project.empty(name: "Reordered loop mixer")
        let active = Track(id: UUID(), name: "Automatic", role: .other)
        var muted = Track(id: UUID(), name: "Muted neighbour", role: .other); muted.mute = true
        project.songs[0].tracks = [active, muted]
        let executor = LoopIndexExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        executor.transport.multiLoop = loop([active]); show.tick()
        show.reorderTrack(muted.id, before: active.id)
        show.tick()
        XCTAssertEqual(show.current?.tracks.map(\.id), [muted.id, active.id])
        XCTAssertEqual(show.current?.tracks.map(\.mute), [true, false])
        XCTAssertTrue(executor.commands.isEmpty, "a stale position would read the neighbour's mute and toggle the automatic track")
        show.sendMixerControl(.mute, target: active.id); show.tick()
        XCTAssertEqual(show.current?.tracks.map(\.mute), [true, true])
        executor.transport.multiLoop = nil; show.tick()
        XCTAssertEqual(show.current?.tracks.map(\.mute), [true, true])
    }

    @MainActor func testReloadAndImportSameProjectIdentityRebuildPositionsAndDropRemovedTracks() throws {
        for importing in [false, true] {
            var project = Project.empty(name: "Replaced index")
            let removed = Track(id: UUID(), name: "Removed", role: .other)
            let retained = Track(id: UUID(), name: "Retained", role: .other)
            project.songs[0].tracks = [removed, retained]
            let executor = LoopIndexExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            executor.transport.multiLoop = loop(project.songs[0].tracks); show.tick()
            #if DEBUG
            let indexed = show.loopMixerLookupWork.indexedTracks
            #endif
            project.songs[0].tracks = [retained]
            project.songs[0].tracks[0].mute = true
            if importing { try show.importProject(ProjectDocumentCodec.encode(project)) }
            else { try show.replaceProject(project) }
            executor.transport.multiLoop = loop(project.songs[0].tracks); show.tick()
            XCTAssertEqual(show.current?.tracks.map(\.id), [retained.id])
            XCTAssertEqual(show.current?.tracks.first?.mute, true)
            #if DEBUG
            XCTAssertEqual(show.loopMixerLookupWork.indexedTracks - indexed, 1)
            #endif
            show.sendMixerControl(.mute, target: retained.id); show.tick()
            XCTAssertEqual(show.current?.tracks.first?.mute, false)
            executor.transport.multiLoop = nil; show.tick()
            XCTAssertEqual(show.current?.tracks.first?.mute, false)
        }
    }

    @MainActor func testIndexRestoresThePreviousSongsGatesWithoutReadingCurrentSongPositions() throws {
        var project = Project.empty(name: "Index across songs")
        let oldTrack = Track(id: UUID(), name: "Old", role: .other)
        project.songs[0].tracks = [oldTrack]
        var nextSong = Project.empty(name: "Next").songs[0]
        var nextTrack = Track(id: UUID(), name: "Next", role: .other); nextTrack.mute = true
        nextSong.tracks = [nextTrack]; project.songs.append(nextSong)
        let executor = LoopIndexExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        var active = loop([oldTrack]); active.gates = true; active.tracks[0].mute = true
        executor.transport.multiLoop = active; show.tick(); show.tick()
        XCTAssertTrue(show.snapshot.project.songs[0].tracks[0].mute)
        #if DEBUG
        let indexed = show.loopMixerLookupWork.indexedTracks
        #endif
        executor.transport.songId = nextSong.id; executor.transport.multiLoop = nil
        show.tick()
        XCTAssertFalse(show.snapshot.project.songs[0].tracks[0].mute)
        XCTAssertTrue(show.snapshot.project.songs[1].tracks[0].mute)
        #if DEBUG
        XCTAssertEqual(show.loopMixerLookupWork.indexedTracks, indexed, "song selection alone does not invalidate project track positions")
        #endif
    }
}
