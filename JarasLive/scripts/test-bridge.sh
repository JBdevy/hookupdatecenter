#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bridge-tests
cat > build/bridge-tests/main.swift <<'SWIFT'
import Foundation
var project = Project.demo()
project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Refrão", position: 12, color: 0xffcc00)]
project.songs[0].tracks[1].parentTrackID = project.songs[0].tracks[0].id
project.songs[0].tracks[1].patch = .masterGroup
project.songs[0].tracks[1].secondaryPatch = OutputPatch(firstChannel: 3, channelCount: 2)
project.masterSecondaryPatch = OutputPatch(firstChannel: 5, channelCount: 2)
project.songs[0].tracks[0].color = 0x20cc80
project.songs[0].tracks[0].midiInput = 3
project.songs[0].tracks[0].clips[0].waveformChannels = [[0.2, 0.3], [0.6, 0.7]]
project.songs[0].tracks[0].clips[0].muted = true
project.songs[0].tracks[0].clips[0].audioFile = AudioFile(path: "Steams/session/Click.wav")
project.songs[0].tracks[0].clips[0].fadeIn = 2
project.songs[0].tracks[0].clips[0].fadeOut = 3
project.songs[0].tracks[0].clips[0].gain = 1.25
project.songs[0].tracks[0].clips[0].playbackRate = 1.5
project.songs[0].tracks[0].clips[0].loopStart = 1
project.songs[0].tracks[0].clips[0].loopLength = 3
var itemFX = NativeFXSettings()
itemFX.inserted = ["EQ", "Reverb"]; itemFX.eqEnabled = true; itemFX.reverbEnabled = true
itemFX.bands[1].gain = 5; itemFX.reverbDecay = 7
project.songs[0].tracks[0].clips[0].fx = itemFX
let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 12)
let second = Part(id: UUID(), name: "Second", startTime: 20, endTime: 30)
project.songs[0].parts = [first, second]
let loopStart = TimelineMarker(id: UUID(), name: "Loop start", position: 3, color: 0xffffff)
let loopEnd = TimelineMarker(id: UUID(), name: "Loop end", position: 9, color: 0xffffff)
// Keep unresolved marker references here to verify lossless persistence after marker deletion.
var multiLoop = MultiLoop(name: "Verse loop", marker1: loopStart.id, marker2: loopEnd.id)
var loopTrack = MultiLoopTrack(id: project.songs[0].tracks[0].id, gain: 0.2)
loopTrack.autoFader = true; loopTrack.mute = true; loopTrack.solo = true
multiLoop.tracks = [loopTrack, MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0.5)]
project.songs[0].parts[0].multiLoops = [multiLoop]
project.songs[0].parts[0].pitchSemitones = 6
project.songs[0].parts[0].pitchTrackIDs = [project.songs[0].tracks[0].id]
project.songs[0].parts[0].pitchGroupIDs = []
project.songs[0].parts[1].pitchSemitones = -6
project.songs[0].parts[1].pitchTrackIDs = []
project.songs[0].parts[1].pitchGroupIDs = [project.songs[0].tracks[0].id]
project.songs[0].parts[0].uppercaseName = true
project.songs[0].parts[1].uppercaseName = false
let list = RegionPlaylist(id: UUID(), name: "Show order", songId: project.songs[0].id, regionIds: [second.id, first.id])
project.regionSetlist = RegionSetlist(playlists: [list], selectedId: list.id, autoAdvance: false)
let gridID = project.songs[0].id
project.regionSetlist?.blocks = [
    SetlistBlock(id: UUID(), songId: gridID, playlistId: list.id, name: "Bloco 01", color: 0x45c68b, beforeRegionId: second.id, symbol: false),
    SetlistBlock(id: UUID(), songId: gridID, name: "All regions block", color: 0xdda633, symbol: true)
]
// The bridge emits canonical timing defaults, including untouched clips.
for song in project.songs.indices {
    project.songs[song].beatsPerBar = project.songs[song].meterBeats
    project.songs[song].beatUnit = project.songs[song].meterUnit
    for track in project.songs[song].tracks.indices {
        for clip in project.songs[song].tracks[track].clips.indices {
            project.songs[song].tracks[track].clips[clip].playbackRate = project.songs[song].tracks[track].clips[clip].audioRate
        }
    }
}
let data = try JSONEncoder().encode(project)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swiftc Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift build/bridge-tests/main.swift -o build/bridge-tests/fixture
build/bridge-tests/fixture build/bridge-tests/demo.json
clang++ -std=c++17 -fobjc-arc -framework Foundation Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Apple/Bridge/JarasCoreBridge.mm Tests/Core/BridgeTests.mm -o build/bridge-tests/test
build/bridge-tests/test build/bridge-tests/demo.json
