import Foundation
var project = Project.empty(name: "Click round trip")
var track = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
track.clickSound = AudioFile(path: "Stems/Click/custom.wav", sha256: "abc")
track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 10)]
project.songs[0].tracks = [track]
let core = JarasCoreBridge()
try core.load(projectData: JSONEncoder().encode(project))
try core.execute(command: "volume", target: track.id.uuidString, value: 0.5)
let snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(snapshot.project.songs[0].tracks[0].clickSound == track.clickSound)
precondition(snapshot.project.songs[0].tracks[0].volume == 0.5)
precondition(snapshot.project.songs[0].tracks[0].clips.first?.id == track.clips.first?.id)
print("CLICK_BRIDGE_CUSTOM_SOUND_AND_CONTROLS_ROUND_TRIP_OK")

// The native engine must retain the visual identity through controls, edits and save/load.
for icon in ["keyboard", "piano", "synthesizer", "electricGuitar", "acousticGuitar", "cello",
             "microphone", "backingVocals", "bass", "drums", "conga", "bongo", "surdo", "accordion", "organ", "cowbell", "jamblock", "futureInstrument"] {
    project.songs[0].tracks[0].instrumentIcon = icon
    try core.applyProjectEdit(JSONEncoder().encode(project))
    try core.execute(command: "volume", target: track.id.uuidString, value: 0.6)
    let updated = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
    precondition(updated.project.songs[0].tracks[0].instrumentIcon == icon)
    try core.load(projectData: JSONEncoder().encode(updated.project))
    let reopened = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
    precondition(reopened.project.songs[0].tracks[0].instrumentIcon == icon)
}
project.songs[0].tracks[0].instrumentIcon = nil
try core.applyProjectEdit(JSONEncoder().encode(project))
let cleared = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(cleared.project.songs[0].tracks[0].instrumentIcon == nil)
print("TRACK_ICONS_NATIVE_BRIDGE_EDIT_CLEAR_ROUND_TRIP_OK")
