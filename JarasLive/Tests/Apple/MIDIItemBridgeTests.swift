import Foundation
var project = Project.empty(name: "MIDI round trip")
var track = Track(id: UUID(), name: "MIDI", role: .keys)
let midi = MIDIItem(notes: [MIDINote(start: 0, length: 1.5, pitch: 60, velocity: 90),MIDINote(start: 2, length: 1, pitch: 67, channel: 3)], grid: MIDIGrid(division: 128, mode: .swing, swing: 0.6))
let clip = AudioClip(id: UUID(), name: "MIDI", startTime: 0, duration: 4, midi: midi)
track.clips = [clip]; project.songs[0].tracks = [track]
let core = JarasCoreBridge()
try core.load(projectData: JSONEncoder().encode(project))
try core.setRecordingChannels(track.id.uuidString, channel: 0)
try core.execute(command: "volume", target: track.id.uuidString, value: 0.5)
var snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(snapshot.project.songs[0].tracks[0].clips[0].midi == midi)
precondition(snapshot.project.songs[0].tracks[0].recordingMode == .midi)
try core.replaceAudioClip(JSONEncoder().encode(clip), track: track.id.uuidString)
snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(snapshot.project.songs[0].tracks[0].clips[0].midi == midi)
var second=clip;second.id=UUID();second.startTime=6
try core.addRecordedClip(JSONEncoder().encode(second), track: track.id.uuidString)
snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(snapshot.project.songs[0].tracks[0].clips.last?.midi == midi)
try core.load(projectData: JSONEncoder().encode(snapshot.project))
let reopened = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(reopened.project == snapshot.project)
print("MIDI_CORE_BRIDGE_LOAD_EDIT_REPLACE_INSERT_AND_SAVE_ROUND_TRIP_OK")

var frozen = clip
frozen.audioFile = AudioFile(path: "Stems/frozen.wav"); frozen.midi = nil; frozen.frozenMIDI = true; frozen.renderedTiming = true
frozen.playbackRate = 1; frozen.waveformChannels = []
try core.replaceAudioClip(JSONEncoder().encode(frozen), track: track.id.uuidString)
let frozenSnapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(frozenSnapshot.project.songs[0].tracks[0].clips[0] == frozen)
try core.load(projectData: JSONEncoder().encode(frozenSnapshot.project))
let frozenReopened = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(frozenReopened.project.songs[0].tracks[0].clips[0] == frozen)
var copied = frozen; copied.id = UUID(); copied.startTime = 12
var payload = track; payload.clips = [copied]
try core.pasteItems(JSONEncoder().encode([payload]), song: project.songs[0].id.uuidString, moving: false)
let pasted = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(pasted.project.songs[0].tracks[0].clips.first { $0.id == copied.id }?.frozenMIDI == true)
print("FROZEN_MIDI_CORE_BRIDGE_REPLACE_SAVE_REOPEN_AND_PASTE_FLAG_OK")

precondition(pasted.project.songs[0].tracks[0].clips.first { $0.id == copied.id }?.renderedTiming == true)
print("GLUED_AUDIO_TIMING_CORE_LOAD_REPLACE_COPY_ROUNDTRIP_OK")

// Capture probes and the native insertion path must retain the same owner map.
var captureProject = Project.empty(name: "Owned MIDI capture")
let captureGroup = Part(id: UUID(), name: "Unified", startTime: 0, endTime: 30)
let captureA = Part(id: UUID(), name: "A", startTime: 0, endTime: 10, parentRegionID: captureGroup.id)
let captureB = Part(id: UUID(), name: "B", startTime: 10, endTime: 30, parentRegionID: captureGroup.id)
let captureTrack = Track(id: UUID(), name: "MIDI", role: .keys)
captureProject.songs[0].parts = [captureA, captureB, captureGroup]
captureProject.songs[0].tracks = [captureTrack]
captureProject.songs[0].duration = 80
captureProject.songs[0].bpm = 120
captureProject.songs[0].regionOwnershipInitialized = true
captureProject.songs[0].timeSettings = ProjectTimeSettings()
captureProject.songs[0].timeSettings?.timebase = .relative
captureProject.songs[0].markers = [
    TimelineMarker(id: UUID(), name: "A", position: 0, color: 0, regionOwnerID: captureA.id, tempoBPM: 120, tempoReferenceBPM: 120),
    TimelineMarker(id: UUID(), name: "A internal", position: 6, color: 0, regionOwnerID: captureA.id, tempoBPM: 180, tempoReferenceBPM: 120),
    TimelineMarker(id: UUID(), name: "B", position: 10, color: 0, regionOwnerID: captureB.id, tempoBPM: 240, tempoReferenceBPM: 120)
]
try core.load(projectData: JSONEncoder().encode(captureProject))
var capturedTake = MIDIRecordingTake(track: captureTrack.id, song: captureProject.songs[0], startTime: 8)
capturedTake.receive(source: 1, status: 0x90, number: 60, value: 100, position: 9)
capturedTake.receive(source: 1, status: 0x91, number: 64, value: 90, position: 9.5)
capturedTake.receive(source: 1, status: 0x80, number: 60, value: 0, position: 13)
let capturedClip = capturedTake.finish(at: 33)!
precondition(capturedClip.regionOwnerID == captureA.id)
try core.addRecordedClip(JSONEncoder().encode(capturedClip), track: captureTrack.id.uuidString)
let capturedSnapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
let insertedCapture = capturedSnapshot.project.songs[0].tracks[0].clips[0]
precondition(insertedCapture.regionOwnerID == capturedClip.regionOwnerID)
precondition(insertedCapture.midi == capturedClip.midi)
precondition(insertedCapture.startTime == capturedClip.startTime && insertedCapture.duration == capturedClip.duration)
precondition(insertedCapture.sourceOffset == capturedClip.sourceOffset)
let capturedNotes = capturedSnapshot.project.songs[0].midiPlaybackNotes(in: insertedCapture)
precondition(capturedNotes.count == 2)
precondition(abs(capturedNotes[0].start - 9) < 1e-8 && abs(capturedNotes[0].end - 13) < 1e-8)
precondition(abs(capturedNotes[1].start - 9.5) < 1e-8 && abs(capturedNotes[1].end - 33) < 1e-8)
try core.load(projectData: JSONEncoder().encode(capturedSnapshot.project))
let capturedReopened = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(capturedReopened.project == capturedSnapshot.project)

var looseTake = MIDIRecordingTake(track: captureTrack.id, song: capturedReopened.project.songs[0], startTime: 41)
looseTake.receive(source: 1, status: 0x90, number: 67, value: 100, position: 42)
looseTake.receive(source: 1, status: 0x80, number: 67, value: 0, position: 44)
try core.moveRegion(captureGroup.id.uuidString, start: 40)
let looseCapture = looseTake.finish(at: 45)!
precondition(looseCapture.regionOwnerID == nil)
try core.addRecordedClip(JSONEncoder().encode(looseCapture), track: captureTrack.id.uuidString)
let looseSnapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
let insertedLoose = looseSnapshot.project.songs[0].tracks[0].clips.first { $0.id == looseCapture.id }!
precondition(insertedLoose.regionOwnerID == nil, "finalization cannot recapture MIDI after a region passes over its onset")
precondition(insertedLoose.midi == looseCapture.midi)
precondition(insertedLoose.startTime == looseCapture.startTime && insertedLoose.duration == looseCapture.duration)
try core.load(projectData: JSONEncoder().encode(looseSnapshot.project))
let looseReopened = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(looseReopened.project == looseSnapshot.project)
print("MIDI_CAPTURE_OWNED_TAIL_AND_FROZEN_LOOSE_NATIVE_INSERT_REOPEN_OK")
