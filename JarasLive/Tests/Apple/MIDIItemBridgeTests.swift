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
