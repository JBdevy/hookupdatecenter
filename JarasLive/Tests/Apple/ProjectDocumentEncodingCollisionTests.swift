import Foundation

struct Clip: Codable, Equatable {
    var name = "},\"waveform\":[0.25],\"songs\":[] \\\"\\\\"
    var waveform: [Double]
    var waveformChannels: [[Double]]?
}
struct Track: Codable, Equatable { var clips: [Clip] }
struct Song: Codable, Equatable { var tracks: [Track] }
struct Project: Codable, Equatable { var songs: [Song] }
enum FixtureCounters {
    static var maximumBytes = 0, maximumArrays = 0
    static func reset() { maximumBytes = 0; maximumArrays = 0 }
}
func project(_ values: [[Double]]) -> Project {
    Project(songs: [Song(tracks: []), Song(tracks: [Track(clips: []), Track(clips: values.map { Clip(waveform: $0, waveformChannels: [[], $0]) })])])
}
func verify(_ value: Project, _ encode: (Project) throws -> Data) throws {
    let encoded = try encode(value)
    let decoded = try JSONDecoder().decode(Project.self, from: encoded)
    precondition(decoded == value)
    for (left, right) in zip(value.songs.flatMap(\.tracks).flatMap(\.clips), decoded.songs.flatMap(\.tracks).flatMap(\.clips)) {
        precondition(left.waveform.map(\.bitPattern) == right.waveform.map(\.bitPattern))
        precondition(left.waveformChannels?.map { $0.map(\.bitPattern) } == right.waveformChannels?.map { $0.map(\.bitPattern) })
    }
}

// The script forces hash collisions and tiny cache limits in a copy of the
// actual encoder. Neither its collision handling nor output path is mocked.
try verify(project([[-0.0], [0.0], [0.125], [0.25], [-0.0], [0.0]]), ProjectDocumentJSON.encode)
precondition(FixtureCounters.maximumArrays == 2 && FixtureCounters.maximumBytes <= 128)
FixtureCounters.reset()
let large = (0..<1024).map { Double($0) / 1024 }
try verify(project([large, large]), ProjectDocumentJSON.encode)
precondition(FixtureCounters.maximumArrays <= 1 && FixtureCounters.maximumBytes <= 128,
             "an individual oversized waveform must bypass the cache without losing samples")
try verify(project([[0.125], large, [], [-0.0]]), ProjectDocumentJSONSchemaFallback.encode)
print("PROJECT_JSON_FORCED_HASH_COLLISIONS_EXACT_ZERO_BITS_CACHE_CAPS_AND_SCHEMA_FALLBACK_OK")
