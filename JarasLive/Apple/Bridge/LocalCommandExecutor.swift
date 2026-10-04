import Foundation
@MainActor final class LocalCommandExecutor: CommandExecutor {
    private let core: JarasCoreBridge
    private struct ClipWaveform {
        let values: [Double]
        let channels: [[Double]]?
        init(_ clip: AudioClip) {
            values = clip.waveform
            channels = clip.waveformChannels.flatMap { $0.isEmpty ? nil : $0 }
        }
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
    func setClipText(_ clip: UUID, text: String) throws { try AudioClip.validateText(text); try core.setClipText(clip.uuidString, text: text) }
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
        var metadata = project
        var retained: [String] = []
        for song in metadata.songs.indices {
            for track in metadata.songs[song].tracks.indices {
                for item in metadata.songs[song].tracks[track].clips.indices {
                    let clip = metadata.songs[song].tracks[track].clips[item]
                    guard waveforms[clip.id]?.sharesStorage(with: clip) == true else { continue }
                    retained.append(clip.id.uuidString)
                    metadata.songs[song].tracks[track].clips[item].waveform = []
                    metadata.songs[song].tracks[track].clips[item].waveformChannels = nil
                }
            }
        }
        // Retained storage was validated when it entered the cache. Validate
        // changed/new arrays and every edited metadata field before committing.
        try metadata.validate()
        try core.applyProjectMetadataEdit(JSONEncoder().encode(metadata), preservingWaveforms: retained)
        cacheWaveforms(project)
    }
    func load(_ project: Project) throws { try project.validate(); try core.load(projectData: JSONEncoder().encode(project)); cacheWaveforms(project) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { try core.execute(command: command.rawValue, target: target?.uuidString, value: value) }
    func snapshot() throws -> ShowSnapshot {
        var snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices {
                for item in snapshot.project.songs[song].tracks[track].clips.indices {
                    let id = snapshot.project.songs[song].tracks[track].clips[item].id
                    if snapshot.project.songs[song].tracks[track].kind.isTeleprompter,
                       snapshot.project.songs[song].tracks[track].clips[item].isProjectionMedia { continue }
                    snapshot.project.songs[song].tracks[track].clips[item].waveform = waveforms[id]?.values ?? []
                    snapshot.project.songs[song].tracks[track].clips[item].waveformChannels = waveforms[id]?.channels
                }
            }
        }
        return snapshot
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { try JSONDecoder().decode(PlaybackSnapshot.self, from: core.playbackSnapshot()) }
    func advance(_ elapsed: Double) { core.advance(elapsed) }
    func finishCurrentSong(_ enabled: Bool) { core.finishCurrentSong(enabled) }
}
