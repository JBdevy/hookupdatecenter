import Foundation
@MainActor final class LocalCommandExecutor: CommandExecutor {
    func setProjectSyncID(_ id: UUID) { core.setProjectSyncID(id.uuidString) }
    func executeAutomation(_ command: ShowCommand, target: UUID?, value: Double) throws { try core.executeAutomation(command: command.rawValue, target: target?.uuidString, value: value) }
    func projectSyncFrame() throws -> Data { try core.projectSyncFrame() }
    func applyProjectSync(_ data: Data, elapsed: Double, first: Bool) throws -> PlaybackSnapshot { try JSONDecoder().decode(PlaybackSnapshot.self, from: core.applyProjectSync(data, elapsed: elapsed, first: first)) }
    private let core: JarasCoreBridge
    private struct ClipWaveform {
        struct Storage: Hashable {
            struct Buffer: Hashable {
                let address: UInt
                let count: Int
                init(_ values: [Double]) {
                    address = values.withUnsafeBufferPointer { $0.isEmpty ? 0 : UInt(bitPattern: $0.baseAddress!) }
                    count = values.count
                }
            }
            let values: Buffer
            let channels: [Buffer]
        }
        let values: [Double]
        let channels: [[Double]]?
        init(_ clip: AudioClip) {
            values = clip.waveform
            channels = clip.waveformChannels.flatMap { $0.isEmpty ? nil : $0 }
        }
        var storage: Storage { Storage(values: .init(values), channels: (channels ?? []).map(Storage.Buffer.init)) }
        private static func sharesStorage(_ a: [Double], _ b: [Double]) -> Bool {
            guard a.count == b.count else { return false }
            guard !a.isEmpty else { return true }
            return a.withUnsafeBufferPointer { left in b.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress } }
        }
        func sharesStorage(with clip: AudioClip) -> Bool {
            guard Self.sharesStorage(values, clip.waveform) else { return false }
            let expected = channels ?? [], actual = clip.waveformChannels ?? []
            guard expected.count == actual.count else { return false }
            return zip(expected, actual).allSatisfy { Self.sharesStorage($0, $1) }
        }
    }
    // These immutable arrays share Swift's existing storage. Scalar edits never
    // box, serialize, decode or read the media waveform again.
    private var waveforms: [UUID: ClipWaveform] = [:]
    private let projectValidation = ProjectValidationCache()
    private struct TrackMetadataSnapshot: Decodable {
        var snapshot: ShowSnapshot
        let trackOrders: [String: [UUID]]
        let revision: UInt64
    }
    private var metadataRevision: UInt64 = 0
    private var snapshotTracks: [UUID: [UUID: Track]] = [:]
    init(core: JarasCoreBridge = JarasCoreBridge()) { self.core = core }
    private func cacheWaveforms(_ project: Project) {
        var next: [UUID: ClipWaveform] = [:]
        for song in project.songs { for track in song.tracks { for clip in track.clips { next[clip.id] = ClipWaveform(clip) } } }
        waveforms = next
    }
    func setTimecode(_ track: UUID, settings: TimecodeSettings) throws { try settings.validate(); try core.setTimecode(track.uuidString, data: JSONEncoder().encode(settings)) }
    func configureRegionSetlist(_ state: RegionSetlist) throws { try core.configureRegionSetlistData(JSONEncoder().encode(state)) }
    func setTrackRouting(_ routes: [UUID: TrackRouting]) throws { try core.setTrackRouting(JSONEncoder().encode(Dictionary(uniqueKeysWithValues: routes.map { ($0.key.uuidString, $0.value) }))) }
    func setOutputPatches(track: UUID?, patches: [OutputPatch]) throws { try core.setOutputPatches(track?.uuidString ?? "", data: JSONEncoder().encode(patches)) }
    func setOutputPatch(track: UUID?, patch: OutputPatch, slot: Int) throws { try core.setOutputPatch(track?.uuidString ?? "", first: Int32(patch.firstChannel), count: Int32(patch.channelCount), slot: Int32(slot)) }
    func groupTracks(_ ids: [UUID]) throws { try core.groupTracks(ids.map(\.uuidString)) }
    func reorderTrack(_ track: UUID, before: UUID?) throws { try core.reorderTrack(track.uuidString, before: before?.uuidString ?? "") }
    func addTrack(id: UUID, name: String, role: TrackRole) throws { try core.addTrack(id: id.uuidString, name: name, role: role.rawValue) }
    func resizeRegion(_ id: UUID, start: Double, end: Double) throws { try core.resizeRegion(id.uuidString, start: start, end: end) }
    func moveRegion(_ id: UUID, start: Double) throws { try core.moveRegion(id.uuidString, start: start) }
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws { try core.setFX(track?.uuidString ?? "", data: JSONEncoder().encode(settings)) }
    func setClipFX(_ clip: UUID, settings: NativeFXSettings) throws { try settings.validateForClip(); try core.setClipFX(clip.uuidString, data: JSONEncoder().encode(settings)) }
    func setClipFXBypass(_ clip: UUID, bypassed: Bool) throws { try core.setClipFXBypass(clip.uuidString, bypassed: bypassed) }
    func setClipName(_ clip: UUID, name: String) throws { try core.setClipName(clip.uuidString, name: name) }
    func setClipText(_ clip: UUID, text: String) throws { try core.setClipText(clip.uuidString, text: text) }
    func setMIDIInput(_ track: UUID, slot: Int) throws { try core.setMIDIInput(track.uuidString, slot: Int32(slot)) }
    func setMIDIChannel(_ track: UUID, channel: Int) throws { try core.setMIDIChannel(track.uuidString, channel: Int32(channel)) }
    func setInputMonitoring(_ track: UUID, enabled: Bool) throws { try core.setInputMonitoring(track.uuidString, enabled: enabled) }
    func setRecordingChannels(_ track: UUID, channel: Int) throws { try core.setRecordingChannels(track.uuidString, channel: Int32(channel)) }
    func setRecording(_ track: UUID, input: OutputPatch, format: String) throws { try core.setRecording(track.uuidString, first: Int32(input.firstChannel), count: Int32(input.channelCount), format: format) }
    func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws {
        var tracks: [Track] = []
        for entry in entries {
            var clip = entry.clip; clip.waveform = []; clip.waveformChannels = nil
            if let index = tracks.firstIndex(where: { $0.id == entry.track }) { tracks[index].clips.append(clip) }
            else { var track = Track(id: entry.track, name: "", role: .other); track.clips = [clip]; tracks.append(track) }
        }
        try core.pasteItems(JSONEncoder().encode(tracks), song: song.uuidString, moving: moving)
        for entry in entries { waveforms[entry.clip.id] = ClipWaveform(entry.clip) }
    }
    func insertAudioTracks(_ tracks: [Track], song: UUID) throws {
        try core.insertAudioTracks(JSONEncoder().encode(tracks), song: song.uuidString)
        for track in tracks { for clip in track.clips { waveforms[clip.id] = ClipWaveform(clip) } }
    }
    func replaceAudioClip(_ clip: AudioClip, track: UUID) throws { try core.replaceAudioClip(JSONEncoder().encode(clip), track: track.uuidString) }
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws {
        try core.addRecordedClip(JSONEncoder().encode(clip), track: track.uuidString)
        waveforms[clip.id] = ClipWaveform(clip)
    }
    func editMasterColor(_ color: UInt32) throws { try core.editMasterColor(color) }
    func editTrack(_ id: UUID, name: String, color: UInt32) throws { try core.editTrack(id.uuidString, name: name, color: color) }
    func setRegionInit(_ id: UUID, count: Int, bars: Bool) throws { try core.setRegionInit(id.uuidString, count: Int32(count), bars: bars) }
    func setRegionPitch(_ id: UUID, semitones: Int, tracks: [UUID], groups: [UUID]) throws { try core.setRegionPitch(id.uuidString, semitones: Int32(semitones), tracks: tracks.map(\.uuidString), groups: groups.map(\.uuidString)) }
    func editRegion(_ id: UUID, name: String, color: UInt32, uppercaseName: Bool) throws { try core.editRegion(id.uuidString, name: name, color: color, uppercaseName: uppercaseName) }
    func moveClip(_ id: UUID, start: Double, track: UUID?) throws { try core.moveClip(id.uuidString, start: start, track: track?.uuidString ?? "") }
    func deleteManualMarker(_ id: UUID) throws { try core.deleteManualMarker(id.uuidString) }
    func retimeTempoMarkers(_ markers: [TimelineMarker]) throws { try core.retimeTempoMarkers(JSONEncoder().encode(markers)) }
    func setTempoMarkers(_ markers: [TimelineMarker]) throws { try core.setTempoMarkers(JSONEncoder().encode(markers)) }
    func setTempoMarkers(_ markers: [TimelineMarker], removing: [UUID]) throws {
        try core.setTempoMarkers(JSONEncoder().encode(markers), removing: removing.map(\.uuidString))
    }
    func setMarker(_ marker: TimelineMarker) throws {
        if let bpm = marker.tempoBPM { try core.setTempoMarker(marker.id.uuidString, position: marker.position, bpm: bpm, beats: Int32(marker.tempoBeats ?? 4), unit: Int32(marker.tempoUnit ?? 4), timebase: (marker.tempoTimebase ?? .global).rawValue) }
        else if marker.isSection { try core.setSectionMarker(marker.id.uuidString, name: marker.name, position: marker.position, color: marker.color, loop: marker.isLoopSection) }
        else { try core.setMarker(marker.id.uuidString, name: marker.name, position: marker.position, color: marker.color) }
    }
    func setProjectTiming(bpm: Double, beats: Int, unit: Int, settings: ProjectTimeSettings) throws {
        try settings.validate()
        try core.setProjectTiming(bpm, beats: Int32(beats), unit: Int32(unit), settings: JSONEncoder().encode(settings))
    }
    func regionsFromClips(_ ids: [UUID]) throws { try core.regions(fromClips: ids.map(\.uuidString), identifiers: ids.map { _ in UUID().uuidString }) }
    func regionFromClip(_ id: UUID) throws { try core.region(fromClip: id.uuidString, identifier: UUID().uuidString) }
    func applyProjectEdit(_ project: Project) throws {
        try applyProjectEdit(project, previousTracks: nil)
    }
    func applyTrackStructureEdit(_ project: Project, previous: Project) throws {
        guard project.id == previous.id else { throw ProjectError.invalid("Cannot edit another project") }
        try applyProjectEdit(project, previousTracks: previous)
    }
    private func applyProjectEdit(_ project: Project, previousTracks: Project?) throws {
        var metadata = project
        var retained: [String] = []
        var waveformSources: [String: String] = [:]
        var sharedSources: [ClipWaveform.Storage: UUID] = [:]
        if let previousTracks {
            // A copied item still owns the original immutable arrays. Reuse
            // their native values without encoding thousands of sample peaks.
            for song in previousTracks.songs { for track in song.tracks { for clip in track.clips {
                if let waveform = waveforms[clip.id], waveform.sharesStorage(with: clip) {
                    sharedSources[waveform.storage] = clip.id
                }
            } } }
        }
        for song in metadata.songs.indices {
            for track in metadata.songs[song].tracks.indices {
                for item in metadata.songs[song].tracks[track].clips.indices {
                    let clip = metadata.songs[song].tracks[track].clips[item]
                    let source = waveforms[clip.id]?.sharesStorage(with: clip) == true
                        ? clip.id : sharedSources[ClipWaveform(clip).storage]
                    guard let source else { continue }
                    retained.append(clip.id.uuidString)
                    waveformSources[clip.id.uuidString] = source.uuidString
                    metadata.songs[song].tracks[track].clips[item].waveform = []
                    metadata.songs[song].tracks[track].clips[item].waveformChannels = nil
                }
            }
        }
        // Retained storage was validated when it entered the cache. Validate
        // changed/new arrays and every edited metadata field before committing.
        try projectValidation.validate(metadata)
        if let previousTracks {
            let previousSongs = Dictionary(uniqueKeysWithValues: previousTracks.songs.map { ($0.id, $0) })
            var orders: [String: [String]] = [:]
            var transmittedItems = Set<UUID>()
            for index in project.songs.indices {
                let song = project.songs[index]
                let oldTracks = Dictionary(uniqueKeysWithValues: (previousSongs[song.id]?.tracks ?? []).map { ($0.id, $0) })
                orders[song.id.uuidString] = song.tracks.map { $0.id.uuidString }
                let changed = Set(song.tracks.filter { oldTracks[$0.id] != $0 }.map(\.id))
                metadata.songs[index].tracks.removeAll { !changed.contains($0.id) }
                for track in metadata.songs[index].tracks { transmittedItems.formUnion(track.clips.map(\.id)) }
            }
            // Every omitted track remains owned by the engine. Adding a row
            // must not serialize all of the existing items and plugin states.
            let preserving = waveformSources.filter { UUID(uuidString: $0.key).map(transmittedItems.contains) == true }
            try core.applyTrackStructureEdit(JSONEncoder().encode(metadata), trackOrders: orders, preservingWaveforms: preserving)
        } else {
            try core.applyProjectMetadataEdit(JSONEncoder().encode(metadata), preservingWaveforms: retained)
        }
        cacheWaveforms(project)
    }
    func load(_ project: Project) throws {
        try projectValidation.validate(project)
        var metadata = project
        var buffers: [String: [Data]] = [:]
        var shared: [ClipWaveform.Storage: [Data]] = [:]
        for song in metadata.songs.indices {
            for track in metadata.songs[song].tracks.indices {
                for item in metadata.songs[song].tracks[track].clips.indices {
                    let clip = metadata.songs[song].tracks[track].clips[item]
                    let waveform = ClipWaveform(clip), storage = waveform.storage
                    let data: [Data]
                    if let cached = shared[storage] { data = cached }
                    else {
                        data = ([waveform.values] + (waveform.channels ?? [])).map { values in
                            values.withUnsafeBytes { Data($0) }
                        }
                        shared[storage] = data
                    }
                    buffers[clip.id.uuidString] = data
                    metadata.songs[song].tracks[track].clips[item].waveform = []
                    metadata.songs[song].tracks[track].clips[item].waveformChannels = nil
                }
            }
        }
        // Large projects can have millions of sample peaks. Transfer their
        // native Double bytes once; JSON carries only editable metadata. The
        // core still owns the exact peaks for split, copy and synchronization.
        try core.load(projectData: JSONEncoder().encode(metadata), waveforms: buffers)
        cacheWaveforms(project)
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { try core.execute(command: command.rawValue, target: target?.uuidString, value: value) }
    func snapshot() throws -> ShowSnapshot {
        do {
            let update = try JSONDecoder().decode(TrackMetadataSnapshot.self,
                from: core.trackMetadataSnapshot(previousRevision: metadataRevision))
            var snapshot = update.snapshot
            var next: [UUID: [UUID: Track]] = [:]
            for song in snapshot.project.songs.indices {
                let id = snapshot.project.songs[song].id
                guard let order = update.trackOrders[id.uuidString] else { throw ProjectError.invalid("Missing snapshot track order") }
                let changed = Dictionary(uniqueKeysWithValues: snapshot.project.songs[song].tracks.map { ($0.id, $0) })
                var tracks: [Track] = []; tracks.reserveCapacity(order.count)
                var retained: [UUID: Track] = [:]
                for trackID in order {
                    guard var track = changed[trackID] ?? snapshotTracks[id]?[trackID] else { throw ProjectError.invalid("Missing snapshot track") }
                    for item in track.clips.indices {
                        if track.kind.isTeleprompter, track.clips[item].isProjectionMedia { continue }
                        let waveform = waveforms[track.clips[item].id]
                        if waveform?.sharesStorage(with: track.clips[item]) != true ||
                            (waveform?.channels == nil) != (track.clips[item].waveformChannels == nil) {
                            track.clips[item].waveform = waveform?.values ?? []
                            track.clips[item].waveformChannels = waveform?.channels
                        }
                    }
                    retained[trackID] = track; tracks.append(track)
                }
                snapshot.project.songs[song].tracks = tracks
                next[id] = retained
            }
            snapshotTracks = next; metadataRevision = update.revision
            return snapshot
        } catch {
            // A failed read must not acknowledge a delta that Swift never
            // received. Revision zero requests every track on the next read.
            metadataRevision = 0; snapshotTracks.removeAll()
            throw error
        }
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { try JSONDecoder().decode(PlaybackSnapshot.self, from: core.playbackSnapshot()) }
    func advance(_ elapsed: Double) { core.advance(elapsed) }
    func finishCurrentSong(_ enabled: Bool) { core.finishCurrentSong(enabled) }
}
