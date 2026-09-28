import Foundation
public enum ShowCommand: String, Sendable { case ignoreNext, tempo, beatsPerBar, beatUnit, clipGain, clipMute, selectRegion, queueRegion, play, pause, stop, next, previous, queue, select, toggleLoop, seek, editSeek, subPlay, subStop, subSeek, stopAll, volume, pan, mute, solo }
@MainActor public protocol CommandExecutor {
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws
    func configureRegionSetlist(_ state: RegionSetlist) throws
    func setTrackRouting(_ routes: [UUID: TrackRouting]) throws
    func setOutputPatches(track: UUID?, patches: [OutputPatch]) throws
    func setOutputPatch(track: UUID?, patch: OutputPatch, slot: Int) throws
    func groupTracks(_ ids: [UUID]) throws
    func reorderTrack(_ track: UUID, before: UUID?) throws
    func addTrack(id: UUID, name: String, role: TrackRole) throws
    func resizeRegion(_ id: UUID, start: Double, end: Double) throws
    func moveRegion(_ id: UUID, start: Double) throws
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws
    func setClipFX(_ clip: UUID, settings: NativeFXSettings) throws
    func setClipFXBypass(_ clip: UUID, bypassed: Bool) throws
    func setClipText(_ clip: UUID, text: String) throws
    func setMIDIInput(_ track: UUID, slot: Int) throws
    func setRecording(_ track: UUID, input: OutputPatch, format: String) throws
    func setTimecode(_ track: UUID, settings: TimecodeSettings) throws
    func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws
    func insertAudioTracks(_ tracks: [Track], song: UUID) throws
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws
    func editTrack(_ id: UUID, name: String, color: UInt32) throws
    func setRegionPitch(_ id: UUID, semitones: Int, tracks: [UUID], groups: [UUID]) throws
    func editRegion(_ id: UUID, name: String, color: UInt32, uppercaseName: Bool) throws
    func moveClip(_ id: UUID, start: Double, track: UUID?) throws
    func regionFromClip(_ id: UUID) throws
    func regionsFromClips(_ ids: [UUID]) throws
    func setMarker(_ marker: TimelineMarker) throws
    func deleteManualMarker(_ id: UUID) throws
    func applyProjectEdit(_ project: Project) throws
    func load(_ project: Project) throws
    func snapshot() throws -> ShowSnapshot
    func playbackSnapshot() throws -> PlaybackSnapshot
    func advance(_ elapsed: Double)
    func finishCurrentSong(_ enabled: Bool)
}
@MainActor public final class RemoteCommandExecutor: CommandExecutor {
    public init() {}
    public func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { throw BackendFailure.notConfigured }
    public func addTrack(id: UUID, name: String, role: TrackRole) throws { throw BackendFailure.notConfigured }
    public func load(_ project: Project) throws { throw BackendFailure.notConfigured }
    public func snapshot() throws -> ShowSnapshot { throw BackendFailure.notConfigured }
    public func playbackSnapshot() throws -> PlaybackSnapshot { throw BackendFailure.notConfigured }
    public func advance(_ elapsed: Double) {}
    public func finishCurrentSong(_ enabled: Bool) {}
}

public extension CommandExecutor {
    func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws { throw BackendFailure.notConfigured }
    func applyProjectEdit(_ project: Project) throws { throw BackendFailure.notConfigured }
    func setTimecode(_ track: UUID, settings: TimecodeSettings) throws { throw BackendFailure.notConfigured }
    func groupTracks(_ ids: [UUID]) throws { throw BackendFailure.notConfigured }
    func setMarker(_ marker: TimelineMarker) throws { throw BackendFailure.notConfigured }
    func deleteManualMarker(_ id: UUID) throws { throw BackendFailure.notConfigured }
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws { throw BackendFailure.notConfigured }
    func setClipFX(_ clip: UUID, settings: NativeFXSettings) throws { throw BackendFailure.notConfigured }
    func setClipFXBypass(_ clip: UUID, bypassed: Bool) throws { throw BackendFailure.notConfigured }
    func setClipText(_ clip: UUID, text: String) throws { throw BackendFailure.notConfigured }
    func setMIDIInput(_ track: UUID, slot: Int) throws { throw BackendFailure.notConfigured }
    func setRecording(_ track: UUID, input: OutputPatch, format: String) throws { throw BackendFailure.notConfigured }
    func insertAudioTracks(_ tracks: [Track], song: UUID) throws { throw BackendFailure.notConfigured }
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws { throw BackendFailure.notConfigured }
    func editTrack(_ id: UUID, name: String, color: UInt32) throws { throw BackendFailure.notConfigured }
    func setTrackRouting(_ routes: [UUID: TrackRouting]) throws { throw BackendFailure.notConfigured }
    func setOutputPatches(track: UUID?, patches: [OutputPatch]) throws { throw BackendFailure.notConfigured }
    func setOutputPatch(track: UUID?, patch: OutputPatch, slot: Int) throws { throw BackendFailure.notConfigured }
    func reorderTrack(_ track: UUID, before: UUID?) throws { throw BackendFailure.notConfigured }
    func configureRegionSetlist(_ state: RegionSetlist) throws { throw BackendFailure.notConfigured }
    func resizeRegion(_ id: UUID, start: Double, end: Double) throws { throw BackendFailure.notConfigured }
    func moveRegion(_ id: UUID, start: Double) throws { throw BackendFailure.notConfigured }
    func setRegionPitch(_ id: UUID, semitones: Int, tracks: [UUID], groups: [UUID]) throws { throw BackendFailure.notConfigured }
    func editRegion(_ id: UUID, name: String, color: UInt32, uppercaseName: Bool) throws { throw BackendFailure.notConfigured }
    func moveClip(_ id: UUID, start: Double, track: UUID?) throws { throw BackendFailure.notConfigured }
    func regionFromClip(_ id: UUID) throws { throw BackendFailure.notConfigured }
    func regionsFromClips(_ ids: [UUID]) throws { throw BackendFailure.notConfigured }
}
