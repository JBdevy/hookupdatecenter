import XCTest
@testable import JarasApplication

@MainActor private final class ManualLoopGateExecutor: CommandExecutor {
    var project = Project.empty(name: "Manual gates during a fade")
    var transport = TransportState(playing: true, position: 0, queue: QueueState(),
        loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var writes: [(command: ShowCommand, target: UUID?)] = []
    func load(_ project: Project) throws {
        self.project = project; transport.songId = project.songs[0].id
    }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        writes.append((command, target))
        for song in project.songs.indices {
            guard let index = project.songs[song].tracks.firstIndex(where: { $0.id == target }) else { continue }
            if command == .mute { project.songs[song].tracks[index].mute.toggle() }
            if command == .solo { project.songs[song].tracks[index].solo.toggle() }
            if command == .volume { project.songs[song].tracks[index].volume = value }
        }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class MultiLoopManualGateTests: XCTestCase {
    private func project(_ states: [Bool], command: ShowCommand) -> Project {
        var project = Project.empty(name: "Manual gates")
        project.songs[0].tracks = states.enumerated().map { index, state in
            var track = Track(id: UUID(), name: "Track \(index)", role: .other)
            track.volume = 0.25 + Double(index) * 0.1
            if command == .mute { track.mute = state } else { track.solo = state }
            return track
        }
        return project
    }
    private func loop(_ project: Project, command: ShowCommand, forced: Set<UUID> = []) -> MultiLoopPlayback {
        let rules = project.songs[0].tracks.map { track in
            var rule = MultiLoopTrack(id: track.id, gain: 0.1)
            rule.autoFader = true
            if command == .mute { rule.mute = forced.contains(track.id) }
            else { rule.solo = forced.contains(track.id) }
            return rule
        }
        return MultiLoopPlayback(id: UUID(), start: 10, end: 20, amount: 0.4,
            gates: !forced.isEmpty, released: false, tracks: rules)
    }
    private func states(_ project: Project, command: ShowCommand) -> [Bool] {
        project.songs[0].tracks.map { command == .mute ? $0.mute : $0.solo }
    }
    @MainActor private func assertState(_ show: ShowController, _ executor: ManualLoopGateExecutor,
        command: ShowCommand, expected: [Bool], volumes: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(states(show.snapshot.project, command: command), expected, file: file, line: line)
        XCTAssertEqual(executor.project, show.snapshot.project, file: file, line: line)
        XCTAssertEqual(show.current?.tracks.map(\.volume), volumes, file: file, line: line)
        XCTAssertFalse(executor.writes.contains { $0.command == .volume }, file: file, line: line)
    }

    @MainActor func testSingleManualMuteAndSoloSurviveFollowingFadeTicksAndExit() throws {
        for command: ShowCommand in [.mute, .solo] {
            for initial in [false, true] {
                let project = project([initial], command: command), executor = ManualLoopGateExecutor()
                let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
                let target = project.songs[0].tracks[0].id, volumes = project.songs[0].tracks.map(\.volume)
                executor.transport.multiLoop = loop(project, command: command); show.tick()
                show.sendMixerControl(command, target: target)
                assertState(show, executor, command: command, expected: [!initial], volumes: volumes)
                XCTAssertTrue(show.hasUnsavedChanges)
                XCTAssertTrue(show.canUndo)
                let manualWrites = executor.writes.count
                for step in 1...12 {
                    executor.transport.multiLoop?.amount = Double(step) / 12
                    executor.transport.multiLoop?.released = step > 6
                    show.tick()
                    assertState(show, executor, command: command, expected: [!initial], volumes: volumes)
                }
                executor.transport.multiLoop = nil; show.tick()
                assertState(show, executor, command: command, expected: [!initial], volumes: volumes)
                XCTAssertEqual(executor.writes.count, manualWrites, "the fade must not undo or resend the manual gate")
                XCTAssertEqual(executor.writes.filter { $0.command == command }.count, 1)
            }
        }
    }

    @MainActor func testSelectedMixedGatesChangeOnlyTheTargetsThatNeedTheRequestedState() throws {
        for command: ShowCommand in [.mute, .solo] {
            let project = project([false, true, false], command: command), executor = ManualLoopGateExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let tracks = project.songs[0].tracks, volumes = tracks.map(\.volume)
            executor.transport.multiLoop = loop(project, command: command); show.tick()
            show.setMixerTrackSelection([tracks[0].id, tracks[1].id], anchor: tracks[0].id)
            show.sendMixerControl(command, target: tracks[0].id)
            XCTAssertEqual(executor.writes.map(\.target), [tracks[0].id])
            show.tick()
            assertState(show, executor, command: command, expected: [true, true, false], volumes: volumes)
            show.sendMixerControl(command, target: tracks[1].id)
            XCTAssertEqual(Set(executor.writes.suffix(2).compactMap(\.target)), [tracks[0].id, tracks[1].id])
            for step in 0..<8 {
                executor.transport.multiLoop?.amount = Double(step) / 8; show.tick()
                assertState(show, executor, command: command, expected: [false, false, false], volumes: volumes)
            }
            executor.transport.multiLoop = nil; show.tick()
            assertState(show, executor, command: command, expected: [false, false, false], volumes: volumes)
            XCTAssertEqual(executor.writes.count, 3, "unchanged selection members must not toggle their stored manual base")
        }
    }

    @MainActor func testManualControlMatchesExplicitMixerCommandWhilePresetForcesTheGate() throws {
        for command: ShowCommand in [.mute, .solo] {
            for initial in [false, true] {
                let project = project([initial], command: command)
                let uiExecutor = ManualLoopGateExecutor(), explicitExecutor = ManualLoopGateExecutor()
                let ui = try ShowController(executor: uiExecutor, persistence: MemoryProjectStore(), initialProject: project)
                let explicit = try ShowController(executor: explicitExecutor, persistence: MemoryProjectStore(), initialProject: project)
                let target = project.songs[0].tracks[0].id, volumes = project.songs[0].tracks.map(\.volume)
                let active = loop(project, command: command, forced: [target])
                uiExecutor.transport.multiLoop = active; explicitExecutor.transport.multiLoop = active
                ui.tick(); explicit.tick()
                assertState(ui, uiExecutor, command: command, expected: [true], volumes: volumes)
                ui.sendMixerControl(command, target: target); explicit.send(command, target: target)
                assertState(ui, uiExecutor, command: command, expected: [false], volumes: volumes)
                XCTAssertEqual(ui.snapshot.project, explicit.snapshot.project)
                ui.tick(); explicit.tick()
                assertState(ui, uiExecutor, command: command, expected: [true], volumes: volumes)
                XCTAssertEqual(ui.snapshot.project, explicit.snapshot.project)
                uiExecutor.transport.multiLoop?.gates = false; explicitExecutor.transport.multiLoop?.gates = false
                uiExecutor.transport.multiLoop?.released = true; explicitExecutor.transport.multiLoop?.released = true
                ui.tick(); explicit.tick()
                assertState(ui, uiExecutor, command: command, expected: [!initial], volumes: volumes)
                XCTAssertEqual(ui.snapshot.project, explicit.snapshot.project,
                    "the user toggles the stored manual base even while a preset forces the displayed gate")
                uiExecutor.transport.multiLoop = nil; explicitExecutor.transport.multiLoop = nil
                ui.tick(); explicit.tick()
                assertState(ui, uiExecutor, command: command, expected: [!initial], volumes: volumes)
                XCTAssertEqual(ui.snapshot.project, explicit.snapshot.project)
                XCTAssertEqual(uiExecutor.writes.map(\.command), explicitExecutor.writes.map(\.command))
            }
        }
    }

    @MainActor func testPresetAndSelectionKeepIndependentManualBasesForChangedAndUnchangedTracks() throws {
        for command: ShowCommand in [.mute, .solo] {
            let project = project([false, true, true, false], command: command), executor = ManualLoopGateExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let tracks = project.songs[0].tracks, volumes = tracks.map(\.volume)
            executor.transport.multiLoop = loop(project, command: command, forced: [tracks[0].id]); show.tick()
            assertState(show, executor, command: command, expected: [true, true, true, false], volumes: volumes)
            show.setMixerTrackSelection([tracks[0].id, tracks[1].id, tracks[3].id], anchor: tracks[0].id)
            let before = executor.writes.count
            show.sendMixerControl(command, target: tracks[0].id)
            XCTAssertEqual(Set(executor.writes.dropFirst(before).compactMap(\.target)), [tracks[0].id, tracks[1].id])
            assertState(show, executor, command: command, expected: [false, false, true, false], volumes: volumes)
            show.tick()
            assertState(show, executor, command: command, expected: [true, false, true, false], volumes: volumes)
            executor.transport.multiLoop?.released = true; executor.transport.multiLoop?.amount = 0.2; show.tick()
            executor.transport.multiLoop = nil; show.tick()
            assertState(show, executor, command: command, expected: [true, false, true, false], volumes: volumes)
        }
    }
}
