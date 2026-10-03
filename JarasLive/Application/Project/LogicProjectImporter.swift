import Foundation
#if os(macOS)
import AppKit

/// Read-only migration of Logic's arrangement. Audio references remain real
/// references when offline, so the normal CatLive recovery UI can reconnect them.
public enum LogicProjectImporter {
    public typealias Result = ProjectMigration.Result
    public typealias Media = ProjectMigration.Media
    private struct Record {
        let tag: String, version: Int, kind: Int, owner: Int, index: Int
        let body: Bytes
    }
    private struct Bytes {
        let data: Data
        var count: Int { data.count }
        func integer(_ offset: Int, _ width: Int = 4) throws -> UInt64 {
            guard offset >= 0, width > 0, width <= 8, offset <= count - width else { throw invalid("Truncated Logic data.") }
            return (0..<width).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func int(_ offset: Int, _ width: Int = 4) throws -> Int { Int(try integer(offset, width)) }
        func slice(_ offset: Int, _ length: Int) throws -> Bytes {
            guard offset >= 0, length >= 0, offset <= count - length else { throw invalid("Truncated Logic data.") }
            return Bytes(data: data.subdata(in: offset..<(offset + length)))
        }
        func text(_ offset: Int, utf16: Bool = false) throws -> String {
            let length = try int(offset, 2)
            let bytes = try slice(offset + 2, length * (utf16 ? 2 : 1)).data
            guard let value = String(data: bytes, encoding: utf16 ? .utf16LittleEndian : .utf8)
                ?? String(data: bytes, encoding: .macOSRoman) else { throw invalid("Invalid Logic name.") }
            return value.trimmingCharacters(in: .controlCharacters)
        }
    }
    private struct MixerSettings {
        let volume: Double
        let pan: Double
        let mute: Bool
    }
    private struct Tempo { var tick: Double; var bpm: Double }
    private struct FileReference { let name: String; let rate: Double; let source: URL? }
    private struct NoteEvent {
        let tick: Double, length: Double
        let pitch: Int, velocity: Int, channel: Int
    }
    private static func invalid(_ detail: String) -> ProjectError { .invalid("Logic: " + detail) }

    public static func read(_ bundle: URL) throws -> Result {
        let fm = FileManager.default
        guard bundle.pathExtension.lowercased() == "logicx" else { throw invalid("Select a .logicx project.") }
        let alternatives = bundle.appendingPathComponent("Alternatives")
        let information = (try? plist(bundle.appendingPathComponent("Resources/ProjectInformation.plist"))) ?? [:]
        let available = try fm.contentsOfDirectory(at: alternatives, includingPropertiesForKeys: nil)
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("ProjectData").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let selected: URL?
        if let value = information["ActiveVariant"] as? NSNumber {
            selected = available.first { Int($0.lastPathComponent) == value.intValue }
        } else if let value = information["ActiveVariant"] as? String {
            selected = available.first { $0.lastPathComponent == value || Int($0.lastPathComponent) == Int(value) }
        } else { selected = nil }
        guard let alternative = selected ?? available.first else { throw invalid("No project alternative was found.") }
        let metadata = try plist(alternative.appendingPathComponent("MetaData.plist"))
        let url = alternative.appendingPathComponent("ProjectData")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 24, size <= 512 * 1024 * 1024 else { throw invalid("Invalid project data size.") }
        let records = try parse(Data(contentsOf: url, options: .mappedIfSafe))
        let name = bundle.deletingPathExtension().lastPathComponent
        var project = Project.empty(name: name)
        project.importedTimeline = true
        var song = project.songs[0]
        song.name = name; song.tracks = []; song.parts = []; song.markers = []; song.timeSettings = .legacy
        let rate = (metadata["SampleRate"] as? NSNumber)?.doubleValue ?? 44100
        let defaultBPM = (metadata["BeatsPerMinute"] as? NSNumber)?.doubleValue ?? 120
        guard (8000...768000).contains(rate), (1...1000).contains(defaultBPM) else { throw invalid("Invalid sample rate or tempo.") }
        song.bpm = defaultBPM
        song.beatsPerBar = (metadata["SongSignatureNumerator"] as? NSNumber)?.intValue ?? 4
        song.beatUnit = (metadata["SongSignatureDenominator"] as? NSNumber)?.intValue ?? 4
        var tempos: [Tempo] = []
        var markerNames: [Int: String] = [:]
        for record in records {
            if record.tag == "qSxT", let rtf = record.body.data.range(of: Data("{\\rtf".utf8)) {
                let content = record.body.data.subdata(in: rtf.lowerBound..<record.body.count)
                // RTF conversion only touches the embedded marker text.
                if let string = try? NSAttributedString(data: content, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string {
                    markerNames[record.owner >> 16] = string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if record.tag == "qSvE", record.kind == 3 {
                for event in try events(record.body) where event.data.first == 0x60 {
                    let bpm = Double(try event.int(16)) / 10000
                    guard (1...1000).contains(bpm) else { throw invalid("Unsupported tempo event.") }
                    tempos.append(Tempo(tick: Double(try event.int(4)) - 38400, bpm: bpm))
                }
            }
        }
        tempos.sort { $0.tick < $1.tick }
        if tempos.isEmpty { tempos = [Tempo(tick: 0, bpm: defaultBPM)] }
        if tempos[0].tick > 0 { tempos.insert(Tempo(tick: 0, bpm: defaultBPM), at: 0) }
        func seconds(_ tick: Double) -> Double {
            if tick < 0 { return tick / 960 * 60 / tempos[0].bpm }
            var time = 0.0, previous = 0.0
            var bpm = tempos.last(where: { $0.tick <= 0 })?.bpm ?? defaultBPM
            for point in tempos where point.tick > 0 && point.tick < tick {
                time += (point.tick - previous) / 960 * 60 / bpm
                previous = point.tick; bpm = point.bpm
            }
            return time + (tick - previous) / 960 * 60 / bpm
        }
        song.bpm = tempos.last(where: { $0.tick <= 0 })?.bpm ?? defaultBPM
        let beats = song.meterBeats, unit = song.meterUnit
        for point in tempos where point.tick >= 0 {
            song.markers?.append(TimelineMarker(id: UUID(), name: String(format: "%g", point.bpm), position: seconds(point.tick), color: 0xAAAAAA,
                tempoBPM: point.bpm, tempoBeats: beats, tempoUnit: unit, tempoTimebase: .free))
        }
        var files: [Int: FileReference] = [:]
        var regions: [String: Bytes] = [:]
        var environments: [Int: String] = [:]
        var channelIdentifiers: [Int: Data] = [:]
        var mixers: [Data: MixerSettings] = [:]
        var sequences: [Int: String] = [:]
        var sequenceRecords: [Int: Record] = [:]
        let mediaFolder = "Stems/Logic-" + UUID().uuidString
        for record in records {
            switch record.tag {
            case "lFuA":
                let filename = try record.body.text(8, utf16: true)
                guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
                    throw invalid("Invalid audio filename.")
                }
                var fileRate = rate
                if let format = record.body.data.range(of: Data("EVAW".utf8)), format.lowerBound + 24 <= record.body.count {
                    let storedRate = Double(try record.body.int(format.lowerBound + 20))
                    if (8000...768000).contains(storedRate) { fileRate = storedRate }
                }
                let candidates = [bundle.appendingPathComponent("Media/Audio Files").appendingPathComponent(filename),
                                  bundle.appendingPathComponent("Audio Files").appendingPathComponent(filename),
                                  bundle.deletingLastPathComponent().appendingPathComponent("Audio Files").appendingPathComponent(filename)]
                let source = candidates.first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                files[record.owner >> 16] = FileReference(name: filename, rate: fileRate, source: source)
            case "gRuA": regions["\(record.owner >> 16):\(record.index)"] = record.body
            case "ivnE":
                if record.body.count >= 160 {
                    environments[record.owner] = try record.body.text(158)
                    // Audio/instrument channel records end with their persistent
                    // UUID; the preceding name is variable-length (UTF-8 bytes).
                    let nameLength = try record.body.int(158, 2)
                    if record.version == 12, record.body.count == 463 + ((nameLength + 1) & ~1) {
                        channelIdentifiers[record.owner] = try record.body.slice(record.body.count - 16, 16).data
                    }
                }
            case "OCuA":
                // Inactive short records contain no channel strip. The UUID
                // follows a variable-size table, so row order is not a link.
                if record.version == 7, record.body.count >= 169 {
                    let identifierOffset = 153 + 4 * (try record.body.int(26, 2))
                    let identifier = try record.body.slice(identifierOffset, 16).data
                    if identifier.contains(where: { $0 != 0 }) {
                        let position = Double(try record.body.integer(116)) / 16_777_216
                        let pan = try record.body.int(89, 1)
                        let mute = try record.body.int(90, 1)
                        guard position <= 127, pan <= 127, mute <= 1 else { throw invalid("Invalid mixer channel controls.") }
                        // Logic persists its fader as unsigned 8.24 position:
                        // 90 = unity, with squared amplitude below/above it.
                        // Preserve fractional precision rather than the coarse
                        // MIDI byte (body +85) or an IEEE float interpretation.
                        let volume = pow(position / 90, 2)
                        let balance = Double(pan - 64) / (pan < 64 ? 64 : 63)
                        guard mixers[identifier] == nil else { throw invalid("Duplicate mixer channel identifier.") }
                        mixers[identifier] = MixerSettings(volume: volume, pan: balance, mute: mute == 1)
                    }
                }
            case "qeSM":
                if record.kind == 23 {
                    sequences[record.owner] = try record.body.text(record.version >= 5 ? 16 : 52)
                    sequenceRecords[record.owner] = record
                }
            default: break
            }
        }
        // The arrangement is a sequence with an ordered row list. Automation,
        // trash and the media bin have other owners and must never be imported.
        let rowRecords = records.filter { $0.tag == "karT" && $0.kind == 23 && $0.body.count >= 57 }
        let candidates = Set(rowRecords.map(\.owner)).filter { owner in
            guard let title = sequences[owner] else { return false }
            return !["TRASH", "Track Automation Root Folder", "Track Alternatives", "Global Harmonies"].contains(title) && !title.hasPrefix("*Automation")
        }
        let root = candidates.contains(0x40000) ? 0x40000 : candidates.sorted().first
        guard let root else { throw invalid("The arrangement track list is not supported.") }
        let rows = rowRecords.filter { $0.owner == root }.sorted { $0.index < $1.index }
        var trackIndices: [Int: Int] = [:]
        var group: UUID?
        var nestedGroups = false
        var missingMixerSettings = false
        for row in rows {
            let rowKind = try row.body.int(0, 1)
            guard rowKind != 3 else { continue } // Logic's output strip is not an audio track.
            guard rowKind == 1 else { throw invalid("Unsupported arrangement track kind.") }
            let depth = try row.body.int(14, 2)
            let channel = try row.body.int(6)
            let title = environments[channel] ?? "Track \(row.index + 1)"
            var track = Track(id: UUID(), name: title, role: .other, color: Track.defaultStandardColor)
            if let identifier = channelIdentifiers[channel], let settings = mixers[identifier] {
                track.volume = settings.volume; track.pan = settings.pan; track.mute = settings.mute
            } else { missingMixerSettings = true }
            if depth > 0 {
                guard let group else { throw invalid("Invalid track group.") }
                track.parentTrackID = group
                if depth > 1 { nestedGroups = true }
            } else { group = track.id }
            trackIndices[row.index + 1] = song.tracks.count
            song.tracks.append(track)
        }
        guard !song.tracks.isEmpty else { throw invalid("No arrangement tracks were found.") }
        var media: [String: Media] = [:]
        var midiItems = 0, extendedItems = 0
        var unsupportedMIDIEvents = false
        var trimmedMIDINotes = false
        let sequenceEvents = Dictionary(grouping: records.filter { $0.tag == "qSvE" && $0.kind == 23 }, by: \.owner)
        var noteCache: [Int: [NoteEvent]] = [:]
        var musicRegions: [Part] = []
        let musicTracks = Set(song.tracks.indices.filter { index in
            let name = song.tracks[index].name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return name.trimmingCharacters(in: .whitespacesAndNewlines) == "musicas"
        })
        for record in records where record.tag == "qSvE" && record.kind == 23 && record.owner == root {
            for event in try events(record.body) {
                let type = event.data.first ?? 0
                guard type == 0x24 || type == 0x20 else {
                    if type == 0xf1 { continue }
                    throw invalid("Unsupported arrangement event.")
                }
                guard event.count >= 80 else { throw invalid("Incomplete arrangement item.") }
                let row = try event.int(20) & 0xffffff
                guard let trackIndex = trackIndices[row] else { throw invalid("An item references an unknown track.") }
                if type == 0x20 {
                    // Arrangement +32 links to qeSM and its paired qSvE, even
                    // for copied regions whose legacy +8 link is zero.
                    let owner = try event.int(32) << 16
                    guard let sequence = sequenceRecords[owner] else { throw invalid("A MIDI region references an unknown sequence.") }
                    let nameOffset = sequence.version >= 5 ? 16 : 52
                    let title = try sequence.body.text(nameOffset)
                    let alignedName = ((try sequence.body.int(nameOffset, 2)) + 1) & ~1
                    let length = Double(try sequence.body.int(nameOffset + 62 + alignedName))
                    let tick = Double(try event.int(4)) - 34560 + Double(try event.int(0) >> 8) / 16777216
                    let start = max(0, seconds(tick)), end = seconds(tick + length)
                    guard length > 0, end.isFinite, end > start, end < 7 * 86400 else { throw invalid("Invalid MIDI region bounds.") }
                    if musicTracks.contains(trackIndex) {
                        musicRegions.append(Part(id: UUID(), name: title.isEmpty ? "Music" : title, startTime: start, endTime: end, color: 0xC7AB40))
                    } else {
                        if noteCache[owner] == nil {
                            guard let contents = sequenceEvents[owner] else { throw invalid("A MIDI region has no event sequence.") }
                            var decoded: [NoteEvent] = []
                            for content in contents {
                                for note in try events(content.body) {
                                    try Task.checkCancellation()
                                    let status = note.data.first ?? 0
                                    if status == 0xf1 { continue }
                                    guard status & 0xf0 == 0x90 else { unsupportedMIDIEvents = true; continue }
                                    guard note.count >= 32, try note.int(23, 1) == 0x89 else { throw invalid("Incomplete MIDI note.") }
                                    let velocity = try note.int(11, 1), pitch = try note.int(12, 1)
                                    let noteLength = Double(try note.int(28))
                                    guard velocity <= 127, pitch <= 127, noteLength > 0 else { throw invalid("Invalid MIDI note.") }
                                    if velocity == 0 { continue }
                                    decoded.append(NoteEvent(tick: Double(try note.int(4)) - 38400 + Double(try note.int(0) >> 8) / 16777216,
                                        length: noteLength, pitch: pitch, velocity: velocity, channel: Int(status & 15) + 1))
                                }
                            }
                            noteCache[owner] = decoded
                        }
                        // qeSM fields follow the padded name. The source start
                        // remains nonzero after cutting/copying a region, while
                        // qSvE keeps the original notes (seen in METRONOMO clips).
                        let sourceTick = Double(Int32(bitPattern: UInt32(try sequence.body.int(nameOffset + 6 + alignedName))))
                        var notes: [MIDINote] = []
                        for note in noteCache[owner] ?? [] {
                            let noteTick = tick + note.tick - sourceTick
                            if noteTick + note.length <= max(0, tick) || noteTick >= tick + length {
                                trimmedMIDINotes = true
                                continue
                            }
                            let originalStart = seconds(noteTick), originalEnd = seconds(noteTick + note.length)
                            if originalStart < start || originalEnd > end { trimmedMIDINotes = true }
                            let noteStart = max(start, originalStart), noteEnd = min(end, originalEnd)
                            guard noteEnd > noteStart else { continue }
                            notes.append(MIDINote(start: (noteStart - start) * 2, length: (noteEnd - noteStart) * 2,
                                pitch: note.pitch, velocity: note.velocity, channel: note.channel))
                            guard notes.count <= 100_000 else { throw invalid("A MIDI region contains too many notes.") }
                        }
                        notes.sort { $0.start < $1.start }
                        // Imported timelines keep their original tempo changes.
                        // Bake visible bounds to local seconds, as for REAPER,
                        // without duplicating hidden source notes in every cut.
                        var clip = AudioClip(id: UUID(), name: title.isEmpty ? "MIDI" : title, startTime: start, duration: end - start,
                                             midi: MIDIItem(notes: notes, sourceBPM: 120))
                        clip.muted = (try event.int(12) & 0x100) != 0
                        song.tracks[trackIndex].clips.append(clip)
                        midiItems += 1
                    }
                    continue
                }
                let fileID = try event.int(44), regionID = try event.int(40)
                guard let file = files[fileID], let region = regions["\(fileID):\(regionID)"] else {
                    throw invalid("An audio item has an unsupported file or region reference.")
                }
                let frames = Double(try region.integer(22, 8)), sourceFrame = Double(try region.integer(6, 8))
                let tick = Double(try event.int(4)) - 34560 + Double(try event.int(0) >> 8) / 16777216
                let start = seconds(tick)
                let duration = frames / file.rate
                guard duration.isFinite, duration > 0, duration < 7 * 86400, sourceFrame / file.rate < 7 * 86400 else {
                    throw invalid("Invalid audio item bounds.")
                }
                let end = start + duration
                guard end > 0 else { continue }
                let path = "\(mediaFolder)/\(fileID)/\(file.name)"
                media[path] = Media(relativePath: path, source: file.source)
                var clip = AudioClip(id: UUID(), name: try region.text(74), startTime: max(0, start), duration: end - max(0, start),
                                     sourceOffset: sourceFrame / file.rate + max(0, -start), audioFile: AudioFile(path: path))
                // Region mute is represented independently of selection flags.
                clip.muted = (try event.int(12) & 0x100) != 0
                if musicTracks.contains(trackIndex) {
                    musicRegions.append(Part(id: UUID(), name: clip.name, startTime: clip.startTime, endTime: clip.startTime + clip.duration, color: 0xC7AB40))
                }
                song.tracks[trackIndex].clips.append(clip)
                if event.count > 80 { extendedItems += 1 }
            }
        }
        var markers: [(name: String, start: Double, end: Double)] = []
        for record in records where record.tag == "qSvE" && record.kind == 22 {
            for event in try events(record.body) where event.data.first == 0x12 {
                guard event.count >= 48 else { throw invalid("Incomplete marker.") }
                let tick = Double(try event.int(4)) - 38400
                let length = Double(try event.int(28))
                let savedTitle = markerNames[try event.int(16)] ?? ""
                let title = savedTitle.isEmpty ? "Marker \(markers.count + 1)" : savedTitle
                markers.append((title, max(0, seconds(tick)), max(0, seconds(tick + length))))
            }
        }
        markers.sort { $0.start < $1.start }
        song.duration = max(1, song.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0,
                            markers.map(\.end).max() ?? 0, musicRegions.map(\.endTime).max() ?? 0, song.markers?.map(\.position).max() ?? 0, markers.map(\.start).max() ?? 0)
        for (index, marker) in markers.enumerated() {
            song.markers?.append(TimelineMarker(id: UUID(), name: String(marker.name.prefix(TimelineMarker.maximumNameLength)), position: marker.start, color: 0xC7AB40))
            let next = index + 1 < markers.count ? markers[index + 1].start : song.duration
            let end = min(next, marker.end > marker.start ? marker.end : next)
            if end > marker.start { song.parts.append(Part(id: UUID(), name: marker.name, startTime: marker.start, endTime: end, color: 0xC7AB40)) }
        }
        convertMusicRegions(musicRegions, in: &song)
        if song.parts.isEmpty { song.parts = [Part(id: UUID(), name: name, startTime: 0, endTime: song.duration)] }
        for index in song.tracks.indices { song.tracks[index].clips.sort { $0.startTime < $1.startTime } }
        project.songs = [song]
        var warnings: [String] = []
        if missingMixerSettings { warnings.append("Some Logic mixer channels use an unsupported layout. Their volume, pan and mute were left at defaults; review those tracks.") }
        if midiItems > 0 { warnings.append("MIDI notes were imported. Choose an instrument in CatLive; Logic instruments and plug-ins are not migrated.") }
        if unsupportedMIDIEvents { warnings.append("Logic MIDI controller, expression and nested sequence events are not migrated; review those regions.") }
        if trimmedMIDINotes { warnings.append("Only MIDI notes within each region's visible bounds were imported.") }
        if extendedItems > 0 { warnings.append("Logic Flex processing and region automation are not applied. Audio items retain their source bounds.") }
        if nestedGroups { warnings.append("Nested Logic groups were placed inside their top-level group.") }
        try project.validate()
        return Result(project: project, media: media.values.sorted { $0.relativePath < $1.relativePath }, warnings: warnings)
    }

    /// A MUSICAS track is a song map: its regions subdivide Logic marker
    /// blocks into CatLive drawer entries. Other MIDI tracks remain instruments.
    private static func convertMusicRegions(_ source: [Part], in song: inout Song) {
        let epsilon = 0.000001
        var music: [Part] = []
        for item in source.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = music.last, abs(last.startTime - item.startTime) <= epsilon { continue }
            music.append(item)
        }
        guard !music.isEmpty else { return }
        let roots = song.parts.sorted { $0.startTime < $1.startTime }
        var assigned = Set<UUID>()
        var linked: [TimelineMarker] = []
        for (index, root) in roots.enumerated() {
            let next = index + 1 < roots.count ? roots[index + 1].startTime : song.duration
            let entries = music.filter { $0.startTime >= root.startTime - epsilon && $0.startTime < root.endTime - epsilon && $0.endTime <= next + epsilon }
            guard !entries.isEmpty else { continue }
            assigned.formUnion(entries.map(\.id))
            // A short Logic marker may only mark the beginning of a song.
            if let last = entries.last, let rootIndex = song.parts.firstIndex(where: { $0.id == root.id }) {
                song.parts[rootIndex].endTime = max(root.endTime, last.endTime)
            }
            // One song already has its top-level region. Multiple songs form
            // a special region, preserving each item's exact bounds and gaps.
            guard entries.count > 1 else { continue }
            for var entry in entries {
                entry.parentRegionID = root.id
                song.parts.append(entry)
                linked.append(TimelineMarker(id: UUID(), name: entry.name, position: entry.startTime, color: entry.color ?? 0xC7AB40,
                                             unifiedRegionID: root.id, sourceRegionID: entry.id))
            }
        }
        for entry in music where !assigned.contains(entry.id) {
            song.parts.append(entry)
            linked.append(TimelineMarker(id: UUID(), name: String(entry.name.prefix(TimelineMarker.maximumNameLength)), position: entry.startTime, color: entry.color ?? 0xC7AB40))
        }
        // Tempo points have their own lane. Prefer song flags over ordinary
        // marker flags at the same point, without duplicating either kind.
        let tempos = (song.markers ?? []).filter(\.isTempo)
        let ordinary = (song.markers ?? []).filter { !$0.isTempo }
        let candidates = (linked + ordinary).enumerated().sorted {
            $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position
        }
        var flags: [TimelineMarker] = []
        for candidate in candidates {
            if let last = flags.last, abs(last.position - candidate.element.position) <= epsilon { continue }
            flags.append(candidate.element)
        }
        song.markers = tempos + flags
        song.parts.sort { $0.startTime == $1.startTime ? $0.endTime > $1.endTime : $0.startTime < $1.startTime }
    }

    public static func save(_ result: Result, to destination: URL) throws {
        try ProjectMigration.save(result, to: destination)
    }
    private static func plist(_ url: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw invalid("Invalid project metadata.")
        }
        return value
    }
    private static func parse(_ data: Data) throws -> [Record] {
        let bytes = Bytes(data: data)
        guard try bytes.integer(0) == 0xabc04723, try bytes.int(16) == data.count - 24 else { throw invalid("Unsupported project container.") }
        var offset = 24, result: [Record] = []
        while offset < data.count {
            try Task.checkCancellation()
            let header = try bytes.slice(offset, 36)
            if try header.integer(0) == 0xabc04723 {
                let length = try header.int(16)
                _ = try bytes.slice(offset, 24 + length)
                offset += 24 + length; continue
            }
            guard let tag = String(data: try header.slice(0, 4).data, encoding: .ascii), tag.utf8.allSatisfy({ (32..<127).contains($0) }) else {
                throw invalid("Invalid project record.")
            }
            let length = try header.int(28)
            let body = try bytes.slice(offset + 36, length)
            result.append(Record(tag: tag, version: try header.int(4, 2), kind: try header.int(6, 2),
                                 owner: try header.int(8), index: try header.int(tag == "karT" ? 18 : 14), body: body))
            offset += 36 + length
        }
        return result
    }
    private static func events(_ bytes: Bytes) throws -> [Bytes] {
        guard bytes.count % 16 == 0 else { throw invalid("Unsupported event layout.") }
        var result: [Bytes] = [], offset = 0
        while offset < bytes.count {
            guard try bytes.int(offset + 7, 1) & 0x80 == 0 else { throw invalid("Invalid event boundary.") }
            var end = offset + 16
            while end < bytes.count, try bytes.int(end + 7, 1) & 0x80 != 0 { end += 16 }
            result.append(try bytes.slice(offset, end - offset)); offset = end
        }
        return result
    }
}
#endif
