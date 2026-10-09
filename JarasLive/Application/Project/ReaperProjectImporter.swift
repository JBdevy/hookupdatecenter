import Foundation
import AVFoundation
#if os(macOS)

/// Reads arrangement data without launching REAPER or modifying the source.
public enum ReaperProjectImporter {
    private final class Chunk {
        let header: [String]
        var lines: [[String]] = []
        var notes: [String] = []
        var midiEvents: [[String]] = []
        var children: [Chunk] = []
        init(_ header: [String]) { self.header = header }
        func line(_ key: String) -> [String] { lines.first { $0.first == key } ?? [] }
        func child(_ key: String) -> Chunk? { children.first { $0.header.first == key } }
        func value(_ key: String, _ index: Int = 1) -> String? { let row = line(key); return row.indices.contains(index) ? row[index] : nil }
        func integer(_ key: String, _ index: Int = 1, default fallback: Int = 0) throws -> Int {
            guard let text = value(key, index) else { return fallback }
            guard let value = Int(text) else { throw ReaperProjectImporter.invalid("Invalid integer value.") }
            return value
        }
        func number(_ key: String, _ index: Int = 1, default fallback: Double = 0) throws -> Double {
            guard let text = value(key, index) else { return fallback }
            return try ReaperProjectImporter.number(text)
        }
    }
    private static func invalid(_ detail: String) -> ProjectError { .invalid("REAPER: " + detail) }
    private static func number(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite else { throw invalid("Invalid numeric value.") }
        return value
    }
    // WDL uses three quote delimiters and literal backslashes, including Windows paths.
    private static func tokens(_ line: Substring) throws -> [String] {
        var result: [String] = [], i = line.startIndex
        while i < line.endIndex {
            if line[i].isWhitespace { i = line.index(after: i); continue }
            let quote = line[i], quoted = quote == "\"" || quote == "'" || quote == "`"
            if quoted { i = line.index(after: i) }
            let start = i
            while i < line.endIndex && (quoted ? line[i] != quote : !line[i].isWhitespace) { i = line.index(after: i) }
            result.append(String(line[start..<i]))
            if quoted {
                guard i < line.endIndex else { throw invalid("Unterminated quoted value.") }
                i = line.index(after: i)
            }
        }
        return result
    }
    private static func parse(_ text: String) throws -> Chunk {
        var stack: [Chunk] = [], root: Chunk?, count = 0
        let keys: Set<String> = ["NAME", "TEMPO", "MARKER", "PT", "VOLPAN", "MUTESOLO", "ISBUS", "PEAKCOL", "POSITION", "LENGTH", "SOFFS", "PLAYRATE", "MUTE", "FADEIN", "FADEOUT", "CHANMODE", "LOOP", "FILE", "TAKE", "SEL", "ALLTAKES", "STARTPOS", "MODE", "MASTER_VOLUME", "MASTERMUTESOLO", "AUXRECV", "MAINSEND", "PANMODE", "SM", "PITCHENV", "STARTTIME", "FRAMERATE", "SEND", "USERDATA", "HASDATA", "IGNTEMPO", "POOLEDEVTS", "E", "e", "Em", "em"]
        for raw in text.split(whereSeparator: \.isNewline) {
            count += 1
            if count % 1024 == 0 { try Task.checkCancellation() }
            guard count <= 2_000_000 else { throw invalid("Project is too large.") }
            let line = raw.drop(while: \.isWhitespace)
            if line.isEmpty { continue }
            if stack.last?.header.first == "BIN", line != ">" {
                stack.last?.notes.append(String(line)); continue
            }
            if stack.last?.header.first == "NOTES", line.first == "|" { stack.last?.notes.append(String(line.dropFirst())); continue }
            if line.first == "<" {
                let header = try tokens(line.dropFirst())
                guard !header.isEmpty, stack.count < 128 else { throw invalid("Invalid chunk nesting.") }
                let chunk = Chunk(header)
                if let parent = stack.last {
                    parent.children.append(chunk)
                    if ["X", "x", "Xm", "xm"].contains(header[0]), parent.header == ["SOURCE", "MIDI"] { parent.midiEvents.append(header) }
                }
                else { guard root == nil else { throw invalid("Multiple project roots.") }; root = chunk }
                stack.append(chunk)
            } else if line.trimmingCharacters(in: .whitespaces) == ">" {
                guard !stack.isEmpty else { throw invalid("Unexpected chunk end.") }
                // Unbracketed TAKE sections belong to the enclosing ITEM.
                if stack.last?.header.first == "TAKE_INLINE" { stack.removeLast() }
                guard !stack.isEmpty else { throw invalid("Invalid take nesting.") }
                stack.removeLast()
            } else {
                guard let parent = stack.last else { throw invalid("Data outside project.") }
                let key = String(line.prefix(while: { !$0.isWhitespace }))
                let hookSection = ["CHATGPT_REGION_PLAYLIST", "VS_HOOK_MULTILOOPS"].contains(parent.header.first ?? "")
                guard keys.contains(key) || hookSection else { continue }
                let row = try tokens(line)
                if key == "TAKE", parent.header.first == "ITEM" || parent.header.first == "TAKE_INLINE" {
                    if parent.header.first == "TAKE_INLINE" { stack.removeLast() }
                    let take = Chunk(["TAKE_INLINE"] + row.dropFirst())
                    stack.last!.children.append(take); stack.append(take)
                } else {
                    parent.lines.append(row)
                    if ["E", "e", "Em", "em"].contains(key), parent.header == ["SOURCE", "MIDI"] { parent.midiEvents.append(row) }
                }
            }
        }
        guard stack.isEmpty, let root, root.header.first == "REAPER_PROJECT" else { throw invalid("Incomplete or invalid .rpp project.") }
        return root
    }
    public static func read(_ source: URL) throws -> ProjectMigration.Result {
        guard source.pathExtension.lowercased() == "rpp" else { throw invalid("Select a .rpp project.") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 * 1024 else { throw invalid("Invalid project size.") }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw invalid("Invalid text encoding.") }
        let root = try parse(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")))
        var hookState: [String: [String: String]] = [:]
        for section in root.child("EXTSTATE")?.children ?? [] where ["CHATGPT_REGION_PLAYLIST", "VS_HOOK_MULTILOOPS"].contains(section.header.first ?? "") {
            var values: [String: String] = [:]
            for row in section.lines where row.count >= 2 { values[row[0]] = row.dropFirst().joined(separator: " ") }
            for binary in section.children where binary.header.first == "BIN" && binary.header.count == 2 {
                if let data = Data(base64Encoded: binary.notes.joined()), let value = String(data: data, encoding: .utf8) {
                    values[binary.header[1]] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                } else { throw invalid("Invalid VS Hook project metadata.") }
            }
            hookState[section.header[0]] = values
        }
        var hook = VSHookProjectMigration(state: hookState)
        var project = Project.empty(name: source.deletingPathExtension().lastPathComponent)
        project.importedTimeline = true
        var song = project.songs[0]
        song.tracks = []; song.parts = []; song.markers = []; song.timeSettings = ProjectTimeSettings()
        song.bpm = try root.number("TEMPO", default: 120)
        song.beatsPerBar = try root.integer("TEMPO", 2, default: 4)
        song.beatUnit = try root.integer("TEMPO", 3, default: 4)
        var warnings = Set<String>()
        let midiTempo = try MIDITempoMap(root)
        var midiPools: [String: Chunk] = [:]
        func collectPools(_ chunk: Chunk) {
            if chunk.header == ["SOURCE", "MIDI"], let pool = chunk.value("POOLEDEVTS"), !chunk.midiEvents.isEmpty { midiPools[pool] = chunk }
            for child in chunk.children { collectPools(child) }
        }
        collectPools(root)
        let unsupported = "REAPER effects, automation, sends, pitch envelopes and advanced playback settings are not converted. Review the migrated mix."
        func limitedVolume(_ value: Double) -> Double {
            let limited = min(pow(10, 12.0 / 20), max(0, value))
            if limited != value { warnings.insert("REAPER mixer volumes above +12 dB were limited to the CatLive mixer range.") }
            return limited
        }
        project.masterVolume = limitedVolume(try root.number("MASTER_VOLUME", default: 1))
        if try root.number("PLAYRATE", default: 1) != 1 || root.child("MASTERFXLIST") != nil || root.child("MASTERFXCHAIN") != nil || root.number("MASTERMUTESOLO") != 0 { warnings.insert(unsupported) }
        let base = source.deletingLastPathComponent()
        let mediaRoot = "Stems/REAPER-" + UUID().uuidString
        var media: [String: ProjectMigration.Media] = [:]
        var lengths: [String: Double] = [:]
        func reference(_ path: String, projection: Bool = false) throws -> ProjectMigration.Media {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            let key = (projection ? "video:" : "audio:") + normalized
            if let existing = media[key] { return existing }
            let name = (normalized as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains(":"), !name.contains("\0") else { throw invalid("Invalid audio filename.") }
            let windowsAbsolute = normalized.count > 2 && normalized.dropFirst().first == ":"
            let candidate = normalized.hasPrefix("/") ? URL(fileURLWithPath: normalized) : base.appendingPathComponent(normalized)
            // Only use the explicit reference; ambiguous basename searches belong to recovery.
            let found = !windowsAbsolute && (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? candidate : nil
            let result = ProjectMigration.Media(relativePath: (projection ? mediaRoot.replacingOccurrences(of: "Stems/", with: "Videos/") : mediaRoot) + "/\(media.count + 1)/" + name, source: found)
            media[key] = result
            return result
        }
        func color(_ text: String?) -> UInt32? {
            guard let text, let raw = UInt32(text), raw & 0x1000000 != 0 else { return nil }
            // RPP serializes portable RGB with red in the low byte.
            return (raw & 255) << 16 | (raw & 0xff00) | ((raw >> 16) & 255)
        }
        var folders: [UUID] = []
        let tracks = root.children.filter { $0.header.first == "TRACK" }
        for node in tracks {
            try Task.checkCancellation()
            var track = Track(id: UUID(), name: node.value("NAME").flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(song.tracks.count + 1)", role: .other)
            track.volume = limitedVolume(try node.number("VOLPAN", default: 1))
            track.pan = try node.number("VOLPAN", 2)
            track.mute = try node.number("MUTESOLO") != 0
            track.solo = try node.number("MUTESOLO", 2) != 0
            track.color = color(node.value("PEAKCOL"))
            track.parentTrackID = folders.first
            let special = specialKind(track.name)
            hook.trackIDs["TRACK_\(song.tracks.count + 1)"] = track.id
            if let guid = node.header.dropFirst().first { hook.trackIDs[guid.uppercased()] = track.id }
            if let special {
                track.role = special == .video ? .other : TrackRole(rawValue: special.rawValue); track.name = special.title
                track.parentTrackID = nil; track.color = special.defaultColor
                if special.isText { track.mute = false }
                if special != .video { track.solo = false }
                if special == .timecode { track.timecode = TimecodeSettings(); track.importedTimecodeItems = true; track.patch = OutputPatch.none }
            }
            let delta = try node.integer("ISBUS", 2)
            guard (-1000...1).contains(delta), delta >= -folders.count else { throw invalid("Invalid track folder structure.") }
            if delta > 0 {
                if !folders.isEmpty { warnings.insert("Nested REAPER folders were placed inside their top-level group.") }
                if special != nil { throw invalid("Uma pista especial não pode ser uma pasta de áudio no projeto de origem.") }
                folders.append(track.id)
            }
            if node.child("FXCHAIN") != nil || !node.line("AUXRECV").isEmpty || node.children.contains(where: { $0.header.first?.contains("ENV") == true }) { warnings.insert(unsupported) }
            for item in node.children where item.header.first == "ITEM" {
                var take = item
                let takes = item.children.filter { ["TAKE", "TAKE_INLINE"].contains($0.header.first ?? "") }
                if let selected = takes.first(where: { $0.header.contains("SEL") || $0.value("SEL") == "1" }) { take = selected }
                else if item.child("SOURCE") == nil, let first = takes.first { take = first }
                if !takes.isEmpty { warnings.insert("Only the active REAPER take is imported for each item.") }
                let start = try item.number("POSITION"), duration = try item.number("LENGTH")
                guard start >= 0, duration > 0 else { throw invalid("Invalid item position or length.") }
                var clip = AudioClip(id: UUID(), name: take.value("NAME") ?? item.value("NAME") ?? "Item", startTime: start, duration: duration)
                if let special {
                    let source = take.child("SOURCE")
                    if special == .timecode {
                        guard let source, source.header.dropFirst().first == "LTC" else {
                            throw invalid("O item da pista Timecode não contém as configurações do gerador SMPTE. Use o gerador LTC/MTC do REAPER para migrar esse item.")
                        }
                        var settings = TimecodeSettings()
                        let send = try source.integer("SEND", default: 1)
                        guard send == 1 || send == 2 else { throw invalid("O gerador Timecode deve usar LTC ou MTC individualmente para migrar.") }
                        settings.mode = send == 2 ? "mtc" : "ltc"
                        settings.frameRate = try source.number("FRAMERATE", default: 30)
                        settings.offset = try source.number("STARTTIME") + take.number("SOFFS")
                        settings.regionRelative = true
                        guard try take.number("PLAYRATE", default: 1) == 1 else { throw invalid("Timecode com velocidade alterada não pode ser recriado com a mesma configuração.") }
                        guard source.line("USERDATA").dropFirst().allSatisfy({ Double($0) == 0 }) else { throw invalid("Timecode com user bits personalizados ainda não é suportado pelo CatLive.") }
                        try settings.validate()
                        clip.timecode = settings; clip.name = settings.mode.uppercased()
                        clip.muted = try item.number("MUTE") != 0
                        if track.clips.isEmpty { track.timecode = settings }
                    } else if let filename = source?.value("FILE"), special == .video || special.isTeleprompter {
                        let ref = try reference(filename, projection: true)
                        clip.audioFile = AudioFile(path: ref.relativePath)
                        clip.sourceOffset = try take.number("SOFFS")
                        clip.playbackRate = try take.number("PLAYRATE", default: 1)
                    } else if special.isText {
                        let text = item.child("NOTES")?.notes.joined(separator: "\n") ?? take.child("NOTES")?.notes.joined(separator: "\n") ?? take.value("NAME") ?? ""
                        try AudioClip.validateText(text, maximum: special.maximumTextLength ?? 400)
                        clip.text = text
                        clip.name = text.components(separatedBy: "\n").first ?? ""
                    }
                    track.clips.append(clip)
                    continue
                }
                let itemPitch = try take.number("PLAYRATE", 3)
                if (-12...12).contains(itemPitch) { clip.pitchSemitones = itemPitch == 0 ? nil : itemPitch }
                else { warnings.insert("Item pitch outside the supported ±12 semitone range was not converted.") }
                clip.sourceOffset = try take.number("SOFFS")
                clip.playbackRate = try take.number("PLAYRATE", default: 1)
                clip.gain = abs(try take.number("VOLPAN", default: 1) * take.number("VOLPAN", 3, default: 1))
                clip.muted = try item.number("MUTE") != 0
                clip.fadeIn = try item.number("FADEIN", 2)
                clip.fadeOut = try item.number("FADEOUT", 2)
                let mode = try take.integer("CHANMODE")
                clip.channelMode = [0: 0, 2: 3, 3: 1, 4: 2][mode] ?? 0
                if try ![0, 2, 3, 4].contains(mode) || take.child("TAKEFX") != nil || take.number("VOLPAN", 2) != 0 || !take.line("SM").isEmpty || item.number("ALLTAKES") != 0 { warnings.insert(unsupported) }
                var audio = take.child("SOURCE"), sectionStart = 0.0, sectionLength: Double?
                if let section = audio, section.header.dropFirst().first == "SECTION" {
                    sectionStart = try section.number("STARTPOS")
                    sectionLength = try section.number("LENGTH")
                    if try section.number("MODE") != 0 { warnings.insert(unsupported) }
                    audio = section.child("SOURCE")
                }
                let kind = audio?.header.dropFirst().first ?? ""
                if let audio, ["WAVE", "MP3", "FLAC", "VORBIS", "AIFF", "AIF", "OPUS", "WAVPACK"].contains(kind), let filename = audio.value("FILE") {
                    let ref = try reference(filename)
                    clip.audioFile = AudioFile(path: ref.relativePath)
                    if clip.name.isEmpty || clip.name == "Item" { clip.name = (filename.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
                    clip.sourceOffset += sectionStart
                    if try item.number("LOOP") != 0 {
                        var length = sectionLength
                        if length == nil, let file = ref.source {
                            if let cached = lengths[file.path] { length = cached }
                            else if let reader = try? AVAudioFile(forReading: file), reader.fileFormat.sampleRate > 0 {
                                length = Double(reader.length) / reader.fileFormat.sampleRate; lengths[file.path] = length
                            }
                        }
                        if let length, length > 0 {
                            clip.loopStart = sectionStart; clip.loopLength = length
                        } else { warnings.insert("Loop lengths for offline REAPER audio could not be determined. Review looped items after locating the files.") }
                    }
                } else if let audio, kind == "MIDI" {
                    clip.midi = try midiItem(source: audio, take: take, item: item, clip: clip, base: base,
                                            tempo: midiTempo, pools: midiPools, warnings: &warnings)
                    // The imported notes contain the audible repetitions and
                    // tempo/rate/trim mapping; playback must apply them once.
                    clip.sourceOffset = 0; clip.playbackRate = 1
                    clip.loopStart = nil; clip.loopLength = nil
                    clip.channelMode = nil; clip.fadeIn = nil; clip.fadeOut = nil
                    warnings.insert("MIDI notes were imported. Choose an instrument in CatLive; REAPER instruments and plug-ins are not migrated.")
                } else if !kind.isEmpty {
                    clip.name = "[\(kind)] " + clip.name
                    warnings.insert("REAPER video and unsupported sources are retained as empty items. Render them to audio in REAPER to migrate their sound.")
                }
                track.clips.append(clip)
            }
            if track.kind.isSingleLane {
                // VS Hook projects can contain empty placeholders underneath their
                // actual lyrics. They must not hide the text or create a second lane.
                let populated = track.clips.filter { $0.audioFile != nil || !($0.text ?? "").isEmpty }
                track.clips.removeAll { clip in
                    clip.audioFile == nil && (clip.text ?? "").isEmpty && populated.contains { other in
                        clip.startTime < other.startTime + other.duration - 0.0000001 && clip.startTime + clip.duration > other.startTime + 0.0000001
                    }
                }
            }
            song.tracks.append(track)
            if delta < 0 { folders.removeLast(-delta) }
        }
        var regionStarts: [String: (Double, String, UInt32?)] = [:]
        for row in root.lines where row.first == "MARKER" {
            guard row.count >= 5, let flags = Int(row[4]) else { throw invalid("Invalid marker.") }
            let position = try number(row[2]), title = row[3].isEmpty ? "Marker " + row[1] : row[3]
            guard position >= 0 else { throw invalid("Invalid marker position.") }
            let tint = color(row.count > 5 ? row[5] : nil)
            if flags & 1 != 0 {
                if let begin = regionStarts.removeValue(forKey: row[1]) {
                    guard position > begin.0 else { throw invalid("Invalid region length.") }
                    let part = Part(id: UUID(), name: begin.1, startTime: begin.0, endTime: position, color: begin.2)
                    song.parts.append(part)
                    hook.regionIDs[row[1]] = part.id
                } else { regionStarts[row[1]] = (position, row[3].isEmpty ? "Region " + row[1] : row[3], tint) }
            } else {
                let marker = TimelineMarker(id: UUID(), name: title, position: position, color: tint ?? 0xC7AB40)
                song.markers?.append(marker)
                hook.sourceMarkers.append(.init(number: row[1], marker: marker))
            }
        }
        guard regionStarts.isEmpty else { throw invalid("Incomplete region.") }
        song.parts.sort { $0.startTime == $1.startTime ? $0.endTime > $1.endTime : $0.startTime < $1.startTime }
        var accepted: [Part] = []
        for var region in song.parts {
            if let parent = accepted.first(where: { $0.parentRegionID == nil && $0.startTime <= region.startTime && $0.endTime >= region.endTime }) { region.parentRegionID = parent.id }
            if RegionLanes(parts: accepted + [region]).count <= 2 { accepted.append(region) }
            else {
                warnings.insert("Regions beyond the two supported overlap lanes were converted to start and end markers.")
                for (suffix, time) in [("", region.startTime), (" end", region.endTime)] {
                    song.markers?.append(TimelineMarker(id: UUID(), name: String((region.name + suffix).prefix(TimelineMarker.maximumNameLength)), position: time, color: region.color ?? 0xC7AB40))
                }
            }
        }
        song.parts = accepted
        // VS Hook accepts a closing point within half a millisecond of the end.
        for index in song.markers?.indices ?? 0..<0 where hook.isTechnicalMarker(song.markers![index].name) {
            let position = song.markers![index].position
            if let end = song.parts.map(\.endTime).filter({ abs($0 - position) <= 0.0005 }).min(by: { abs($0 - position) < abs($1 - position) }) {
                song.markers![index].position = end
            }
        }
        // Loop endpoints and VS Hook commands are not songs in a unified region.
        let technical = (song.markers ?? []).filter { hook.isTechnicalMarker($0.name) }
        song.markers?.removeAll { hook.isTechnicalMarker($0.name) }
        let hookMarkerParents = hook.hasMetadata ? Set(song.parts.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--")
        }.map(\.id)) : nil
        convertSpecialRegions(in: &song, markerParentIDs: hookMarkerParents)
        for original in technical {
            var marker = original
            let label = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.hasPrefix("*") || label.hasPrefix("$") {
                // Source names remain intact in hook.sourceMarkers for loop pairing.
                let slotPrefix = (1...4).contains { label.hasPrefix("*\($0)") }
                let suffix = slotPrefix ? label.dropFirst(2) : label.dropFirst()
                let name = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                marker.name = name.isEmpty ? "Trecho" : name
                if song.parts.contains(where: { marker.position >= $0.startTime && marker.position <= $0.endTime }) { marker.section = true; marker.loopSection = label.hasPrefix("*") }
                else { warnings.insert("VS Hook: um marcador de trecho fora de uma música foi mantido como marcador comum.") }
            }
            if let index = song.markers?.firstIndex(where: { abs($0.position - marker.position) <= 0.000001 }) {
                if marker.isSection {
                    song.markers?[index].section = true
                    if marker.isLoopSection { song.markers?[index].loopSection = true }
                }
            } else {
                marker.name = String((marker.isSection ? marker.name.uppercased() : marker.name).prefix(marker.isSection ? TimelineMarker.maximumSectionNameLength : TimelineMarker.maximumNameLength))
                song.markers?.append(marker)
            }
        }
        if let tempo = root.child("TEMPOENVEX") {
            for row in tempo.lines where row.first == "PT" {
                guard row.count >= 3 else { throw invalid("Invalid tempo point.") }
                let position = try number(row[1]), bpm = try number(row[2])
                if TimelineTempo.bpmRange.contains(bpm), position >= 0 {
                    let signature = row.count > 4 ? Int(row[4]) ?? 0 : 0
                    if signature != 0 { song.beatsPerBar = signature & 0xffff; song.beatUnit = signature >> 16 }
                    let meterBeats = song.meterBeats, meterUnit = song.meterUnit
                    song.markers?.append(TimelineMarker(id: UUID(), name: String(format: "%g", bpm), position: position, color: 0xAAAAAA, tempoBPM: bpm, tempoBeats: meterBeats, tempoUnit: meterUnit, tempoTimebase: .global, tempoReferenceBPM: bpm))
                } else { warnings.insert("Tempo points outside the CatLive tempo range were omitted; item positions in seconds are unchanged.") }
                if row.count > 3 && row[3] != "1" { warnings.insert("REAPER tempo ramps were imported as discrete tempo points; item positions in seconds are unchanged.") }
            }
        }
        // The initial meter is independent from later tempo/time-signature changes.
        song.beatsPerBar = try root.integer("TEMPO", 2, default: 4); song.beatUnit = try root.integer("TEMPO", 3, default: 4)
        song.duration = max(1, song.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0, song.parts.map(\.endTime).max() ?? 0, song.markers?.map(\.position).max() ?? 0)
        if song.parts.isEmpty { song.parts = [Part(id: UUID(), name: song.name, startTime: 0, endTime: song.duration)] }
        project.songs = [song]
        hook.apply(to: &project, warnings: &warnings)
        project.orderSpecialTracks()
        try project.validate()
        return ProjectMigration.Result(project: project, media: media.values.sorted { $0.relativePath < $1.relativePath }, warnings: warnings.sorted())
    }
    /// RPP MIDI uses source quarter notes. Integrate the original tempo map
    /// before flattening into the imported free timeline, including linear ramps.
    private struct MIDITempoMap {
        struct Point { let time: Double; let bpm: Double; let linear: Bool; var beat: Double = 0 }
        let points: [Point]
        init(_ root: Chunk) throws {
            let initial = try root.number("TEMPO", default: 120)
            guard initial > 0 else { throw invalid("Invalid MIDI project tempo.") }
            var values = [Point(time: 0, bpm: initial, linear: false)]
            for row in root.child("TEMPOENVEX")?.lines ?? [] where row.first == "PT" {
                guard row.count >= 3 else { throw invalid("Invalid tempo point.") }
                let time = try number(row[1]), bpm = try number(row[2])
                guard time >= 0, bpm > 0 else { throw invalid("Invalid MIDI tempo point.") }
                values.append(Point(time: time, bpm: bpm, linear: row.count > 3 && row[3] == "0"))
            }
            let sorted = values.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            var result: [Point] = []
            for entry in sorted {
                if result.last?.time == entry.element.time { result.removeLast() }
                var point = entry.element
                if let previous = result.last {
                    point.beat = previous.beat + (point.time - previous.time) * (previous.linear ? (previous.bpm + point.bpm) / 2 : previous.bpm) / 60
                }
                result.append(point)
            }
            points = result
        }
        func beat(at time: Double) -> Double {
            let index = points.lastIndex { $0.time <= time } ?? 0
            let point = points[index], elapsed = time - point.time
            let slope = point.linear && time >= point.time && points.indices.contains(index + 1) ? (points[index + 1].bpm - point.bpm) / (points[index + 1].time - point.time) : 0
            return point.beat + (point.bpm * elapsed + slope * elapsed * elapsed / 2) / 60
        }
        func time(at beat: Double) -> Double {
            let index = points.lastIndex { $0.beat <= beat } ?? 0
            let point = points[index], elapsedBeats = beat - point.beat
            let slope = point.linear && points.indices.contains(index + 1) && beat >= point.beat ? (points[index + 1].bpm - point.bpm) / (points[index + 1].time - point.time) : 0
            if abs(slope) < 0.000000000001 { return point.time + elapsedBeats * 60 / point.bpm }
            let discriminant = max(0, point.bpm * point.bpm + 120 * slope * elapsedBeats)
            return point.time + 120 * elapsedBeats / (point.bpm + sqrt(discriminant))
        }
    }
    private struct MIDISource { let notes: [MIDINote]; let length: Double }
    private static func inlineMIDI(_ source: Chunk, warnings: inout Set<String>) throws -> MIDISource {
        let ppq = try source.number("HASDATA", 2, default: 960)
        guard ppq > 0, ppq <= 1_000_000, source.value("HASDATA", 3).map({ $0 == "QN" }) ?? true else { throw invalid("Unsupported MIDI tick format.") }
        struct Pending { let start: Double; let velocity: Int; let muted: Bool }
        struct Queue { var values: [Pending] = []; var index = 0 }
        var active: [Int: Queue] = [:], notes: [MIDINote] = [], ticks = 0.0, noteOns = 0
        for (index, row) in source.midiEvents.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            guard row.count >= 2, let delta = Int64(row[1]) else { throw invalid("Invalid MIDI event offset.") }
            ticks += Double(delta)
            guard abs(ticks) <= 10_000_000 * ppq else { throw invalid("MIDI event is outside the supported range.") }
            guard row[0].lowercased().first == "e" else {
                warnings.insert("MIDI controllers, program changes and SysEx are not migrated; review the instrument settings.")
                continue
            }
            guard row.count >= 3, let status = UInt8(row[2], radix: 16), status >= 0x80 else { throw invalid("Invalid MIDI event bytes.") }
            if status >= 0xf0 {
                warnings.insert("MIDI controllers, program changes and SysEx are not migrated; review the instrument settings.")
                continue
            }
            guard row.count >= 4, let first = UInt8(row[3], radix: 16), first < 128 else { throw invalid("Invalid MIDI event bytes.") }
            let kind = status & 0xf0, channel = Int(status & 15) + 1
            let byteCount = kind == 0xc0 || kind == 0xd0 ? 4 : 5
            guard row.count >= byteCount else { throw invalid("Truncated MIDI event.") }
            let second: UInt8
            if byteCount == 5 {
                guard let byte = UInt8(row[4], radix: 16), byte < 128 else { throw invalid("Invalid MIDI event data.") }
                second = byte
            } else { second = 0 }
            let key = channel * 128 + Int(first), muted = row[0].lowercased().contains("m")
            if muted { warnings.insert("Muted MIDI notes were omitted because individual note mute is not supported.") }
            if kind == 0x90 && second > 0 {
                noteOns += 1
                guard noteOns <= 100_000 else { throw invalid("Too many MIDI notes.") }
                var queue = active.removeValue(forKey: key) ?? Queue()
                queue.values.append(Pending(start: ticks / ppq, velocity: Int(second), muted: muted))
                active[key] = queue
            } else if kind == 0x80 || kind == 0x90 {
                if var queue = active.removeValue(forKey: key), queue.index < queue.values.count {
                    let start = queue.values[queue.index]; queue.index += 1
                    if queue.index < queue.values.count { active[key] = queue }
                    if !start.muted, !muted, ticks / ppq > start.start {
                        notes.append(MIDINote(start: start.start, length: ticks / ppq - start.start, pitch: Int(first), velocity: start.velocity, channel: channel))
                    }
                }
            } else if kind != 0xb0 || first != 123 {
                warnings.insert("MIDI controllers, program changes and SysEx are not migrated; review the instrument settings.")
            }
        }
        if !active.isEmpty { warnings.insert("MIDI notes without a matching note-off were omitted.") }
        notes.sort { $0.start == $1.start ? $0.pitch < $1.pitch : $0.start < $1.start }
        return MIDISource(notes: notes, length: max(ticks / ppq, notes.map(\.end).max() ?? 0))
    }
    private static func midiItem(source: Chunk, take: Chunk, item: Chunk, clip: AudioClip, base: URL,
                                 tempo: MIDITempoMap, pools: [String: Chunk], warnings: inout Set<String>) throws -> MIDIItem {
        let data: MIDISource
        if let filename = source.value("FILE") {
            let path = filename.replacingOccurrences(of: "\\", with: "/")
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw invalid("Missing MIDI source: " + filename + ". Locate it before importing the project.")
            }
            let file = try StandardMIDIFileImport.read(url)
            data = MIDISource(notes: file.tracks.flatMap(\.notes), length: file.tracks.map(\.length).max() ?? 0)
            if file.hasUnsupportedEvents { warnings.insert("MIDI controllers, program changes and SysEx are not migrated; review the instrument settings.") }
        } else {
            var events = source
            if source.midiEvents.isEmpty, let pool = source.value("POOLEDEVTS") {
                guard let original = pools[pool] else { throw invalid("Missing pooled MIDI source.") }
                events = original
            }
            data = try inlineMIDI(events, warnings: &warnings)
        }
        let rate = clip.audioRate
        guard rate.isFinite, (1.0 / 32...32).contains(rate) else { throw invalid("Invalid MIDI playback rate.") }
        let ignoreTempo = try source.integer("IGNTEMPO") != 0
        let fixedBPM = try source.number("IGNTEMPO", 2, default: 120)
        guard fixedBPM > 0 else { throw invalid("Invalid source MIDI tempo.") }
        let startBeat = tempo.beat(at: clip.startTime)
        let offset: Double
        if let value = take.value("SOFFS", 2) { offset = try number(value) }
        else if ignoreTempo { offset = clip.sourceOffset * fixedBPM / 60 }
        else { offset = (startBeat - tempo.beat(at: clip.startTime - clip.sourceOffset / rate)) * rate }
        func sourceBeat(at time: Double) -> Double {
            offset + (ignoreTempo ? (time - clip.startTime) * fixedBPM / 60 : tempo.beat(at: time) - startBeat) * rate
        }
        func time(at sourceBeat: Double) -> Double {
            ignoreTempo ? clip.startTime + (sourceBeat - offset) * 60 / fixedBPM / rate : tempo.time(at: startBeat + (sourceBeat - offset) / rate)
        }
        let endBeat = sourceBeat(at: clip.startTime + clip.duration)
        let looped = try item.integer("LOOP") != 0 && data.length > 0
        var notes: [MIDINote] = []
        for (index, note) in data.notes.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            let first = looped ? floor((offset - note.end) / data.length) + 1 : 0
            let last = looped ? ceil((endBeat - note.start) / data.length) - 1 : 0
            guard first.isFinite, last.isFinite, abs(first) < 1e12, abs(last) < 1e12,
                  last - first < 100_000 else { throw invalid("Too many MIDI loop repetitions.") }
            if last < first { continue }
            for repetition in Int64(first)...Int64(last) {
                let displacement = looped ? Double(repetition) * data.length : 0
                let begin = max(clip.startTime, time(at: note.start + displacement))
                let end = min(clip.startTime + clip.duration, time(at: note.end + displacement))
                if end > begin {
                    // 120 BPM is the neutral source coordinate system (2 QN/s).
                    notes.append(MIDINote(start: (begin - clip.startTime) * 2, length: (end - begin) * 2,
                                          pitch: note.pitch, velocity: note.velocity, channel: note.channel))
                    guard notes.count <= 100_000 else { throw invalid("Too many imported MIDI notes.") }
                }
            }
        }
        notes.sort { $0.start == $1.start ? ($0.channel == $1.channel ? $0.pitch < $1.pitch : $0.channel < $1.channel) : $0.start < $1.start }
        return MIDIItem(notes: notes, sourceBPM: 120)
    }
    private static func specialKind(_ name: String) -> TrackKind? {
        let key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }.lowercased()
        switch key {
        case "teleprompt1", "teleprompter1": return .teleprompt
        case "teleprompt2", "teleprompter2": return .teleprompt2
        case "media": return .video
        case "cifras": return .chords
        case "timecode": return .timecode
        default: return nil
        }
    }
    /// REAPER can describe a special region either with child regions or with
    /// marker starts. Materialize both as CatLive drawer entries and linked flags.
    private static func convertSpecialRegions(in song: inout Song, markerParentIDs: Set<UUID>? = nil) {
        let epsilon = 0.000001
        func samePoint(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= epsilon }
        let ordered = (song.markers ?? []).enumerated().sorted {
            $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position
        }
        var markers: [TimelineMarker] = []
        for entry in ordered {
            if let last = markers.last, samePoint(last.position, entry.element.position) { continue }
            markers.append(entry.element)
        }
        let roots = song.parts.filter { $0.parentRegionID == nil }
        var consumed = Set<UUID>()
        var linked: [TimelineMarker] = []
        for root in roots {
            // At a shared edge, the marker belongs to the region that starts there.
            let inside = markers.filter { marker in
                if let markerParentIDs, !markerParentIDs.contains(root.id) { return false }
                guard marker.position >= root.startTime && marker.position < root.endTime else { return false }
                let owner = roots.filter { marker.position >= $0.startTime && marker.position < $0.endTime }
                    .min { $0.endTime - $0.startTime < $1.endTime - $1.startTime }
                return owner?.id == root.id
            }
            let children = song.parts.filter { $0.parentRegionID == root.id }
            for marker in inside {
                consumed.insert(marker.id)
                if children.contains(where: { samePoint($0.startTime, marker.position) }) { continue }
                let nextMarker = inside.first { $0.position > marker.position + epsilon }?.position ?? root.endTime
                let nextRegion = children.filter { $0.startTime > marker.position + epsilon }.map(\.startTime).min() ?? root.endTime
                let containingEnd = children.filter { $0.startTime < marker.position && $0.endTime > marker.position }.map(\.endTime).min() ?? root.endTime
                let end = min(root.endTime, nextMarker, nextRegion, containingEnd)
                guard end > marker.position else { continue }
                song.parts.append(Part(id: UUID(), name: marker.name, startTime: marker.position, endTime: end, color: marker.color, parentRegionID: root.id))
            }
            // An interior marker subdivides an existing child instead of creating
            // two drawer entries playing the same interval.
            for child in children {
                if let split = inside.first(where: { $0.position > child.startTime + epsilon && $0.position < child.endTime }),
                   let index = song.parts.firstIndex(where: { $0.id == child.id }) {
                    song.parts[index].endTime = split.position
                }
            }
            for child in song.parts.filter({ $0.parentRegionID == root.id }).sorted(by: { $0.startTime < $1.startTime }) {
                linked.append(TimelineMarker(id: UUID(), name: child.name, position: child.startTime, color: child.color ?? 0xC7AB40, unifiedRegionID: root.id, sourceRegionID: child.id))
            }
        }
        // Prefer a drawer flag over an ordinary marker at the same point. Tempo
        // points live in a separate ruler and are intentionally independent.
        let candidates = linked + markers.filter { !consumed.contains($0.id) }
        let sorted = candidates.enumerated().sorted {
            $0.element.position == $1.element.position ? $0.offset < $1.offset : $0.element.position < $1.element.position
        }
        var result: [TimelineMarker] = []
        for entry in sorted {
            var marker = entry.element
            if let last = result.last, samePoint(last.position, marker.position) { continue }
            if marker.unifiedRegionID == nil { marker.name = String((marker.isSection ? marker.name.uppercased() : marker.name).prefix(marker.isSection ? TimelineMarker.maximumSectionNameLength : TimelineMarker.maximumNameLength)) }
            result.append(marker)
        }
        song.markers = result
        song.parts.sort { $0.startTime == $1.startTime ? $0.endTime > $1.endTime : $0.startTime < $1.startTime }
    }

}
#endif
