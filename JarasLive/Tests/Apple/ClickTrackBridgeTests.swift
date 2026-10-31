import Foundation
var project = Project.empty(name: "Click round trip")
var track = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
track.clickSound = AudioFile(path: "Stems/Click/custom.wav", sha256: "abc")
track.clips = [AudioClip(id: UUID(), name: "Click", startTime: 0, duration: 10)]
track.clips[0].clickDouble = true
project.songs[0].tracks = [track]
let core = JarasCoreBridge()
try core.load(projectData: JSONEncoder().encode(project))
try core.execute(command: "volume", target: track.id.uuidString, value: 0.5)
let snapshot = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(snapshot.project.songs[0].tracks[0].clickSound == track.clickSound)
precondition(snapshot.project.songs[0].tracks[0].volume == 0.5)
precondition(snapshot.project.songs[0].tracks[0].clips.first?.id == track.clips.first?.id)
precondition(snapshot.project.songs[0].tracks[0].clips[0].clickDouble == true)
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

let emptySlots: [OutputPatch] = [.master, .none, .none]
try core.setOutputPatches(track.id.uuidString, data: JSONEncoder().encode(emptySlots))
let withSlots = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(withSlots.project.songs[0].tracks[0].outputPatches == emptySlots, "Blank Patch rows must survive the engine bridge")
print("PATCH_EMPTY_OUTPUT_SLOTS_ROUND_TRIP_OK")

let parent = UUID(), child = UUID()
project.songs[0].duration = 20
project.songs[0].parts = [Part(id: parent, name: "Song", startTime: 0, endTime: 10),
                        Part(id: child, name: "Part", startTime: 2, endTime: 8, parentRegionID: parent)]
project.songs[0].tracks[0].clips[0].regionOwnerID = parent
try core.load(projectData: JSONEncoder().encode(project))
project.songs[0].tracks[0].clips[0].startTime = 3
project.songs[0].tracks[0].clips[0].duration = 3
var fragment = project.songs[0].tracks[0].clips[0]
fragment.id = UUID(); fragment.startTime = 6; fragment.duration = 4
project.songs[0].tracks[0].clips.append(fragment)
try core.applyProjectEdit(JSONEncoder().encode(project))
let split = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(split.project.songs[0].tracks[0].clips.allSatisfy { $0.regionOwnerID == parent && $0.clickDouble == true })
try core.load(projectData: JSONEncoder().encode(split.project))
let reloaded = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
precondition(reloaded.project.songs[0].tracks[0].clips.allSatisfy { $0.regionOwnerID == parent })
print("CLICK_SPLIT_TRIM_PARENT_OWNER_ROUND_TRIP_OK")

do {
    try core.moveClip(track.clips[0].id.uuidString, start: 4, track: track.id.uuidString)
    preconditionFailure("Generated Click must not move through the engine bridge")
} catch { }
print("CLICK_BRIDGE_MOVE_REJECTED_OK")
