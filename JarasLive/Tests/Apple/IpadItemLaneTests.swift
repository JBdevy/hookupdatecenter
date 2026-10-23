
let isolated = AudioClip(startTime: 0, duration: 5)
let first = AudioClip(startTime: 10, duration: 10)
let second = AudioClip(startTime: 15, duration: 10)
let adjacent = AudioClip(startTime: 25, duration: 5)
let track = Track(clips: [isolated, first, second, adjacent])
// Decode the real protocol to keep this fixture independent of optional fields.
let json = """
{"id":"\(UUID())","name":"Test","color":3355443,"volume":1,"pan":0,"mute":false,"solo":false,"clips":[],"laneCount":2}
"""
var remote = try JSONDecoder().decode(DAWRemoteState.Track.self, from: Data(json.utf8))
for scale in [0.35, 1, 3] {
    let geometry = IpadNativeItemGeometry(track: track, remoteTrack: remote, scale: scale)
    precondition(geometry.height(isolated.id) == geometry.rowHeight)
    precondition(geometry.height(adjacent.id) == geometry.rowHeight)
    precondition(geometry.offset(isolated.id) == 0 && geometry.offset(adjacent.id) == 0)
    precondition(geometry.height(first.id) == geometry.rowHeight / 2)
    precondition(geometry.height(second.id) == geometry.rowHeight / 2)
    precondition(geometry.offset(first.id) != geometry.offset(second.id))
    for clip in track.clips {
        precondition(geometry.offset(clip.id) + geometry.height(clip.id) <= geometry.rowHeight)
    }
}
remote.laneCount = 3
private let recording = IpadNativeItemGeometry(track: track, remoteTrack: remote, scale: 1)
precondition(recording.height(isolated.id) == recording.rowHeight / 3)
private let observer = IpadNativeItemGeometry(track: nil, remoteTrack: remote, scale: 1)
precondition(observer.offset(first.id, fallbackLane: 2) == observer.fallbackLaneHeight * 2)
print("IPAD_ITEM_LANES_ISOLATED_OVERLAPPING_ADJACENT_RECORDING_AND_REMOTE_OK")
