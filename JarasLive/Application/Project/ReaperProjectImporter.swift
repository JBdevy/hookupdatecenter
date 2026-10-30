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
        var effectBypass: [String] = []
        var effectEnvelopes: [Chunk] = []
        var pendingEffectBypass: [String] = []
        var lastEffect: Chunk?
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
    public struct VST3Request: Sendable {
        public var plugin: ExternalPlugin
        public var parameterIndices: Set<Int>
        public init(plugin: ExternalPlugin, parameterIndices: Set<Int> = []) { self.plugin = plugin; self.parameterIndices = parameterIndices }
    }
    public struct VST3Resolution: Sendable {
        public var plugin: ExternalPlugin
        public var parameterIDs: [Int: UInt32]
        public init(plugin: ExternalPlugin, parameterIDs: [Int: UInt32] = [:]) { self.plugin = plugin; self.parameterIDs = parameterIDs }
    }
    /// Keep warning templates separate from project/plugin names so the UI can
    /// use its selected language without translating user data or plugin IDs.
    private struct Warnings {
        var values = Set<String>()
        let localize: (String) -> String
        func errorDescription(_ error: Error) -> String {
            ProjectMigration.errorDescription(error, localize: localize)
        }
        mutating func insert(_ key: String, _ arguments: CVarArg...) {
            values.insert(arguments.isEmpty ? localize(key) : String(format: localize(key), arguments: arguments))
        }
    }
    private struct ImportedFX {
        var settings: NativeFXSettings?
        var envelopes: [TrackEnvelope] = []
    }
    /// REAPER's VST3 chunk has its own routing header and tagged state records.
    /// Verified against REAPER's GetNamedConfigParm("vst_chunk") using GainFixture:
    /// [byteCount:u32, kind:u32, bytes] kind 1 = processor, 0 = controller.
    /// The routing header and program-name trailer are not plugin component state.
    static func vst3States(_ lines: [String]) throws -> (component: String?, controller: String?) {
        guard !lines.isEmpty else { return (nil, nil) }
        var bytes = Data()
        for line in lines {
            guard let data = Data(base64Encoded: line), bytes.count + data.count <= 64 * 1024 * 1024 else { throw invalid("Invalid VST3 state encoding or size.") }
            bytes.append(data)
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw invalid("Truncated VST3 state.") }
            return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard try u32(4) == 0xfeed5eee else { throw invalid("Unsupported VST3 routing-state format.") }
        let inputs = try u32(8)
        guard inputs <= 4096 else { throw invalid("Invalid VST3 input count.") }
        let outputOffset = 12 + 8 * inputs, outputs = try u32(outputOffset)
        guard outputs <= 4096 else { throw invalid("Invalid VST3 output count.") }
        let lengthOffset = outputOffset + 4 + 8 * outputs
        let length = try u32(lengthOffset), begin = lengthOffset + 12, end = begin + length
        guard length <= 64 * 1024 * 1024, end <= bytes.count else { throw invalid("Truncated VST3 processor state.") }
        var cursor = begin, component: String?, controller: String?
        while cursor < end {
            let count = try u32(cursor), kind = try u32(cursor + 4)
            cursor += 8
            guard cursor + count <= end, kind == 0 || kind == 1 else { throw invalid("Unsupported VST3 state record.") }
            if count > 0 {
                let state = bytes.subdata(in: cursor..<cursor + count).base64EncodedString()
                if kind == 1 {
                    guard component == nil else { throw invalid("Duplicate VST3 processor state.") }
                    component = state
                } else {
                    guard controller == nil else { throw invalid("Duplicate VST3 controller state.") }
                    controller = state
                }
            }
            cursor += count
        }
        return (component, controller)
    }
    private static func importFX(_ chain: Chunk?, scope: String, resolve: ((VST3Request) throws -> VST3Resolution?)?, warnings: inout Warnings) throws -> ImportedFX {
        guard let chain else { return ImportedFX() }
        var result = ImportedFX(), settings = NativeFXSettings()
        if chain.children.contains(where: { $0.header.first == "CONTAINER" }) {
            warnings.insert("%@: REAPER FX containers are not supported; effects inside containers were not imported.", scope)
        }
        settings.inserted = []
        for node in chain.children where ["VST", "AU", "JS", "DX", "CLAP", "VIDEO_EFFECT"].contains(node.header.first ?? "") {
            do {
            let header = node.header
            guard header.first == "VST", header.count > 5,
                  header[1].hasPrefix("VST3:") || header[1].hasPrefix("VST3i:") else {
                let name = header.dropFirst().first ?? header.first ?? "FX"
                warnings.insert("%@: %@ was not imported; only VST3 effects are supported during REAPER migration.", scope, name)
                continue
            }
            guard let open = header[5].firstIndex(of: "{"), let close = header[5].firstIndex(of: "}"), open < close else {
                warnings.insert("%@: VST3 %@ has no class ID and was not imported.", scope, header[1]); continue
            }
            let rawID = String(header[5][header[5].index(after: open)..<close]).uppercased()
            guard rawID.count == 32, rawID.allSatisfy(\.isHexDigit) else { throw invalid("Invalid VST3 class ID.") }
            let classID = rawID
            let name = header[1].split(separator: ":", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? header[1]
            var plugin = ExternalPlugin(classID: classID, name: name, path: header[2], category: header[1].hasPrefix("VST3i:") ? "Instrument" : "Fx")
            plugin.bypassed = node.effectBypass.dropFirst().first == "1" || node.effectBypass.dropFirst(2).first == "1"
            var validState = true, available = false
            do {
                let state = try vst3States(node.notes)
                plugin.componentState = state.component; plugin.controllerState = state.controller
            } catch {
                warnings.insert("%@: %@ state was not imported: %@", scope, name, warnings.errorDescription(error))
                // Retain the exact plugin reference, but never silently play its
                // default preset when the saved preset could not be restored.
                plugin.bypassed = true; validState = false
            }
            var parameterIDs: [Int: UInt32] = [:]
            let indices = try Set(node.effectEnvelopes.map { envelope -> Int in
                guard envelope.header.count > 1 else { throw invalid("Missing VST3 automation parameter identity.") }
                let identity = envelope.header[1].split(separator: ":", omittingEmptySubsequences: false)
                guard (1...2).contains(identity.count), let index = Int(identity[0]), index >= 0,
                      identity.count == 1 || UInt32(identity[1]) != nil else {
                    throw invalid("Invalid VST3 automation parameter identity: " + envelope.header[1])
                }
                return index
            })
            do {
                if let found = try resolve?(VST3Request(plugin: plugin, parameterIndices: indices)) {
                    guard found.plugin.classID.uppercased() == plugin.classID else { throw invalid("VST3 resolver returned a different plugin class.") }
                    // The source preset, instance identity and bypass flag belong
                    // to this particular track/take, not the catalog entry.
                    plugin.path = found.plugin.path; plugin.category = found.plugin.category
                    parameterIDs = found.parameterIDs
                    available = validState
                } else {
                    plugin.bypassed = true
                    warnings.insert("%@: VST3 %@ was not found. Its saved state was retained, but the effect was not inserted. Install the same VST3 and import again.", scope, name)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                plugin.bypassed = true
                warnings.insert("%@: VST3 %@ could not be restored. Its reference was retained but the effect was not inserted: %@", scope, name, warnings.errorDescription(error))
            }
            if plugin.category.localizedCaseInsensitiveContains("midi") {
                warnings.insert("%@: %@ is categorized as a MIDI effect; VST3 MIDI-output transformations are not supported and were not migrated.", scope, name)
            }
            settings.externalPlugins = (settings.externalPlugins ?? []) + [plugin]
            if available { settings.inserted.append(plugin.effectKey) }
            for envelope in node.effectEnvelopes {
                let identity = envelope.header.count > 1 ? envelope.header[1].split(separator: ":").map(String.init) : []
                let parameter = identity.count == 2 ? UInt32(identity[1]) : identity.first.flatMap(Int.init).flatMap { parameterIDs[$0] }
                guard let parameter else {
                    warnings.insert("%@: %@ automation parameter %@ could not be identified; that envelope was not applied.", scope, name, identity.joined(separator: ":")); continue
                }
                let label = envelope.header.count > 5 ? envelope.header[5] : name + " · " + identity.joined(separator: ":")
                let target = AutomationTarget(.externalFX, plugin: plugin.id, parameter: parameter)
                if let imported = try importEnvelope(envelope, target: target, name: label, warnings: &warnings, scope: scope) { result.envelopes.append(imported) }
            }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER FX ignored: %@", warnings.errorDescription(error)) }
}
        if settings.externalPlugins?.isEmpty == false { result.settings = settings }
        return result
    }
    private static func importAutomation(_ node: Chunk, fx: [TrackEnvelope], take: Bool = false, offset: Double = 0, scope: String, warnings: inout Warnings) throws -> TrackAutomation? {
        var result = TrackAutomation()
        let mode = try node.integer("AUTOMODE")
        result.mode = [0: .trimRead, 1: .read, 2: .touch, 3: .write, 4: .latch][mode] ?? .read
        if mode > 4 { warnings.insert("%@: unsupported REAPER automation mode was imported as Read.", scope) }
        result.envelopes = fx
        for child in node.children {
            do {
            let key = child.header.first ?? ""
            let kind: AutomationTarget.Kind?
            switch key {
            case "VOLENV2": kind = take ? nil : .volume
            case "PANENV2": kind = take ? nil : .pan
            case "VOLENV": kind = take ? .volume : nil
            case "PANENV": kind = take ? .pan : nil
            case "MUTEENV": kind = .mute
            default: kind = nil
            }
            if let kind {
                if let envelope = try importEnvelope(child, target: AutomationTarget(kind), name: kind.rawValue.capitalized, warnings: &warnings, scope: scope) { result.envelopes.append(envelope) }
            } else if key.contains("ENV"), key != "PARMENV", key != "TEMPOENVEX" {
                let points = child.lines.filter { $0.first == "PT" }.count
                if points > 0 {
                    warnings.insert("%@: REAPER %@ automation is not supported and was not applied (%ld points).", scope, key, points)
                }
            }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER envelope ignored: %@", warnings.errorDescription(error)) }
}
        guard !result.envelopes.isEmpty else { return nil }
        for index in result.envelopes.indices {
            for point in result.envelopes[index].points.indices { result.envelopes[index].points[point].time += offset }
            if result.envelopes[index].points.first?.time ?? 0 < 0 {
                let boundary = result.envelopes[index].value(at: 0)
                result.envelopes[index].points.removeAll { $0.time < 0 }
                if result.envelopes[index].points.first?.time != 0 {
                    result.envelopes[index].points.insert(EnvelopePoint(time: 0, value: boundary), at: 0)
                }
            }
            // In CatLive hiding a track Env disables its playback. Keep active
            // imported envelopes visible so a hidden REAPER lane keeps sounding.
            if !take, result.envelopes[index].enabled { result.envelopes[index].visible = true }
        }
        result.lanesVisible = true
        return result
    }
    private struct ImportPoint {
        var time: Double, value: Double, shape: Int, tension: Double
    }
    private static func importEnvelope(_ node: Chunk, target: AutomationTarget, name: String, warnings: inout Warnings, scope: String) throws -> TrackEnvelope? {
        if !node.line("POOLEDENVINST").isEmpty || node.children.contains(where: { ["POOLEDENVINST", "AI"].contains($0.header.first ?? "") }) {
            warnings.insert("%@: %@ contains automation items; pooled automation items were not imported.", scope, name)
        }
        var points: [ImportPoint] = []
        for row in node.lines where row.first == "PT" {
            do {
            guard row.count >= 3 else { throw invalid("Invalid envelope point.") }
            let time = try number(row[1]), value = try number(row[2]), shape = row.count > 3 ? Int(row[3]) : 0
            guard let shape, (0...5).contains(shape) else { throw invalid("Invalid envelope point time or shape.") }
            let point = ImportPoint(time: time, value: value, shape: shape, tension: row.count > 7 ? try number(row[7]) : 0)
            if let last = points.last, last.time == time { points[points.count - 1] = point }
            else { points.append(point) }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER envelope point ignored: %@", warnings.errorDescription(error)) }
}
        guard !points.isEmpty else { return nil }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.time < $1.time }) else { throw invalid("Unsorted envelope points.") }
        let volume = target.kind == .volume, fader = try volume && node.integer("VOLTYPE") == 1
        let range: ClosedRange<Double> = volume ? 0...pow(10, 12.0 / 20) : target.kind == .pan ? -1...1 : 0...1
        if points.contains(where: { !range.contains($0.value) }) {
            warnings.insert("%@: %@ envelope exceeds the CatLive parameter range and was not applied.", scope, name); return nil
        }
        func normalized(_ value: Double) -> Double {
            if volume { return TrackEnvelope.normalizedGain(value) }
            if target.kind == .pan { return (value + 1) * 0.5 }
            if target.kind == .mute { return 1 - value }
            return value
        }
        let neutral: Double = volume ? TrackEnvelope.normalizedGain(1) : target.kind == .pan ? 0.5 : target.kind == .mute ? 0 : points[0].value
        var result = TrackEnvelope(target: target, name: name, defaultValue: neutral)
        result.enabled = try node.integer("ACT", default: 1) != 0
        result.visible = try node.integer("VIS", default: 1) != 0
        result.armed = try node.integer("ARM") != 0
        if volume { result.valueScale = .linearGain }
        let shapes: [EnvelopeShape] = [.linear, .square, .smooth, .fastStart, .fastEnd]
        // REAPER fader scaling, checked against its ScaleFromEnvelopeMode oracle.
        let faderGain = pow(10, 12.0 / 20) / 2
        func toFader(_ value: Double) -> Double { pow((sqrt(1 + 4 * value / faderGain) - 1) / 2, 1.0 / 3) }
        func fromFader(_ value: Double) -> Double { let q = value * value * value; return faderGain * q * (1 + q) }
        func domain(_ value: Double) -> Double { fader ? toFader(value) : value }
        func rawValue(_ index: Int, _ fraction: Double) -> Double {
            let a = points[index], b = points[index + 1], av = domain(a.value), bv = domain(b.value)
            let value: Double
            if a.shape < 5 { value = av + (bv - av) * shapes[a.shape].interpolate(fraction) }
            else {
                // Cubic cardinal segment, tension-adjusted as used by REAPER.
                let previous = index > 0 ? points[index - 1] : a
                let next = index + 2 < points.count ? points[index + 2] : b
                let span = b.time - a.time, tension = min(1, max(-1, a.tension))
                var x1 = 0.25, x2 = 0.75
                var y1 = av + (bv - domain(previous.value)) / (b.time - previous.time) * span * 0.25
                var y2 = bv - (domain(next.value) - av) / (next.time - a.time) * span * 0.25
                x1 += tension * (tension > 0 ? 1 - x1 : x1)
                x2 += tension * (tension > 0 ? 1 - x2 : x2)
                y1 -= tension * (tension > 0 ? y1 - av : bv - y1)
                y2 -= tension * (tension > 0 ? y2 - av : bv - y2)
                y1 = min(domain(range.upperBound), max(domain(range.lowerBound), y1))
                y2 = min(domain(range.upperBound), max(domain(range.lowerBound), y2))
                func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
                    let u = 1 - t
                    return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3
                }
                var low = 0.0, high = 1.0
                for _ in 0..<36 { let mid = (low + high) * 0.5; if cubic(mid, 0, x1, x2, 1) < fraction { low = mid } else { high = mid } }
                value = cubic((low + high) * 0.5, av, y1, y2, bv)
            }
            return fader ? fromFader(value) : value
        }
        for index in points.indices {
            let point = points[index]
            let resample = index + 1 < points.count && point.shape != 1 && (fader || point.shape == 5)
            result.points.append(EnvelopePoint(time: point.time, value: normalized(point.value), shape: resample ? .linear : shapes[min(4, point.shape)]))
            guard resample else { continue }
            let end = points[index + 1]
            func sample(_ a: Double, _ av: Double, _ b: Double, _ bv: Double, _ depth: Int) throws {
                var error = 0.0
                for weight in [0.25, 0.5, 0.75] {
                    let exact = rawValue(index, a + (b - a) * weight), estimate = av + (bv - av) * weight
                    error = max(error, abs(exact - estimate))
                }
                if error > 0.00001, depth < 16, (b - a) * (end.time - point.time) > 0.000001 {
                    let middle = (a + b) * 0.5, mv = rawValue(index, middle)
                    try sample(a, av, middle, mv, depth + 1)
                    result.points.append(EnvelopePoint(time: point.time + (end.time - point.time) * middle, value: normalized(mv)))
                    guard result.points.count < 200_000 else { throw invalid("Envelope contains too many resampled points.") }
                    try sample(middle, mv, b, bv, depth + 1)
                }
            }
            try sample(0, point.value, 1, end.value, 0)
        }
        return result
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
    private static func parse(_ text: String, report: ((Error) -> Void)? = nil) throws -> Chunk {
        var stack: [Chunk] = [], root: Chunk?, count = 0
        let keys: Set<String> = ["POOLEDENVINST", "ACT", "VIS", "ARM", "VOLTYPE", "AUTOMODE", "BYPASS", "FX", "IPHASE", "NAME", "TEMPO", "MARKER", "PT", "VOLPAN", "MUTESOLO", "ISBUS", "PEAKCOL", "POSITION", "LENGTH", "TAKEVOLPAN", "SOFFS", "PLAYRATE", "MUTE", "FADEIN", "FADEOUT", "CHANMODE", "LOOP", "FILE", "TAKE", "SEL", "ALLTAKES", "STARTPOS", "MODE", "MASTER_VOLUME", "MASTERMUTESOLO", "AUXRECV", "MAINSEND", "PANMODE", "SM", "PITCHENV", "STARTTIME", "FRAMERATE", "SEND", "USERDATA", "HASDATA", "IGNTEMPO", "POOLEDEVTS", "E", "e", "Em", "em"]
        for raw in text.split(whereSeparator: \.isNewline) {
            do {
            count += 1
            if count % 1024 == 0 { try Task.checkCancellation() }
            guard count <= 2_000_000 else { throw invalid("Project is too large.") }
            let line = raw.drop(while: \.isWhitespace)
            if line.isEmpty { continue }
            if stack.last?.header.first == "VST", line != ">", !line.hasPrefix("<") {
                stack.last?.notes.append(String(line)); continue
            }
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
                    if ["FXCHAIN", "TAKEFX", "MASTERFXLIST", "MASTERFXCHAIN"].contains(parent.header.first ?? "") {
                        if header.first == "PARMENV" { parent.lastEffect?.effectEnvelopes.append(chunk) }
                        else if ["VST", "AU", "JS", "DX", "CLAP", "VIDEO_EFFECT"].contains(header.first ?? "") {
                            chunk.effectBypass = parent.pendingEffectBypass
                            parent.lastEffect = chunk
                        }
                    }
                    if ["X", "x", "Xm", "xm"].contains(header[0]), parent.header == ["SOURCE", "MIDI"] { parent.midiEvents.append(header) }
                }
                else {
                    guard root == nil else { throw invalid("Multiple project roots.") }
                    guard header.first == "REAPER_PROJECT" else { throw invalid("Incomplete or invalid .rpp project.") }
                    root = chunk
                }
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
                    guard let item = stack.last, item.header.first == "ITEM" else { throw invalid("Invalid take nesting.") }
                    let take = Chunk(["TAKE_INLINE"] + row.dropFirst())
                    item.children.append(take); stack.append(take)
                } else {
                    parent.lines.append(row)
                    if key == "BYPASS" { parent.pendingEffectBypass = row }
                    if ["E", "e", "Em", "em"].contains(key), parent.header == ["SOURCE", "MIDI"] { parent.midiEvents.append(row) }
                }
            }

            } catch is CancellationError { throw CancellationError() }
            catch {
                guard let report else { throw error }; report(error)
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("<") { break }
            }
}
        guard let root, root.header.first == "REAPER_PROJECT" else { throw invalid("Incomplete or invalid .rpp project.") }
        if !stack.isEmpty {
            let error = invalid("Incomplete project: recovered the available arrangement.")
            guard let report else { throw error }; report(error)
        }
        return root
    }
    public static func read(_ source: URL, resolveVST3: ((VST3Request) throws -> VST3Resolution?)? = nil,
                            localizeWarning: @escaping (String) -> String = { $0 }) throws -> ProjectMigration.Result {
        guard source.pathExtension.lowercased() == "rpp" else { throw invalid("Select a .rpp project.") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 * 1024 else { throw invalid("Invalid project size.") }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw invalid("Invalid text encoding.") }
        var warnings = Warnings(localize: localizeWarning)
        let root = try parse(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")), report: { warnings.insert("%@", warnings.errorDescription($0)) })
        // REAPER POSITION values are seconds from the physical start of the
        // arrangement. PROJOFFS/measure numbering label the ruler; they do not
        // move that boundary. Keep this start at CatLive 00:00.
        var hookState: [String: [String: String]] = [:]
        for section in root.child("EXTSTATE")?.children ?? [] where ["CHATGPT_REGION_PLAYLIST", "VS_HOOK_MULTILOOPS"].contains(section.header.first ?? "") {
            var values: [String: String] = [:]
            for row in section.lines where row.count >= 2 { values[row[0]] = row.dropFirst().joined(separator: " ") }
            for binary in section.children where binary.header.first == "BIN" && binary.header.count == 2 {
                if let data = Data(base64Encoded: binary.notes.joined()), let value = String(data: data, encoding: .utf8) {
                    values[binary.header[1]] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                } else { warnings.insert("Invalid VS Hook metadata was ignored; arrangement data was retained.") }
            }
            hookState[section.header[0]] = values
        }
        func recovered<T>(_ description: String, _ fallback: T, _ operation: () throws -> T) throws -> T {
            do { return try operation() }
            catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("%@: %@", warnings.localize(description), warnings.errorDescription(error)); return fallback }
        }
        var hook = VSHookProjectMigration(state: hookState)
        var project = Project.empty(name: source.deletingPathExtension().lastPathComponent)
        project.importedTimeline = true
        var song = project.songs[0]
        song.tracks = []; song.parts = []; song.markers = []; song.timeSettings = ProjectTimeSettings()
        song.bpm = try recovered("REAPER project setting ignored", 120.0) { try root.number("TEMPO", default: 120) }
        song.beatsPerBar = try recovered("REAPER project setting ignored", 4) { try root.integer("TEMPO", 2, default: 4) }
        song.beatUnit = try recovered("REAPER project setting ignored", 4) { try root.integer("TEMPO", 3, default: 4) }
        if !TimelineTempo.bpmRange.contains(song.bpm) { warnings.insert("Invalid REAPER tempo ignored; 120 BPM was used."); song.bpm = 120 }
        if !(1...32).contains(song.beatsPerBar ?? 4) || ![1, 2, 4, 8, 16, 32].contains(song.beatUnit ?? 4) {
            warnings.insert("Invalid REAPER time signature ignored; 4/4 was used."); song.beatsPerBar = 4; song.beatUnit = 4
        }
        var ignoredItems = 0
        let midiTempo = try MIDITempoMap(root, report: { warnings.insert("%@", warnings.errorDescription($0)) })
        var midiPools: [String: Chunk] = [:]
        func collectPools(_ chunk: Chunk) {
            if chunk.header == ["SOURCE", "MIDI"], let pool = chunk.value("POOLEDEVTS"), !chunk.midiEvents.isEmpty { midiPools[pool] = chunk }
            for child in chunk.children { collectPools(child) }
        }
        collectPools(root)
        let unsupported = "REAPER sends and advanced playback settings are not converted. Review the migrated mix."
        func limitedVolume(_ value: Double) -> Double {
            let limited = min(pow(10, 12.0 / 20), max(0, value))
            if limited != value { warnings.insert("REAPER mixer volumes above +12 dB were limited to the CatLive mixer range.") }
            return limited
        }
        project.masterVolume = limitedVolume(try recovered("REAPER project setting ignored", 1.0) { try root.number("MASTER_VOLUME", default: 1) })
        project.masterPan = try recovered("REAPER project setting ignored", 0.0) { try root.number("MASTER_VOLUME", 2) }
        project.masterMute = try recovered("REAPER project setting ignored", 0) { try root.integer("MASTERMUTESOLO") } & 1 != 0
        let masterFX = try importFX(root.child("MASTERFXLIST") ?? root.child("MASTERFXCHAIN"), scope: "Master", resolve: resolveVST3, warnings: &warnings)
        project.masterFX = masterFX.settings
        do { project.masterAutomation = try importAutomation(root, fx: masterFX.envelopes, scope: "Master", warnings: &warnings) }
        catch { warnings.insert("Master automation ignored: %@", warnings.errorDescription(error)) }
        if try recovered("REAPER project setting ignored", 1.0) { try root.number("PLAYRATE", default: 1) } != 1 { warnings.insert(unsupported) }
        let base = source.deletingLastPathComponent()
        let mediaRoot = "Stems"
        var importedNames = MediaFileNames(directory: nil)
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
            let result = ProjectMigration.Media(relativePath: (projection ? "Videos" : mediaRoot) + "/" + importedNames.allocate(name), source: found)
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
            do {
            try Task.checkCancellation()
            var track = Track(id: UUID(), name: node.value("NAME").flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(song.tracks.count + 1)", role: .other)
            do { track.volume = limitedVolume(try node.number("VOLPAN", default: 1)) }
            catch { track.volume = 1; warnings.insert("%@: invalid mixer setting ignored: %@", track.name, warnings.errorDescription(error)) }
            do { track.pan = try node.number("VOLPAN", 2) }
            catch { track.pan = 0; warnings.insert("%@: invalid mixer setting ignored: %@", track.name, warnings.errorDescription(error)) }
            do { track.mute = try node.number("MUTESOLO") != 0 }
            catch { track.mute = false; warnings.insert("%@: invalid mixer setting ignored: %@", track.name, warnings.errorDescription(error)) }
            do { track.solo = try node.number("MUTESOLO", 2) != 0 }
            catch { track.solo = false; warnings.insert("%@: invalid mixer setting ignored: %@", track.name, warnings.errorDescription(error)) }
            track.color = color(node.value("PEAKCOL"))
            track.parentTrackID = folders.last
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
            var delta = (try? node.integer("ISBUS", 2)) ?? 0
            if !(-1000...1).contains(delta) || delta < -folders.count {
                warnings.insert("%@: invalid folder structure was ignored.", track.name); delta = 0
            }
            if delta > 0 {
                if special != nil { warnings.insert("%@: special-track folder membership was ignored.", track.name); delta = 0 }
                else { folders.append(track.id) }
            }
            do { track.phaseInverted = try node.integer("IPHASE") != 0 }
            catch { track.phaseInverted = false; warnings.insert("%@: invalid mixer setting ignored: %@", track.name, warnings.errorDescription(error)) }
            let importedFX = try importFX(node.child("FXCHAIN"), scope: track.name, resolve: resolveVST3, warnings: &warnings)
            track.fx = importedFX.settings
            if node.value("FX") == "0", let plugins = track.fx?.externalPlugins {
                track.fx?.externalPlugins = plugins.map { var plugin = $0; plugin.bypassed = true; return plugin }
            }
            do { track.automation = try importAutomation(node, fx: importedFX.envelopes, scope: track.name, warnings: &warnings) }
            catch { warnings.insert("%@: automation ignored: %@", track.name, warnings.errorDescription(error)) }
            if !node.line("AUXRECV").isEmpty { warnings.insert(unsupported) }
            for item in node.children where item.header.first == "ITEM" {
            do {
                let start = try item.number("POSITION"), duration = try item.number("LENGTH")
                guard duration > 0, (start + duration).isFinite else { throw invalid("Invalid item position or length.") }
                if start < 0 { ignoredItems += 1; continue }
                // Audio/MIDI tracks can expose alternate takes as stacked items.
                // Special projection tracks have one lane, so importing all
                // REAPER takes from the same item would create invalid overlaps.
                var takes = item.children.filter { ["TAKE", "TAKE_INLINE"].contains($0.header.first ?? "") }
                if item.child("SOURCE") != nil || takes.isEmpty { takes.insert(item, at: 0) }
                let activeTake = takes.first { $0 !== item && ($0.header.contains("SEL") || $0.value("SEL") == "1") } ?? takes.first
                if special != nil, let activeTake {
                    if takes.count > 1 { warnings.insert("%@: alternate REAPER takes ignored on this single-lane special track; the active take was imported.", track.name) }
                    takes = [activeTake]
                }
                let playAllTakes = try item.integer("ALLTAKES") != 0
                for take in takes {
            do {
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
                        clip.muted = try item.number("MUTE") != 0 || (!playAllTakes && take !== activeTake)
                        if track.clips.isEmpty { track.timecode = settings }
                    } else if let filename = source?.value("FILE"), special == .video || special.isTeleprompter {
                        let ref = try reference(filename, projection: true)
                        clip.audioFile = AudioFile(path: ref.relativePath)
                        clip.sourceOffset = try take.number("SOFFS")
                        clip.playbackRate = try take.number("PLAYRATE", default: 1)
                    } else if special.isText {
                        let text = item.child("NOTES")?.notes.joined(separator: "\n") ?? take.child("NOTES")?.notes.joined(separator: "\n") ?? take.value("NAME") ?? ""
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
                let takeGain: Double, takePan: Double
                if !take.line("TAKEVOLPAN").isEmpty {
                    takeGain = try item.number("VOLPAN", default: 1) * take.number("TAKEVOLPAN", 2, default: 1)
                    takePan = try take.number("TAKEVOLPAN")
                } else {
                    takeGain = try take.number("VOLPAN", default: item.number("VOLPAN", default: 1)) * take.number("VOLPAN", 3, default: 1)
                    takePan = try take.number("VOLPAN", 2)
                }
                clip.gain = abs(takeGain)
                clip.phaseInverted = takeGain < 0 ? true : nil
                clip.pan = takePan
                clip.muted = try item.number("MUTE") != 0 || (!playAllTakes && take !== activeTake)
                clip.fadeIn = try item.number("FADEIN", 2)
                clip.fadeOut = try item.number("FADEOUT", 2)
                let mode = try take.integer("CHANMODE")
                clip.channelMode = [0: 0, 2: 3, 3: 1, 4: 2][mode] ?? 0
                if try ![0, 2, 3, 4].contains(mode) || !take.line("SM").isEmpty { warnings.insert(unsupported) }
                let takeFX = try importFX(take.child("TAKEFX"), scope: track.name + " / " + clip.name, resolve: resolveVST3, warnings: &warnings)
                clip.fx = takeFX.settings
                let hasTakeInstrument = clip.fxBypassed != true && (clip.fx?.externalPlugins ?? []).contains {
                    $0.category.contains("Instrument") && !$0.bypassed && clip.fx?.inserted.contains($0.effectKey) == true
                }
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
                    if !hasTakeInstrument, clip.fx?.externalPlugins?.isEmpty == false {
                        warnings.insert("%@ / %@: MIDI take VST3 effects and their saved states were retained, but no active take instrument generates audio for them. MIDI-only transformations are not supported; these take effects are not applied.", track.name, clip.name)
                    }
                    if !hasTakeInstrument, !(track.fx?.externalPlugins ?? []).contains(where: { $0.category.contains("Instrument") && track.fx?.inserted.contains($0.effectKey) == true }) {
                        warnings.insert("MIDI notes were imported. Choose an instrument in CatLive; no compatible VST3 instrument was inserted on this track or take.")
                    }
                } else {
                    // Do not create silent placeholders or interrupt opening for
                    // empty/unsupported takes. Special media tracks are handled above.
                    continue
                }
                var takeAutomation = try importAutomation(take, fx: takeFX.envelopes, take: true, offset: clip.sourceOffset, scope: track.name + " / " + clip.name, warnings: &warnings)
                if clip.midi != nil, var automation = takeAutomation {
                    // MIDI notes were flattened into timeline seconds above.
                    // REAPER take envelopes use item-relative time multiplied
                    // by take rate (unaffected by media SOFFS or source loops).
                    // Flatten this clock to match the reset clip rate of one.
                    let rate = try take.number("PLAYRATE", default: 1)
                    for envelope in automation.envelopes.indices {
                        for point in automation.envelopes[envelope].points.indices {
                            automation.envelopes[envelope].points[point].time /= rate
                        }
                    }
                    takeAutomation = automation
                    if !hasTakeInstrument {
                        warnings.insert("%@ / %@: MIDI take automation was retained, but cannot be applied independently through a shared track instrument. An active VST3 instrument on the take is required.", track.name, clip.name)
                    }
                }
                clip.automation = takeAutomation
                track.clips.append(clip)

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER take ignored: %@", warnings.errorDescription(error)) }
}

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER item ignored: %@", warnings.errorDescription(error)) }
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
                // REAPER permits overlaps even between distinct items, not only
                // alternate takes. Recover each supported projection layer in
                // timeline order, without moving or trimming accepted content.
                // Equal starts keep source order; text and media remain independent.
                let order = track.clips.indices.sorted {
                    track.clips[$0].startTime == track.clips[$1].startTime ? $0 < $1 :
                        track.clips[$0].startTime < track.clips[$1].startTime
                }
                var ends = [-Double.infinity, -Double.infinity]
                var rejected = Set<Int>()
                for index in order {
                    let clip = track.clips[index]
                    let layer = track.kind.isTeleprompter && clip.isProjectionMedia ? 1 : 0
                    if ends[layer] > clip.startTime + 0.0000001 {
                        rejected.insert(index)
                        warnings.insert("%@: item \"%@\" at %.6f s was ignored because it overlaps another item on the same special-track layer. The rest of the project was imported.", track.name, clip.name, clip.startTime)
                    } else { ends[layer] = clip.startTime + clip.duration }
                }
                track.clips = track.clips.enumerated().compactMap { rejected.contains($0.offset) ? nil : $0.element }
            }
            song.tracks.append(track)
            if delta < 0 { folders.removeLast(-delta) }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER track ignored: %@", warnings.errorDescription(error)) }
}
        var regionStarts: [String: (Double, String, UInt32?)] = [:]
        for row in root.lines where row.first == "MARKER" {
            do {
            guard row.count >= 5, let flags = Int(row[4]) else { throw invalid("Invalid marker.") }
            let position = try number(row[2]), title = row[3].isEmpty ? "Marker " + row[1] : row[3]
            let tint = color(row.count > 5 ? row[5] : nil)
            if flags & 1 != 0 {
                if let begin = regionStarts.removeValue(forKey: row[1]) {
                    guard position > begin.0 else { throw invalid("Invalid region length.") }
                    guard position > 0 else { continue }
                    let part = Part(id: UUID(), name: begin.1, startTime: max(0, begin.0), endTime: position, color: begin.2)
                    song.parts.append(part)
                    hook.regionIDs[row[1]] = part.id
                } else { regionStarts[row[1]] = (position, row[3].isEmpty ? "Region " + row[1] : row[3], tint) }
            } else {
                guard position >= 0 else { continue }
                let marker = TimelineMarker(id: UUID(), name: title, position: position, color: tint ?? 0xC7AB40)
                song.markers?.append(marker)
                hook.sourceMarkers.append(.init(number: row[1], marker: marker))
            }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER marker ignored: %@", warnings.errorDescription(error)) }
}
        if !regionStarts.isEmpty {
            warnings.insert("Incomplete REAPER regions were retained as start markers.")
            for (_, begin) in regionStarts where begin.0 >= 0 {
                song.markers?.append(TimelineMarker(id: UUID(), name: String(begin.1.prefix(TimelineMarker.maximumNameLength)), position: begin.0, color: begin.2 ?? 0xC7AB40))
            }
        }
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
            guard original.position >= 0 else { continue }
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
            var initialTempo: TimelineMarker?
            for row in tempo.lines where row.first == "PT" {
            do {
                guard row.count >= 3 else { throw invalid("Invalid tempo point.") }
                let position = try number(row[1]), bpm = try number(row[2])
                if TimelineTempo.bpmRange.contains(bpm) {
                    let signature = row.count > 4 ? Int(row[4]) ?? 0 : 0
                    if signature != 0 { song.beatsPerBar = signature & 0xffff; song.beatUnit = signature >> 16 }
                    let meterBeats = song.meterBeats, meterUnit = song.meterUnit
                    let marker = TimelineMarker(id: UUID(), name: String(format: "%g", bpm), position: max(0, position), color: 0xAAAAAA, tempoBPM: bpm, tempoBeats: meterBeats, tempoUnit: meterUnit, tempoTimebase: .global, tempoReferenceBPM: bpm)
                    if position < 0 { initialTempo = marker } else { song.markers?.append(marker) }
                } else { warnings.insert("Tempo points outside the CatLive tempo range were omitted; item positions in seconds are unchanged.") }
                if row.count > 3 && row[3] != "1" { warnings.insert("REAPER tempo ramps were imported as discrete tempo points; item positions in seconds are unchanged.") }

            } catch is CancellationError { throw CancellationError() }
            catch { warnings.insert("REAPER tempo point ignored: %@", warnings.errorDescription(error)) }
}
            if let initialTempo, song.markers?.contains(where: { $0.isTempo && $0.position == 0 }) != true {
                song.markers?.append(initialTempo)
            }
        }
        // The initial meter is independent from later tempo/time-signature changes.
        song.beatsPerBar = song.meterBeats; song.beatUnit = song.meterUnit
        let contentEnd = max(song.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0,
                             song.parts.map(\.endTime).max() ?? 0, song.markers?.map(\.position).max() ?? 0)
        song.duration = max(1, contentEnd)
        // A region-free REAPER timeline stays region-free in CatLive.
        project.songs = [song]
        var hookWarnings = Set<String>()
        hook.apply(to: &project, warnings: &hookWarnings)
        for warning in hookWarnings { warnings.insert(warning) }
        if ignoredItems > 0 { warnings.insert("%ld REAPER items before the project start were ignored.", ignoredItems) }
        project.orderSpecialTracks()
        try project.validate()
        return ProjectMigration.Result(project: project, media: media.values.filter { entry in song.tracks.contains { track in track.clips.contains { $0.audioFile?.path == entry.relativePath } } }.sorted { $0.relativePath < $1.relativePath }, warnings: warnings.values.sorted())
    }
    /// RPP MIDI uses source quarter notes. Integrate the original tempo map
    /// before flattening into the imported free timeline, including linear ramps.
    private struct MIDITempoMap {
        struct Point { let time: Double; let bpm: Double; let linear: Bool; var beat: Double = 0 }
        let points: [Point]
        init(_ root: Chunk, report: (Error) -> Void) throws {
            let initial = (try? root.number("TEMPO", default: 120)) ?? 120
            guard initial > 0 else { throw invalid("Invalid MIDI project tempo.") }
            var values: [Point] = []
            for row in root.child("TEMPOENVEX")?.lines ?? [] where row.first == "PT" {
                do {
                guard row.count >= 3 else { throw invalid("Invalid tempo point.") }
                let time = try number(row[1]), bpm = try number(row[2])
                guard bpm > 0 else { throw invalid("Invalid MIDI tempo point.") }
                values.append(Point(time: time, bpm: bpm, linear: row.count > 3 && row[3] == "0"))

                } catch { report(error) }
}
            values.insert(Point(time: min(0, values.map(\.time).min() ?? 0), bpm: initial, linear: false), at: 0)
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
    private static func inlineMIDI(_ source: Chunk, warnings: inout Warnings) throws -> MIDISource {
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
                                 tempo: MIDITempoMap, pools: [String: Chunk], warnings: inout Warnings) throws -> MIDIItem {
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
