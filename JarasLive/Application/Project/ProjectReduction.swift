import Foundation

public struct ProjectReductionTrack: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var sources: Set<UUID>
    public init(name: String, sources: Set<UUID>) { self.name = name; self.sources = sources }
}
public enum ProjectReduction {
    public struct Span: Equatable, Sendable { public var start: Double; public var end: Double }
    public static func sourceTracks(in project: Project) -> [Track] {
        let parents = Set(project.songs.flatMap(\.tracks).compactMap(\.parentTrackID))
        return project.songs.flatMap(\.tracks).filter { !parents.contains($0.id) }
    }
    public static func isAudio(_ clip: AudioClip, track: Track) -> Bool {
        guard clip.timecode == nil, clip.text == nil, !clip.isProjectionMedia else { return false }
        let ext = (((clip.audioFile ?? track.audioFile)?.path ?? "") as NSString).pathExtension.lowercased()
        guard !["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "mts", "m2ts"].contains(ext) else { return false }
        return clip.midi != nil || clip.audioFile != nil || track.audioFile != nil
    }
    /// Positive overlap joins vertically. Touching ends and gaps stay separate.
    public static func spans(_ tracks: [Track]) -> [Span] {
        let clips = tracks.flatMap { track in track.clips.filter { isAudio($0, track: track) } }
            .sorted { $0.startTime < $1.startTime }
        var result: [Span] = []
        for clip in clips where clip.duration > 0 {
            let end = clip.startTime + clip.duration
            if let last = result.last, clip.startTime < last.end - 0.000001 {
                result[result.count - 1].end = max(last.end, end)
            } else { result.append(Span(start: clip.startTime, end: end)) }
        }
        return result
    }
    /// Files and adjacent items must share the same discrete sample clock.
    /// Floating point edge residue may otherwise produce a zero-frame file.
    public static func sampleAligned(_ spans: [Span], sampleRate: Double = 48000) -> [Span] {
        spans.compactMap { span in
            let start = (span.start * sampleRate).rounded(), end = (span.end * sampleRate).rounded()
            guard start.isFinite, end.isFinite, end > start else { return nil }
            return Span(start: start / sampleRate, end: end / sampleRate)
        }
    }
    /// Region boundaries partition the timeline: overlapping/unified regions
    /// must never render the same samples twice. Uncovered audio is retained.
    public static func spans(_ tracks: [Track], in song: Song) -> [Span] {
        let audio = spans(tracks)
        guard !audio.isEmpty else { return [] }
        let parents = Set(song.parts.compactMap(\.parentRegionID))
        let regions = song.parts.filter { !parents.contains($0.id) && $0.endTime > $0.startTime }
        guard !regions.isEmpty else { return audio }
        let bounds = Array(Set(regions.flatMap { [$0.startTime, $0.endTime] } + [audio[0].start, audio.last!.end])).sorted()
        var result: [Span] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where end > start {
            let covered = audio.filter { $0.start < end && $0.end > start }
            guard !covered.isEmpty else { continue }
            if regions.contains(where: { $0.startTime < end && $0.endTime > start }) {
                result.append(Span(start: start, end: end))
            } else {
                result += covered.map { Span(start: max(start, $0.start), end: min(end, $0.end)) }
            }
        }
        return result
    }
    public struct SizeEstimate: Sendable {
        public var frames: Double = 0
        public var files = 0
        public var copiedBytes: Double = 0
        public var documentBytes: Double = 0
        public func bytes(for format: AudioExportFormat) -> Double {
            // MP3 is CBR 320 kbps. Allow for encoder delay, tags and file headers.
            let audio = format == .mp3 ? frames / 48000 * 40000 : frames * 8
            return audio + Double(files) * 8192 + copiedBytes + documentBytes
        }
    }
    public static func estimate(_ groups: [ProjectReductionTrack], project: Project,
                                fileSize: (String) -> Double) -> SizeEstimate {
        var estimate = SizeEstimate()
        var retained = project
        for i in retained.songs.indices { retained.songs[i].tracks = [] }
        for group in groups {
            guard let si = project.songs.firstIndex(where: { !group.sources.isDisjoint(with: $0.tracks.map(\.id)) }) else { continue }
            let song = project.songs[si], sources = song.tracks.filter { group.sources.contains($0.id) }
            let ranges = sampleAligned(spans(sources, in: song))
            if sources.count == 1 && (sources[0].parentTrackID == nil || ranges.isEmpty) {
                retained.songs[si].tracks.append(sources[0])
            } else {
                estimate.frames += ranges.reduce(0) { $0 + (($1.end - $1.start) * 48000).rounded() }
                estimate.files += ranges.count
                var output = Track(id: group.id, name: group.name, role: .other)
                output.clips = sources.flatMap { source in
                    source.clips.filter { !isAudio($0, track: source) }.map { original in
                        var clip = original
                        if clip.audioFile == nil { clip.audioFile = source.audioFile }
                        return clip
                    }
                }
                retained.songs[si].tracks.append(output)
            }
        }
        // Shared references are copied once, including samples used by retained FX.
        estimate.copiedBytes = retained.mediaPaths.reduce(0) { $0 + max(0, fileSize($1)) }
        estimate.documentBytes = Double((try? JSONEncoder().encode(retained).count) ?? 0) + Double(estimate.files) * 2048
        return estimate
    }
    /// Group processing is already printed by the writer. Keep only the
    /// destination lanes, detached from every original folder.
    public static func retain(_ ids: Set<UUID>, in project: inout Project) {
        for si in project.songs.indices {
            project.songs[si].tracks = project.songs[si].tracks.filter { ids.contains($0.id) }.map { source in
                var track = source
                track.parentTrackID = nil
                track.outputs = track.outputs?.map { $0 == .masterGroup ? .master : $0 }
                if track.patch == .masterGroup { track.patch = .master }
                if track.secondaryPatch == .masterGroup { track.secondaryPatch = .master }
                if let partner = track.stereoLink?.partner, !ids.contains(partner) { track.stereoLink = nil }
                if var routing = track.routing {
                    routing.receives = routing.receives.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
                    routing.transmitters = routing.transmitters.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
                    track.routing = routing
                }
                return track
            }
        }
    }
    public static func validate(_ groups: [ProjectReductionTrack], project: Project) throws {
        guard !groups.isEmpty else { throw ProjectError.invalid("Create at least one destination track.") }
        let eligible = Set(sourceTracks(in: project).map(\.id)); var used = Set<UUID>()
        for group in groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !group.sources.isEmpty,
                  group.sources.isSubset(of: eligible), used.isDisjoint(with: group.sources) else {
                throw ProjectError.invalid("Choose a name and source tracks. Each source can belong to only one destination.")
            }
            guard project.songs.filter({ !group.sources.isDisjoint(with: $0.tracks.map(\.id)) }).count == 1 else {
                throw ProjectError.invalid("Choose source tracks from the same arrangement.")
            }
            used.formUnion(group.sources)
        }
    }
}
