import Foundation

final class MeasuringSnapshotCore: JarasCoreBridge {
    var editData = Data()
    var retainedIDs: [String] = []
    var pastedData: Data?
    override func pasteItems(_ data: Data, song: String, moving: Bool) throws {
        try super.pasteItems(data, song: song, moving: moving)
        pastedData = data
    }
    override func applyProjectMetadataEdit(_ data: Data, preservingWaveforms identifiers: [String]) throws {
        try super.applyProjectMetadataEdit(data, preservingWaveforms: identifiers)
        editData = data; retainedIDs = identifiers
    }
}
@MainActor func runSnapshotCacheTests() throws {
    let core = MeasuringSnapshotCore(), executor = LocalCommandExecutor(core: core)
    var project = Project.empty(name: "Waveform cache")
    var track = Track(id: UUID(), name: "Audio", role: .keys)
    let source = (0..<10_000).map { Double($0 % 100) / 100 }
    var clip = AudioClip(id: UUID(), name: "Recorded audio", startTime: 0, duration: 30, waveform: source, audioFile: AudioFile(path: "Steams/recording.wav"))
    clip.waveformChannels = [source, Array(source.reversed())]
    track.clips = [clip]; project.songs[0].tracks = [track]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    func matchesFull() throws -> ShowSnapshot {
        let cached = try executor.snapshot()
        let full = try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot())
        precondition(cached.project == full.project, "metadata hydration must exactly match the full native project")
        let cachedTransport = try encoder.encode(cached.transport), fullTransport = try encoder.encode(full.transport)
        precondition(cachedTransport == fullTransport, "metadata hydration cannot modify either playback head")
        precondition(cached.nextSongId == full.nextSongId)
        return cached
    }
    try executor.load(project)
    let loaded = try matchesFull()
    let originalStorage = source.withUnsafeBufferPointer { $0.baseAddress }
    precondition(loaded.project.songs[0].tracks[0].clips[0].waveform.withUnsafeBufferPointer { $0.baseAddress } == originalStorage, "hydration shares existing immutable waveform storage instead of allocating or decoding it")
    let fullSize = try core.snapshot().count, metadataSize = try core.metadataSnapshot().count
    precondition(metadataSize * 20 < fullSize, "metadata transfer is independent of the large waveform payload")
    var unchangedWaves = loaded.project
    unchangedWaves.songs[0].tracks[0].name = "Renamed track"
    try executor.applyProjectEdit(unchangedWaves)
    precondition(core.retainedIDs == [clip.id.uuidString] && core.editData.count * 20 < fullSize, "structural edits omit every unchanged waveform from their JSON payload")
    let retainedEditBytes = core.editData.count
    let retainedStorage = try matchesFull()
    precondition(retainedStorage.project.songs[0].tracks[0].clips[0].waveform.withUnsafeBufferPointer { $0.baseAddress } == originalStorage, "structural edits keep sharing the same immutable Swift waveform")
    var changedWaves = unchangedWaves
    changedWaves.songs[0].tracks[0].clips[0].waveform = [0.2, 0.9]
    changedWaves.songs[0].tracks[0].clips[0].waveformChannels = [[0.3, 0.4]]
    try executor.applyProjectEdit(changedWaves)
    precondition(core.retainedIDs.isEmpty, "changed waveform storage is transmitted instead of silently retaining stale values")
    _ = try matchesFull()
    try executor.applyProjectEdit(unchangedWaves)
    precondition(core.retainedIDs.isEmpty, "undo restores the real old waveform when the cached data changed")
    _ = try matchesFull()
    var invalidWave = unchangedWaves
    invalidWave.songs[0].tracks[0].clips[0].waveform = [1.2]
    do { try executor.applyProjectEdit(invalidWave); preconditionFailure("invalid changed waveform accepted") } catch {}
    _ = try matchesFull()
    var invalidMetadata = unchangedWaves
    invalidMetadata.songs[0].tracks[0].clips[0].duration = -1
    do { try executor.applyProjectEdit(invalidMetadata); preconditionFailure("invalid retained metadata accepted") } catch {}
    _ = try matchesFull()
    try executor.execute(.play, target: nil, value: 0)
    try executor.execute(.subSeek, target: nil, value: 20)
    try executor.execute(.subPlay, target: nil, value: 0)
    executor.advance(2)
    let beforeEdits = try executor.playbackSnapshot()
    for command in [ShowCommand.clipGain, .clipMute, .mute, .solo, .pan, .volume] {
        let target = command == .clipGain || command == .clipMute ? clip.id : track.id
        try executor.execute(command, target: target, value: command == .clipGain ? 0.25 : 0)
        let current = try matchesFull()
        precondition(current.project.songs[0].tracks[0].clips[0].waveform == source, "scalar edits retain all cached waveform values")
    }
    let afterEdits = try executor.playbackSnapshot()
    let beforeTransport = try encoder.encode(beforeEdits.transport), afterTransport = try encoder.encode(afterEdits.transport)
    precondition(beforeTransport == afterTransport, "metadata reads and scalar edits preserve both running clocks")
    var imported = Track(id: UUID(), name: "Imported", role: .guitar)
    let importedClip = AudioClip(id: UUID(), name: "Imported clip", startTime: 50, duration: 10, waveform: [0.8, 0.4], audioFile: AudioFile(path: "Steams/import.wav"), waveformChannels: [[0.1, 0.2], [0.6, 0.7]])
    imported.clips = [importedClip]
    try executor.insertAudioTracks([imported], song: project.songs[0].id)
    _ = try matchesFull()
    let recorded = AudioClip(id: UUID(), name: "New take", startTime: 40, duration: 5, waveform: [0.3, 0.9], audioFile: AudioFile(path: "Steams/take.wav"), waveformChannels: [[0.4, 0.5]])
    try executor.addRecordedClip(recorded, track: track.id)
    _ = try matchesFull()
    var draft = try executor.snapshot().project
    draft.splitItems([clip.id], at: 10)
    let beforeSplitTransport = try encoder.encode(executor.playbackSnapshot().transport)
    try executor.applyProjectEdit(draft)
    let afterSplitTransport = try encoder.encode(executor.playbackSnapshot().transport)
    precondition(beforeSplitTransport == afterSplitTransport, "incremental structural edits preserve both live playback clocks without a project reload")
    let split = try matchesFull()
    precondition(split.project.songs[0].tracks[0].clips.count == 3, "split keeps both newly identified waveform pieces and the take")
    precondition(split.project.songs[0].tracks[0].clips[0].waveform.count < source.count, "same-ID split replaces the cached waveform too")
    try executor.applyProjectEdit(project)
    _ = try matchesFull()
    try executor.addTrack(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
    try executor.regionFromClip(clip.id)
    let timecode = try matchesFull()
    precondition(timecode.project.songs[0].tracks.first?.kind == .timecode && timecode.project.songs[0].tracks.first?.clips.first?.waveformChannels == nil, "native generated IDs hydrate to canonical empty waveform metadata")
    var invalid = project; invalid.songs[0].duration = -1
    do { try executor.load(invalid); preconditionFailure("invalid load accepted") } catch {}
    _ = try matchesFull()
    var invalidTrack = imported; invalidTrack.id = UUID(); invalidTrack.clips[0].id = clip.id; invalidTrack.clips[0].waveform = [0.99]
    do { try executor.insertAudioTracks([invalidTrack], song: project.songs[0].id); preconditionFailure("duplicate clip accepted") } catch {}
    _ = try matchesFull()
    let replacement = Project.empty(name: "Next project")
    try executor.execute(.stopAll, target: nil, value: 0)
    try executor.load(replacement)
    let replaced = try executor.snapshot()
    precondition(replaced.project.songs.flatMap(\.tracks).flatMap(\.clips).isEmpty, "project replacement does not leak old waveform metadata")
    let pasteCore = MeasuringSnapshotCore(), pasteExecutor = LocalCommandExecutor(core: pasteCore)
    var original = Project.empty(name: "Paste metadata")
    var pasteTrack = Track(id: UUID(), name: "Audio", role: .keys)
    var pasteFX = NativeFXSettings(); pasteFX.inserted = ["EQ"]; pasteFX.eqEnabled = true
    pasteTrack.clips = [AudioClip(id: UUID(), name: "Original", startTime: 0, duration: 10, waveform: Array(repeating: 0.25, count: 4096), audioFile: AudioFile(path: "Steams/original.wav"), gain: 0.75, muted: true, fx: pasteFX)]
    original.songs[0].tracks = [pasteTrack]; original.songs[0].duration = 10
    try pasteExecutor.load(original)
    let songID = original.songs[0].id
    let clipID = original.songs[0].tracks[0].clips[0].id
    let clipboard = GridItemClipboard(project: original, song: songID, selected: [clipID])!
    let pasted = try clipboard.items(in: original, at: 300)
    try pasteExecutor.pasteItems(pasted, song: songID, moving: false)
    let pastedJSON = try JSONSerialization.jsonObject(with: pasteCore.pastedData!) as! [[String: Any]]
    let encodedClip = (pastedJSON[0]["clips"] as! [[String: Any]])[0]
    precondition((encodedClip["waveform"] as! [Double]).isEmpty && encodedClip["waveformChannels"] == nil, "paste sends only item metadata without encoding waveform arrays")
    let afterPaste = try pasteExecutor.snapshot()
    let pastedClip = afterPaste.project.songs[0].tracks[0].clips.first { $0.id == pasted[0].clip.id }!
    let expected = pasted[0].clip
    precondition(pastedClip.id == expected.id && pastedClip.startTime == expected.startTime && pastedClip.duration == expected.duration && pastedClip.sourceOffset == expected.sourceOffset && pastedClip.audioRate == expected.audioRate && pastedClip.name == expected.name && pastedClip.fx == expected.fx && pastedClip.muted == expected.muted && pastedClip.gain == expected.gain && pastedClip.audioFile == expected.audioFile && pastedClip.waveform == expected.waveform, "native paste retains all FX, mute, gain, source and cached waveform values")
    let waveAddress = pastedClip.waveform.withUnsafeBufferPointer { $0.baseAddress }
    precondition(waveAddress == pasted[0].clip.waveform.withUnsafeBufferPointer { $0.baseAddress }, "paste reuses immutable waveform storage")
    var moved = pasted
    moved[0].clip.startTime = 350
    try pasteExecutor.pasteItems(moved, song: songID, moving: true)
    let afterMove = try pasteExecutor.snapshot()
    precondition(afterMove.project.songs[0].tracks[0].clips.filter { $0.id == moved[0].clip.id }.count == 1)
    precondition(afterMove.project.songs[0].tracks[0].clips.first { $0.id == moved[0].clip.id }?.startTime == 350)
    precondition(afterMove.transport == afterPaste.transport, "copy and move never change either playback cursor")

    let patches: [OutputPatch] = [.master, .stereo, OutputPatch(firstChannel: 3, channelCount: 2), OutputPatch(firstChannel: 5, channelCount: 1)]
    try pasteExecutor.setOutputPatches(track: pasteTrack.id, patches: patches)
    try pasteExecutor.setOutputPatches(track: nil, patches: Array(patches.dropFirst()))
    var routed = try pasteExecutor.snapshot()
    precondition(routed.project.songs[0].tracks[0].outputPatches == patches && routed.project.masterOutputPatches == Array(patches.dropFirst()), "native bridge persists all route instances")
    precondition(routed.transport == afterMove.transport, "routing updates preserve running state and cursors")
    try pasteExecutor.setOutputPatches(track: pasteTrack.id, patches: [])
    routed = try pasteExecutor.snapshot()
    precondition(routed.project.songs[0].tracks[0].outputPatches.isEmpty, "native metadata retains explicitly empty routes")
    print("LOCAL_METADATA_SNAPSHOT_CACHE_COW_IMPORT_RECORD_SPLIT_UNDO_FAILURE_AND_TRANSPORT_OK fullBytes=\(fullSize) metadataBytes=\(metadataSize) retainedEditBytes=\(retainedEditBytes)")
}
try MainActor.assumeIsolated { try runSnapshotCacheTests() }
