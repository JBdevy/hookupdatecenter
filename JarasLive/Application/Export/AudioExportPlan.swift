import Foundation

public enum AudioExportFormat: String, CaseIterable, Sendable { case wav = "WAV", aiff = "AIFF", mp3 = "MP3"
    public var fileExtension: String { rawValue.lowercased() }
}
public struct AudioExportEncoding: Sendable {
    public var format: AudioExportFormat = .wav
    public var bitDepth = 24
    /// 0 preserves each exported item's source channel count; 1/2 force mono/stereo.
    public var channels = 2
    public var bitrate = 320
    public var sampleRate = 48000.0
    public init(format: AudioExportFormat = .wav, bitDepth: Int = 24, channels: Int = 2, bitrate: Int = 320, sampleRate: Double = 48000) {
        self.format = format; self.bitDepth = bitDepth; self.channels = channels; self.bitrate = bitrate; self.sampleRate = sampleRate
    }
}
public enum AudioExportSource: String, CaseIterable, Sendable { case master = "Master", tracks = "Tracks", masterAndTracks = "Master + Tracks", stems = "Stems" }
public enum AudioExportBounds: String, CaseIterable, Sendable { case project = "Complete project", area = "Selected area", regions = "Selected regions", allRegions = "All regions" }
public struct AudioExportJob: Identifiable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var start: Double
    public var end: Double
    public var track: UUID?
    public var clip: UUID?
    public var output = 0
    /// A drawer song starts a fresh musical entry; preceding overlapping stems
    /// are excluded, while exports of its parent retain the complete mix.
    public var minimumClipStart: Double? = nil
    public var duration: Double { end - start }
    public func includes(_ clip: AudioClip) -> Bool {
        minimumClipStart.map { clip.startTime >= $0 } ?? true
    }
}
public struct AudioExportPlan: Sendable {
    public var jobs: [AudioExportJob]
    public init(jobs: [AudioExportJob]) { self.jobs = jobs }
    /// Context export preserves every explicitly selected region, including a
    /// parent and its drawer songs. Playlist block IDs are not render targets.
    public static func contextRegions(clicked: UUID, selected: Set<UUID>, in song: Song) -> Set<UUID> {
        let valid = Set(song.parts.map(\.id))
        return (selected.contains(clicked) ? selected : [clicked]).intersection(valid)
    }
    public static func combining(primary: Self, secondary: Self) -> Self {
        var result = primary.jobs, names = Set(primary.jobs.map { $0.fileName.lowercased() })
        for var job in secondary.jobs {
            let base = (job.fileName as NSString).deletingPathExtension, ext = (job.fileName as NSString).pathExtension
            var suffix = 2
            while !names.insert(job.fileName.lowercased()).inserted { job.fileName = "\(base) (\(suffix)).\(ext)"; suffix += 1 }
            job.id = "secondary-" + job.id; job.output = 1
            result.append(job)
        }
        return Self(jobs: result)
    }
    public init(project: Project, song: Song, source: AudioExportSource, bounds: AudioExportBounds,
                template: String, tracks selectedTracks: Set<UUID>, clips selectedClips: Set<UUID>,
                regions selectedRegions: Set<UUID>, area: ClosedRange<Double>? = nil, format: AudioExportFormat = .wav) {
        var jobs: [AudioExportJob] = []
        var used = Set<String>()
        func append(track: Track?, clip: AudioClip?, region: Part?, start: Double, end: Double) {
            guard start.isFinite, end.isFinite, end > start else { return }
            // Replace only supported tokens; ordinary spaces and surrounding text survive.
            let tokens = ["%track": track?.name ?? "Master", "%stem": clip.map { ($0.name as NSString).deletingPathExtension } ?? track?.name ?? "Master",
                          "%region": region?.displayName ?? song.name, "%project": project.name]
            let expression = try! NSRegularExpression(pattern: "%track|%region|%stem|%project")
            let original = template as NSString
            var raw = template
            for match in expression.matches(in: template,range: NSRange(location: 0,length: original.length)).reversed() {
                if let range = Range(match.range,in: raw), let value = tokens[original.substring(with: match.range)] { raw.replaceSubrange(range,with: value) }
            }
            let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = project.name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "_")
            let base = cleaned.isEmpty ? (fallback.isEmpty ? "Export" : fallback) : cleaned
            let pathExtension = (base as NSString).pathExtension.lowercased()
            var stem = ["wav","aiff","aif","mp3"].contains(pathExtension) ? (base as NSString).deletingPathExtension : base
            if track == nil, source == .masterAndTracks, stem != "Master", !stem.hasSuffix(" Master") { stem += " Master" }
            // Leave room for a duplicate suffix within the filesystem byte limit.
            while stem.utf8.count > 220 { stem.removeLast() }
            var name = stem + "." + format.fileExtension, suffix = 2
            while !used.insert(name.lowercased()).inserted { name = "\(stem) (\(suffix))." + format.fileExtension; suffix += 1 }
            jobs.append(AudioExportJob(id: "\(jobs.count)", fileName: name, start: start, end: end, track: track?.id, clip: clip?.id,
                                       minimumClipStart: region?.parentRegionID == nil ? nil : region?.startTime))
        }
        if source == .stems {
            for track in song.tracks where track.kind == .standard {
                for clip in track.clips where selectedClips.contains(clip.id) && (clip.audioFile != nil || track.audioFile != nil) {
                    append(track: track, clip: clip, region: song.parts.first { clip.startTime >= $0.startTime && clip.startTime < $0.endTime }, start: clip.startTime, end: clip.startTime + clip.duration)
                }
            }
        } else {
            let ranges: [(Part?,Double,Double)]
            switch bounds {
            case .project: ranges = [(nil,0,song.completeAudioExportEnd)]
            case .area: ranges = area.map { [(nil,$0.lowerBound,$0.upperBound)] } ?? []
            case .regions: ranges = song.parts.filter { selectedRegions.contains($0.id) }.map { ($0,$0.startTime,$0.endTime) }
            case .allRegions: ranges = song.parts.filter { $0.parentRegionID == nil }.map { ($0,$0.startTime,$0.endTime) }
            }
            for (region,start,end) in ranges {
                if source != .tracks { append(track: nil,clip: nil,region: region,start: start,end: end) }
                if source != .master {
                    for track in song.tracks where track.kind == .standard && selectedTracks.contains(track.id) {
                        append(track: track,clip: nil,region: region,start: start,end: end)
                    }
                }
            }
        }
        self.jobs = jobs
    }
}
