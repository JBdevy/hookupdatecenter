import Foundation

public struct GrandMA2Settings: Codable, Equatable, Sendable {
    public var sequence = 1, page = 1, executor = 1, timecode = 1, slot = 2
    public init() {}
    public init(project: Project) {
        self.init()
        guard let raw = project.windowsLighting,
              let data = try? JSONEncoder().encode(raw),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["grandMA2"] as? [String: Int] else { return }
        sequence = settings["sequence"] ?? 1; page = settings["page"] ?? 1
        executor = settings["executor"] ?? 1; timecode = settings["timecode"] ?? 1; slot = settings["slot"] ?? 2
    }
    public func validate() throws {
        guard [sequence, page, executor, timecode].allSatisfy({ (1...9999).contains($0) }), (1...8).contains(slot) else {
            throw ProjectError.invalid("Sequence, page, executor and timecode must be 1–9999; MTC slot must be 1–8.")
        }
    }
}

/// Same persisted assignments and absolute MTC reservations as the Windows editor.
/// The receiver creates XML; the sender sends only a bounded lighting plan.
public struct GrandMA2Map: Sendable {
    public struct Cue: Codable, Equatable, Sendable { public var name: String; public var position: Double }
    public struct Region: Codable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var start: Double, end: Double
        public var offset: Int
        public var selected: Bool
        public var cues: [Cue]
    }
    public struct Plan: Codable, Sendable {
        public var name: String
        public var settings: GrandMA2Settings
        public var regions: [Region]
    }
    public var plan: Plan
    public var persisted: PortableProjectJSON
    public static func build(project: Project, settings: GrandMA2Settings, selected: Set<UUID>? = nil) throws -> Self {
        try settings.validate()
        var raw: [String: Any] = [:]
        if let value = project.windowsLighting {
            raw = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]) ?? [:]
        }
        var assignments: [String: Int] = [:], occupied = Set<Int>()
        for (key, value) in (raw["assignments"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let offset = (value as? Int) ?? (value as? String).flatMap(Int.init) ?? -1
            let canonical = key.hasPrefix("region:") ? UUID(uuidString: String(key.dropFirst(7))).map { "region:\($0.uuidString)" } ?? key : key
            if canonical.hasPrefix("region:"), assignments[canonical] == nil, (0..<9999).contains(offset), occupied.insert(offset).inserted { assignments[canonical] = offset }
        }
        var starts: [String: [String: Double]] = [:]
        if raw["committed"] as? Bool == true {
            for (key, value) in (raw["starts"] as? [String: [String: Double]] ?? [:]).sorted(by: { $0.key < $1.key }) {
                starts[UUID(uuidString: key)?.uuidString ?? key] = value
            }
        }
        var nextStart = starts.values.map { ($0["end"] ?? 0) + 60 }.max() ?? 0
        var nextOffset = (occupied.max() ?? -1) + 1
        let sources = ResolumeMap.build(project: project, settings: ResolumeSettings()).cues
        var regions: [Region] = []
        for song in project.songs {
            var base: Double = 0
            if let reservation = starts[song.id.uuidString] {
                base = reservation["start"] ?? 0
                guard song.duration <= (reservation["end"] ?? 0) - base else {
                    throw ProjectError.invalid("The song exceeds its reserved MTC space. Review the lighting map before extending it.")
                }
            } else if project.songs.count > 1 {
                base = ceil(nextStart)
                let end = base + ceil(song.duration / 60 + 1) * 60
                starts[song.id.uuidString] = ["start": base, "end": end]; nextStart = end + 60
            }
            let roots = sources.filter { $0.song == song.id && $0.isRegion }.sorted {
                $0.start == $1.start ? $0.region.uuidString < $1.region.uuidString : $0.start < $1.start
            }
            for region in roots {
                let key = "region:\(region.region.uuidString)"
                if assignments[key] == nil { assignments[key] = nextOffset; nextOffset += 1 }
                let offset = assignments[key]!
                guard offset < 9999, [settings.sequence, settings.executor, settings.timecode].allSatisfy({ $0 + offset <= 9999 }) else {
                    throw ProjectError.invalid("Starting numbers leave insufficient space for all songs.")
                }
                let cues = sources.filter { $0.region == region.region }.sorted {
                    $0.position == $1.position ? $0.key < $1.key : $0.position < $1.position
                }.map { Cue(name: $0.name, position: $0.position + base) }
                guard base.isFinite, base >= 0, region.start >= 0, region.end + base <= 86400 else {
                    throw ProjectError.invalid("The lighting map exceeds the 24-hour MTC limit.")
                }
                regions.append(Region(id: region.region, name: region.deckName, start: region.start + base,
                    end: region.end + base, offset: offset, selected: selected?.contains(region.region) ?? true, cues: cues))
            }
        }
        raw["committed"] = true; raw["assignments"] = assignments; raw["starts"] = starts
        raw["grandMA2"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        return Self(plan: Plan(name: LightingExportName.clean(project.name, fallback: "Projeto CatLive"), settings: settings, regions: regions),
                    persisted: try JSONDecoder().decode(PortableProjectJSON.self, from: JSONSerialization.data(withJSONObject: raw)))
    }
}
