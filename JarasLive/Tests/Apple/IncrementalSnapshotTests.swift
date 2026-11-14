import Foundation

private func matchesNativeProject(_ value: Project, _ full: Project) -> Bool {
    var compared = value
    guard compared.songs.count == full.songs.count else { return false }
    func samePeaks(_ a: [Double], _ b: [Double]) -> Bool {
        // Ventura's full NSNumber -> JSON -> Double reference can round a
        // decimal peak by two ULPs. Cached arrays must retain their original
        // bits (checked separately), while metadata remains exactly equal.
        a.count == b.count && zip(a, b).allSatisfy { $0 == $1 || abs($0 - $1) <= 4 * max($0.ulp, $1.ulp) }
    }
    for song in compared.songs.indices {
        guard compared.songs[song].tracks.count == full.songs[song].tracks.count else { return false }
        for track in compared.songs[song].tracks.indices {
            guard compared.songs[song].tracks[track].clips.count == full.songs[song].tracks[track].clips.count else { return false }
            for item in compared.songs[song].tracks[track].clips.indices {
                let clip = compared.songs[song].tracks[track].clips[item], reference = full.songs[song].tracks[track].clips[item]
                guard samePeaks(clip.waveform, reference.waveform),
                      (clip.waveformChannels == nil) == (reference.waveformChannels == nil),
                      (clip.waveformChannels ?? []).count == (reference.waveformChannels ?? []).count,
                      zip(clip.waveformChannels ?? [], reference.waveformChannels ?? []).allSatisfy({ samePeaks($0, $1) }) else { return false }
                compared.songs[song].tracks[track].clips[item].waveform = reference.waveform
                compared.songs[song].tracks[track].clips[item].waveformChannels = reference.waveformChannels
            }
        }
    }
    return compared == full
}

final class MeasuringSnapshotCore: JarasCoreBridge {
    var loadMetadata = Data()
    var loadWaveforms: [String: [Data]] = [:]
    var editData = Data()
    var retainedIDs: [String] = []
    var pastedData: Data?
    var trackEditData = Data()
    var trackWaveformSources: [String: String] = [:]
    var trackSnapshotData = Data()
    var failNextTrackSnapshot = false
    override func load(projectData: Data, waveforms: [String: [Data]]) throws {
        try super.load(projectData: projectData, waveforms: waveforms)
        loadMetadata = projectData; loadWaveforms = waveforms
    }
    override func trackMetadataSnapshot(previousRevision: UInt64) throws -> Data {
        let result = try super.trackMetadataSnapshot(previousRevision: previousRevision)
        trackSnapshotData = result
        if failNextTrackSnapshot {
            failNextTrackSnapshot = false
            return Data("invalid snapshot".utf8)
        }
        return result
    }
    override func applyTrackStructureEdit(_ data: Data, trackOrders: [String: [String]], preservingWaveforms: [String: String]) throws {
        try super.applyTrackStructureEdit(data, trackOrders: trackOrders, preservingWaveforms: preservingWaveforms)
        trackEditData = data
        trackWaveformSources = preservingWaveforms
    }
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
    var clip = AudioClip(id: UUID(), name: "Recorded audio", startTime: 0, duration: 30, waveform: source, audioFile: AudioFile(path: "Stems/recording.wav"))
    clip.waveformChannels = [source, Array(source.reversed())]
    track.clips = [clip]; project.songs[0].tracks = [track]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    func matchesFull() throws -> ShowSnapshot {
        let cached = try executor.snapshot()
        let full = try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot())
        precondition(matchesNativeProject(cached.project, full.project), "metadata hydration must exactly match the full native project")
        let cachedTransport = try encoder.encode(cached.transport), fullTransport = try encoder.encode(full.transport)
        precondition(cachedTransport == fullTransport, "metadata hydration cannot modify either playback head")
        precondition(cached.nextSongId == full.nextSongId)
        return cached
    }
    try executor.load(project)
    try executor.setMIDIChannel(track.id, channel: 16)
    let channel16 = try matchesFull().project.songs[0].tracks[0].midiChannel
    precondition(channel16 == 16)
    try executor.setMIDIChannel(track.id, channel: 0)
    let allChannels = try matchesFull().project.songs[0].tracks[0].midiChannel
    precondition(allChannels == nil)
    try executor.execute(.clipNormalization, target: clip.id, value: 0.5)
    let normalized = try matchesFull().project.songs[0].tracks[0].clips[0]
    precondition(normalized.normalizationGain == 0.5 && normalized.gain == nil, "normalization crosses the native bridge independently from volume")
    try executor.execute(.clipNormalization, target: clip.id, value: 1)
    let loaded = try matchesFull()
    let originalStorage = source.withUnsafeBufferPointer { $0.baseAddress }
    precondition(loaded.project.songs[0].tracks[0].clips[0].waveform.withUnsafeBufferPointer { $0.baseAddress } == originalStorage, "hydration shares existing immutable waveform storage instead of allocating or decoding it")
    let fullSize = try core.snapshot().count, metadataSize = try core.metadataSnapshot().count
    precondition(metadataSize * 20 < fullSize, "metadata transfer is independent of the large waveform payload")
    precondition(core.loadMetadata.count * 20 < fullSize,
                 "opening a project must not encode its waveform samples into JSON")
    let rawPeaks = source.withUnsafeBytes { Data($0) }
    precondition(core.loadWaveforms[clip.id.uuidString] == [rawPeaks, rawPeaks, Array(source.reversed()).withUnsafeBytes { Data($0) }],
                 "the core receives the exact native bytes of every mono and channel waveform")
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
    let importedClip = AudioClip(id: UUID(), name: "Imported clip", startTime: 50, duration: 10, waveform: [0.8, 0.4], audioFile: AudioFile(path: "Stems/import.wav"), waveformChannels: [[0.1, 0.2], [0.6, 0.7]])
    imported.clips = [importedClip]
    try executor.insertAudioTracks([imported], song: project.songs[0].id)
    _ = try matchesFull()
    let recorded = AudioClip(id: UUID(), name: "New take", startTime: 40, duration: 5, waveform: [0.3, 0.9], audioFile: AudioFile(path: "Stems/take.wav"), waveformChannels: [[0.4, 0.5]])
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
    let previousProject = try matchesFull().project
    let invalidBuffers: [[String: [Data]]] = [
        [:], [clip.id.uuidString: []], [clip.id.uuidString: [Data([0])]],
        [clip.id.uuidString: [[Double.nan].withUnsafeBytes { Data($0) }]],
        [clip.id.uuidString: [rawPeaks], UUID().uuidString: [Data()]]
    ]
    for buffers in invalidBuffers {
        do { try core.load(projectData: core.loadMetadata, waveforms: buffers); preconditionFailure("invalid binary waveform load accepted") } catch {}
        let current = try matchesFull()
        precondition(current.project == previousProject, "a failed binary load must preserve the complete previous project")
    }
    print("BINARY_WAVEFORM_LOAD_EXACT_CHANNELS_SPLIT_AND_FAILURE_ATOMICITY_OK")
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
    pasteTrack.clips = [AudioClip(id: UUID(), name: "Original", startTime: 0, duration: 10, waveform: Array(repeating: 0.25, count: 4096), audioFile: AudioFile(path: "Stems/original.wav"), gain: 0.75, muted: true, fx: pasteFX)]
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
    var timeSettings = ProjectTimeSettings()
    timeSettings.timebase = .free; timeSettings.divisions = 0
    timeSettings.affectsMIDIItems = true; timeSettings.affectsAutomationLength = false
    let originalTiming = routed.project.songs[0]
    try pasteExecutor.setProjectTiming(bpm: 240, beats: 3, unit: 8, settings: timeSettings)
    var timed = try pasteExecutor.snapshot()
    precondition(timed.project.songs[0].projectTime == timeSettings && timed.project.songs[0].meterBeats == 3 && timed.project.songs[0].meterUnit == 8, "native timing configuration persists all controls together")
    precondition(timed.project.songs[0].tracks == originalTiming.tracks && timed.transport == routed.transport, "free grid never stretches items or moves playback heads")
    let reopened = LocalCommandExecutor()
    try reopened.load(timed.project)
    let reopenedTiming = try reopened.snapshot()
    precondition(reopenedTiming.project.songs[0].projectTime == timeSettings, "timebase and divisions survive the complete native project round trip")
    timeSettings.timebase = .relative; timeSettings.divisions = 8
    try pasteExecutor.setProjectTiming(bpm: 120, beats: 4, unit: 4, settings: timeSettings)
    timed = try pasteExecutor.snapshot()
    let timedItem = timed.project.songs[0].tracks[0].clips.first { $0.id == pastedClip.id }!
    let beforeTimedItem = originalTiming.tracks[0].clips.first { $0.id == pastedClip.id }!
    precondition(timedItem.startTime == beforeTimedItem.startTime * 2 && timedItem.audioRate == beforeTimedItem.audioRate / 2 && timedItem.waveform == pastedClip.waveform, "relative grid updates clip position and audio speed while retaining waveform storage")
    precondition(timedItem.waveform.withUnsafeBufferPointer { $0.baseAddress } == waveAddress, "timing changes do not recreate cached waveform arrays")
    var linkedProject = Project.empty(name: "Linked pair")
    var left = Track(id: UUID(), name: "Keys", role: .keys)
    left.volume = 0.6; left.pan = 0.2; left.inputPatch = OutputPatch(firstChannel: 5, channelCount: 2)
    var right = Track(id: UUID(), name: "Other", role: .keys)
    right.volume = 0.2; right.pan = -0.4; right.color = 0xff0033
    linkedProject.songs[0].tracks = [left,right]
    let beforeLink = linkedProject
    linkedProject.songs[0].linkTracks([left.id,right.id], firstInput: 5, color: 0x333333)
    let linked = LocalCommandExecutor(); try linked.load(linkedProject)
    try linked.execute(.volume, target: right.id, value: 0.75)
    try linked.execute(.pan, target: right.id, value: -0.3)
    var linkedState = try linked.snapshot().project
    precondition(linkedState.songs[0].tracks[0].volume == 0.75 && linkedState.songs[0].tracks[1].volume == 0.75)
    precondition(linkedState.songs[0].tracks[0].pan == 0.3 && linkedState.songs[0].tracks[1].pan == -0.3)
    try linked.execute(.pan, target: left.id, value: 0)
    try linked.setRecording(right.id, input: OutputPatch(firstChannel: 8,channelCount: 2), format: "wav")
    linkedState = try linked.snapshot().project
    precondition(linkedState.songs[0].tracks.allSatisfy { $0.pan == 0 && $0.inputPatch?.channelCount == 1 })
    precondition(linkedState.songs[0].tracks[0].inputPatch?.firstChannel == 7 && linkedState.songs[0].tracks[1].inputPatch?.firstChannel == 8)
    let restoredLink = LocalCommandExecutor(); try restoredLink.load(linkedState)
    var reopenedLink = try restoredLink.snapshot().project
    reopenedLink.songs[0].unlinkTracks(left.id)
    // Recording format was explicitly changed after linking and is independent.
    reopenedLink.songs[0].tracks[1].recordingFormat = nil
    precondition(reopenedLink.songs[0].tracks == beforeLink.songs[0].tracks, "unlink restores original mixer and routing after native save/reopen")
    try restoredLink.applyProjectEdit(reopenedLink)
    let unlinkedState = try restoredLink.snapshot()
    precondition(unlinkedState.project.songs[0].tracks == beforeLink.songs[0].tracks)
    print("LINKED_TRACKS_NATIVE_VOLUME_MIRRORED_PAN_MONO_INPUT_AND_REOPEN_RESTORE_OK")
    let channelsCore = LocalCommandExecutor()
    var channelsProject = Project.empty(name: "Channel modes")
    var channelTrack = Track(id: UUID(), name: "Stereo source", role: .keys)
    let channelClip = AudioClip(id: UUID(), name: "Original", startTime: 0, duration: 1, audioFile: AudioFile(path: "Stems/original.wav"), gain: 0.4, muted: true)
    channelTrack.clips = [channelClip]; channelsProject.songs[0].tracks = [channelTrack]
    try channelsCore.load(channelsProject)
    let channelBaseline = try channelsCore.snapshot().project.songs[0].tracks[0].clips[0]
    try channelsCore.execute(.masterMono, target: nil, value: 0)
    try channelsCore.setRecordingChannels(channelTrack.id, channel: 1)
    try channelsCore.execute(.clipChannelMode, target: channelClip.id, value: 3)
    let channelState = try channelsCore.snapshot().project
    precondition(channelState.masterMono == true)
    precondition(channelState.songs[0].tracks[0].recordingChannels == 1)
    precondition(channelState.songs[0].tracks[0].clips[0].channelMode == 3)
    let reopenedChannels = LocalCommandExecutor(); try reopenedChannels.load(channelState)
    let reopenedMono = try reopenedChannels.snapshot().project.masterMono
    precondition(reopenedMono == true)
    try reopenedChannels.execute(.masterMono, target: nil, value: 0)
    try reopenedChannels.execute(.clipChannelMode, target: channelClip.id, value: 0)
    let stereoState = try reopenedChannels.snapshot().project
    precondition(stereoState.masterMono != true)
    precondition(stereoState.songs[0].tracks[0].clips[0] == channelBaseline)
    print("CHANNEL_MODE_NATIVE_SAVE_REOPEN_AND_ORIGINAL_STEREO_RESTORE_OK")
    var stemProject = try channelsCore.snapshot().project
    let stemIDs = (0..<5).map { _ in UUID() }
    stemProject.songs[0].tracks[0].clips[0].separatedStemTracks = stemIDs
    try channelsCore.applyProjectEdit(stemProject)
    try channelsCore.execute(.volume, target: channelTrack.id, value: 0.4)
    let stemState = try channelsCore.snapshot().project
    precondition(stemState.songs[0].tracks[0].clips[0].separatedStemTracks == stemIDs)
    try reopenedChannels.load(stemState)
    let reopenedStems = try reopenedChannels.snapshot().project
    precondition(reopenedStems.songs[0].tracks[0].clips[0].separatedStemTracks == stemIDs)
    print("CATSTEM_NATIVE_BRIDGE_EDIT_MIXER_SAVE_REOPEN_ASSOCIATIONS_OK")
    let structuralCore = MeasuringSnapshotCore(), structural = LocalCommandExecutor(core: structuralCore)
    var large = project
    large.songs[0].tracks = (0..<32).map { index in
        var value = track; value.id = UUID(); value.name = "Track \(index)"
        value.clips[0].id = UUID(); return value
    }
    try structural.load(large)
    let before = try structural.snapshot().project
    var added = before
    let empty = Track(id: UUID(), name: "Added", role: .keys)
    added.songs[0].tracks.insert(empty, at: 2)
    added.songs[0].tracks[4].volume = 0.4
    try structural.applyTrackStructureEdit(added, previous: before)
    let delta = try JSONSerialization.jsonObject(with: structuralCore.trackEditData) as! [String: Any]
    let deltaTracks = ((delta["songs"] as! [[String: Any]])[0]["tracks"] as! [[String: Any]])
    precondition(deltaTracks.count == 2, "Adding a track and changing another transmits only those two tracks")
    func canonicalStructure() throws -> Project {
        let value = try structural.snapshot().project
        let full = try JSONDecoder().decode(ShowSnapshot.self, from: structuralCore.snapshot()).project
        precondition(matchesNativeProject(value, full), "Structural delta must match the complete canonical native project")
        return value
    }
    let afterAdded = try canonicalStructure()
    precondition(afterAdded == added && afterAdded.songs[0].tracks[2].id == empty.id)
    func returnedTrackCount() throws -> Int {
        let response = try JSONSerialization.jsonObject(with: structuralCore.trackSnapshotData) as! [String: Any]
        let snapshot = response["snapshot"] as! [String: Any], project = snapshot["project"] as! [String: Any]
        return (project["songs"] as! [[String: Any]]).reduce(0) { $0 + ($1["tracks"] as! [[String: Any]]).count }
    }
    let changedTrackCount = try returnedTrackCount()
    precondition(changedTrackCount == 2, "Snapshot decodes only the added and edited tracks")
    let unchangedSnapshot = try canonicalStructure(), unchangedTrackCount = try returnedTrackCount()
    precondition(unchangedSnapshot == afterAdded && unchangedTrackCount == 0, "Repeated reads retain canonical tracks without decoding them again")
    let fullMetadataSize = try structuralCore.metadataSnapshot().count
    precondition(structuralCore.trackSnapshotData.count * 3 < fullMetadataSize)
    let (copied, copiedIDs) = try afterAdded.trackDuplicationDraft([afterAdded.songs[0].tracks[0].id], song: afterAdded.songs[0].id)
    var invalidDraft = copied
    let draftIndex = invalidDraft.songs[0].tracks.firstIndex { copiedIDs.contains($0.id) }!
    invalidDraft.songs[0].tracks[draftIndex].clips[0].duration = -1
    do { try structural.applyTrackStructureEdit(invalidDraft, previous: afterAdded); preconditionFailure("Invalid copied metadata accepted") } catch {}
    let afterInvalidDraft = try canonicalStructure()
    precondition(afterInvalidDraft == afterAdded, "Draft construction does not commit invalid copied metadata")
    invalidDraft = copied
    invalidDraft.songs[0].tracks[draftIndex].clips[0].waveform = [.nan]
    do { try structural.applyTrackStructureEdit(invalidDraft, previous: afterAdded); preconditionFailure("Invalid copied waveform accepted") } catch {}
    let afterInvalidDraftWaveform = try canonicalStructure()
    precondition(afterInvalidDraftWaveform == afterAdded, "Draft construction cannot bypass waveform validation")
    try structural.execute(.play, target: nil, value: 0)
    try structural.execute(.subPlay, target: nil, value: 0)
    structural.advance(1)
    let running = try structural.playbackSnapshot()
    try structural.applyTrackStructureEdit(copied, previous: afterAdded)
    let afterCopy = try canonicalStructure(), afterCopyPlayback = try structural.playbackSnapshot()
    precondition(afterCopy == copied)
    precondition(afterCopyPlayback.transport == running.transport, "Duplicating tracks preserves both running playback heads")
    let copyDelta = try JSONSerialization.jsonObject(with: structuralCore.trackEditData) as! [String: Any]
    let copyTracks = (copyDelta["songs"] as! [[String: Any]])[0]["tracks"] as! [[String: Any]]
    precondition(copyTracks.count == copiedIDs.count, "Duplicate transmits only the new tracks")
    let copyItems = copyTracks.flatMap { $0["clips"] as! [[String: Any]] }
    precondition(copyItems.allSatisfy { ($0["waveform"] as? [Double])?.isEmpty == true && $0["waveformChannels"] == nil }, "Copies omit the immutable waveform arrays, including every stereo channel")
    precondition(structuralCore.trackWaveformSources.count == copyItems.count && structuralCore.trackWaveformSources.allSatisfy { $0.key != $0.value }, "Copies reuse the waveform of an existing native item under their new IDs")
    let copiesWithWaveforms = try JSONEncoder().encode(copied.songs[0].tracks.filter { copiedIDs.contains($0.id) })
    precondition(structuralCore.trackEditData.count * 20 < copiesWithWaveforms.count)
    let badOrder = [copied.songs[0].id.uuidString: [UUID().uuidString]]
    do { try structuralCore.applyTrackStructureEdit(structuralCore.trackEditData, trackOrders: badOrder, preservingWaveforms: [:]); preconditionFailure("Unknown retained track accepted") } catch {}
    let afterFailure = try canonicalStructure(), afterFailurePlayback = try structural.playbackSnapshot()
    precondition(afterFailure == copied && afterFailurePlayback.transport == afterCopyPlayback.transport, "Invalid structural delta is atomic")
    let completeOrder = [copied.songs[0].id.uuidString: copied.songs[0].tracks.map { $0.id.uuidString }]
    let invalidSource = [copyItems[0]["id"] as! String: UUID().uuidString]
    do { try structuralCore.applyTrackStructureEdit(structuralCore.trackEditData, trackOrders: completeOrder, preservingWaveforms: invalidSource); preconditionFailure("Unknown waveform source accepted") } catch {}
    let afterInvalidSource = try canonicalStructure()
    precondition(afterInvalidSource == copied, "A missing waveform source leaves the native project unchanged")
    var changedCopy = copied
    let copyIndex = changedCopy.songs[0].tracks.firstIndex { copiedIDs.contains($0.id) }!
    let changedItemID = changedCopy.songs[0].tracks[copyIndex].clips[0].id
    changedCopy.songs[0].tracks[copyIndex].clips[0].waveform = [0.3, 0.6]
    changedCopy.songs[0].tracks[copyIndex].clips[0].waveformChannels = [[0.1, 0.2], [0.4, 0.5]]
    try structural.applyTrackStructureEdit(changedCopy, previous: copied)
    let changedCopyState = try canonicalStructure()
    precondition(changedCopyState == changedCopy && structuralCore.trackWaveformSources[changedItemID.uuidString] == nil, "Edited waveform arrays are transferred instead of borrowing another item's old values")
    try structural.applyTrackStructureEdit(before, previous: changedCopy)
    let undone = try canonicalStructure()
    precondition(undone == before, "Undo removes new tracks and restores edited tracks and waveforms")
    try structural.execute(.volume, target: before.songs[0].tracks[0].id, value: 0.3)
    structuralCore.failNextTrackSnapshot = true
    do { _ = try structural.snapshot(); preconditionFailure("Broken snapshot decoded") } catch {}
    let recovered = try canonicalStructure(), recoveredTracks = try returnedTrackCount()
    precondition(recovered.songs[0].tracks[0].volume == 0.3 && recoveredTracks == before.songs[0].tracks.count,
                 "A lost response requests a complete canonical snapshot without missing edits")
    _ = try structuralCore.trackMetadataSnapshot(previousRevision: 0)
    let afterOtherReader = try canonicalStructure(), otherReaderTrackCount = try returnedTrackCount()
    precondition(afterOtherReader == recovered && otherReaderTrackCount == before.songs[0].tracks.count,
                 "Another snapshot reader cannot desynchronize the retained track cache")
    var reordered = recovered
    reordered.songs[0].tracks.swapAt(0, 1)
    try structural.applyTrackStructureEdit(reordered, previous: recovered)
    let afterReorder = try canonicalStructure(), reorderedTrackCount = try returnedTrackCount()
    precondition(afterReorder == reordered && reorderedTrackCount == 0, "Canonical order changes retain existing track values")
    var replacementProject = Project.empty(name: "Replacement with reused IDs")
    replacementProject.songs[0] = reordered.songs[0]
    replacementProject.setlists[0].songIds = [replacementProject.songs[0].id]
    replacementProject.songs[0].tracks[0].clips[0].waveform = [0.7]
    try structural.execute(.stopAll, target: nil, value: 0)
    try structural.load(replacementProject)
    let afterReplacement = try canonicalStructure()
    precondition(afterReplacement.id == replacementProject.id && afterReplacement.songs[0].tracks[0].clips[0].waveform == [0.7],
                 "Project replacement refreshes media arrays even when canonical track metadata is unchanged")
    var noPeaks = afterReplacement
    noPeaks.songs[0].tracks[0].clips[0].waveform = []
    noPeaks.songs[0].tracks[0].clips[0].waveformChannels = nil
    try structural.applyTrackStructureEdit(noPeaks, previous: afterReplacement)
    let emptyPeaks = try canonicalStructure()
    precondition(emptyPeaks == noPeaks, "Removing waveform arrays hydrates canonical empty storage on unchanged metadata")
    var noPeaksOnLoad = Project.empty(name: "No waveform on load")
    noPeaksOnLoad.songs[0].parts = [Part(id: UUID(), name: "Region", startTime: 0, endTime: 60)]
    var noPeaksTrack = Track(id: UUID(), name: "Silent audio", role: .other)
    noPeaksTrack.clips = [AudioClip(id: UUID(), name: "Empty peaks", startTime: 0, duration: 1)]
    noPeaksOnLoad.songs[0].tracks = [noPeaksTrack]
    try structural.load(noPeaksOnLoad)
    _ = try canonicalStructure()
    try structural.addTrack(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
    let nativeTimecode = try canonicalStructure()
    let timecodeID = nativeTimecode.songs[0].tracks.first { $0.kind == .timecode }!.id
    try structural.resizeRegion(nativeTimecode.songs[0].parts[0].id, start: 0, end: 80)
    let normalizedTimecode = try canonicalStructure()
    precondition(normalizedTimecode.songs[0].tracks.first { $0.id == timecodeID }?.clips != nativeTimecode.songs[0].tracks.first { $0.id == timecodeID }?.clips,
                 "Snapshot returns regenerated timecode items after a native region edit")
    print("TRACK_METADATA_DELTA_CANONICAL_ORDER_CHANGED_TRACKS_FAILURE_RECOVERY_OTHER_READER_AND_PROJECT_REPLACEMENT_OK")
    print("TRACK_STRUCTURE_DELTA_OMITS_UNCHANGED_TRACKS_PRESERVES_ORDER_WAVEFORMS_PLAYBACK_UNDO_AND_ATOMIC_FAILURE_OK")
    print("LOCAL_METADATA_SNAPSHOT_CACHE_COW_IMPORT_RECORD_SPLIT_UNDO_FAILURE_AND_TRANSPORT_OK fullBytes=\(fullSize) metadataBytes=\(metadataSize) retainedEditBytes=\(retainedEditBytes)")
}
try MainActor.assumeIsolated { try runSnapshotCacheTests() }
