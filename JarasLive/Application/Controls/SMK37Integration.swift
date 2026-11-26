import Foundation

/// Private SysEx shared with the CatLive controller firmware. The ordinary
/// MIDI path stays available until the selected device answers our handshake.
public enum SMK37Protocol {
    public static let signature: [UInt8] = [0xf0, 0x7d, 0x43, 0x4c, 0x53, 1]
    public struct Frame: Equatable, Sendable {
        public let command: UInt8
        public let payload: [UInt8]
    }
    public static func encode(_ command: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        guard command < 128, payload.count <= 87, payload.allSatisfy({ $0 < 128 }) else { return [] }
        var bytes = signature + [command] + payload
        bytes.append(UInt8((128 - (bytes.dropFirst().reduce(0) { $0 + Int($1) } & 127)) & 127))
        bytes.append(0xf7)
        return bytes
    }
    public static func decode(_ bytes: [UInt8]) -> Frame? {
        guard (9...96).contains(bytes.count), bytes.starts(with: signature), bytes.last == 0xf7,
              bytes.dropFirst().dropLast().allSatisfy({ $0 < 128 }),
              bytes.dropFirst().dropLast().reduce(0, { $0 + Int($1) }) & 127 == 0 else { return nil }
        return Frame(command: bytes[6], payload: Array(bytes[7..<(bytes.count - 2)]))
    }
    public static func text(_ value: String) -> [UInt8] {
        let ascii = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "pt_BR"))
        return Array(ascii.unicodeScalars.map { (32...126).contains($0.value) ? UInt8($0.value) : 32 }.prefix(64))
    }
    public static func color(_ rgb: UInt32) -> [UInt8] {
        stride(from: 20, through: 0, by: -4).map { UInt8((rgb >> $0) & 15) }
    }
    public static func preset(_ index: Int, name: String, rgb: UInt32) -> [UInt8] {
        guard (0..<6).contains(index) else { return [] }
        return encode(0x10, [UInt8(index)] + color(rgb) + text(name))
    }
    public static func pad(_ index: Int, preset: Int, name: String, rgb: UInt32) -> [UInt8] {
        guard (0..<6).contains(preset), (0..<16).contains(index) else { return [] }
        return encode(0x11, [UInt8(preset), UInt8(index)] + color(rgb) + text(name))
    }
    public static func selection(preset: Int, pad: Int?, serial: UInt8, active: UInt16) -> [UInt8] {
        guard (0..<6).contains(preset), pad == nil || (0..<16).contains(pad!) else { return [] }
        return encode(0x12, [UInt8(preset), pad.map(UInt8.init) ?? 127, serial & 127,
                             UInt8(active & 127), UInt8((active >> 7) & 127), UInt8(active >> 14)])
    }
    public static func action(_ label: String, rgb: UInt32 = 0xeeeeee) -> [UInt8] {
        encode(0x13, color(rgb) + text(label))
    }
    public static func transport(paused: Bool, recording: Bool, looping: Bool, auto: Bool, preview: Bool, playing: Bool, queued: Bool = false) -> [UInt8] {
        let flags = (paused ? 1 : 0) | (recording ? 2 : 0) | (looping ? 4 : 0) |
                    (auto ? 8 : 0) | (preview ? 16 : 0) | (playing ? 32 : 0) | (queued ? 64 : 0)
        return encode(0x14, [UInt8(flags)])
    }
    public static func loop(_ name: String, rgb: UInt32) -> [UInt8] {
        encode(0x15, color(rgb) + text(name))
    }
    public static func fadeout(active: Bool, remaining: Double, duration: Double) -> [UInt8] {
        guard active, remaining.isFinite, duration.isFinite, duration > 0 else { return encode(0x16, [0, 0, 0]) }
        let seconds = min(5, max(0, remaining)), fraction = min(1, max(0, remaining / duration))
        return encode(0x16, [1, UInt8(ceil(seconds * 10 - 0.000001)), UInt8((fraction * 127).rounded())])
    }
    /// Fixed five-row viewport. Blank edge rows keep the selection centered.
    public static func window(_ names: [String], selected: Int) -> [String] {
        guard names.indices.contains(selected) else { return Array(repeating: "", count: 5) }
        return (-2...2).map { names.indices.contains(selected + $0) ? names[selected + $0] : "" }
    }
    public static func navigation(kind: Int, rows: [String]) -> [UInt8] {
        guard (1...3).contains(kind), rows.count == 5 else { return [] }
        var data = [UInt8(kind)]
        for (index, row) in rows.enumerated() {
            let limit = index == 2 ? 24 : 14
            var bytes = text(row)
            if bytes.count > limit { bytes = Array(bytes.prefix(limit - 3)) + [46, 46, 46] }
            data.append(UInt8(bytes.count)); data += bytes
        }
        return encode(0x17, data)
    }
    public static func playlist(_ name: String) -> [UInt8] {
        var bytes = text(name)
        if bytes.count > 36 { bytes = Array(bytes.prefix(33)) + [46,46,46] }
        return encode(0x19, bytes)
    }
    public static func songTitles(playing: String, queued: String) -> [UInt8] {
        var payload: [UInt8] = []
        for value in [playing, queued] {
            var bytes = text(value)
            if bytes.count > 36 { bytes = Array(bytes.prefix(33)) + [46,46,46] }
            payload.append(UInt8(bytes.count)); payload += bytes
        }
        return encode(0x1a, payload)
    }
    public static func playback(position: Double, start: Double, end: Double) -> [UInt8] {
        guard position.isFinite, start.isFinite, end.isFinite, end > start else { return encode(0x18, Array(repeating: 0, count: 8)) }
        let duration = end - start, elapsed = min(duration, max(0, position - start))
        // 200 steps match the physical display and avoid needless full-page redraws.
        let progress = Int((elapsed / duration * 200).rounded())
        let seconds = Int(min(2097151, elapsed)), total = Int(min(2097151, duration))
        var payload: [UInt8] = [UInt8(progress & 127), UInt8(progress >> 7)]
        for value in [seconds, total] {
            payload.append(UInt8(value & 127))
            payload.append(UInt8((value >> 7) & 127))
            payload.append(UInt8((value >> 14) & 127))
        }
        return encode(0x18, payload)
    }
    public static func padBusLabel(gain: Double) -> String {
        guard gain.isFinite, gain > 0 else { return "VINHETAS FX -INF dB" }
        return "VINHETAS FX " + String(format: "%.1f dB", locale: Locale(identifier: "en_US_POSIX"), min(0, 20 * log10(gain)))
    }
    /// The dedicated pad bus fader reaches unity, never gain above 0 dB.
    public static func padBusGain(_ value: UInt8) -> Double {
        value == 0 ? 0 : pow(10, (-60 + Double(min(127, value)) / 127 * 60) / 20)
    }
    public static func isDeviceName(_ name: String) -> Bool {
        let normalized = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("SMK37")
    }
}

public enum SMK37Action: Equatable, Sendable {
    case record, preview, scrollTracks(Int), queuedParts(Int), auto
    case playStop, pause, repeatLoop, songs(Int), currentParts(Int), confirm
    case previewPage(Int), playlist(Int), fadeout(Bool), padBusVolume(UInt8)
    /// SDK order is upper row (0...7), then lower row (8...15).
    public static func pad(_ index: Int) -> Self? {
        switch index {
        case 0: return .record
        case 2: return .preview
        case 3: return .scrollTracks(-1)
        case 4: return .scrollTracks(1)
        case 5: return .queuedParts(-1)
        case 6: return .queuedParts(1)
        case 7: return .auto
        case 8: return .playStop
        case 9: return .pause
        case 10: return .repeatLoop
        case 11: return .songs(-1)
        case 12: return .songs(1)
        case 13: return .currentParts(-1)
        case 14: return .currentParts(1)
        case 15: return .confirm
        default: return nil
        }
    }
}

/// State belongs to one enabled input/output pair, never the audio callback.
/// Press ownership survives bank/channel changes, so a release cannot stop
/// another pad or leave a gated sound playing in the previous preset.
public struct SMK37Session {
    public enum Event: Equatable, Sendable {
        case connected
        case preset(Int)
        case padDown(token: UUID, preset: Int, pad: Int)
        case padUp(token: UUID)
        case action(SMK37Action)
    }
    public private(set) var connected = false
    public private(set) var mode = 0
    public private(set) var preset = 0
    public private(set) var channel = 0
    private var lastResponse = -Double.infinity
    private var held: [Int: UUID] = [:]
    private var down = Set<Int>()
    public init() {}
    public mutating func selectHostPreset(_ index: Int) {
        if (0..<6).contains(index) { preset = index }
    }
    public mutating func close() -> [Event] {
        let releases = held.values.map { Event.padUp(token: $0) }
        held.removeAll(); down.removeAll(); connected = false; lastResponse = -.infinity
        return releases
    }
    public mutating func expire(at time: Double) -> [Event] {
        connected && time - lastResponse >= 3 ? close() : []
    }
    public mutating func receive(_ bytes: [UInt8], at time: Double) -> [Event] {
        guard let frame = SMK37Protocol.decode(bytes) else { return [] }
        let p = frame.payload
        if frame.command == 0x41, p.count == 3, p[0] < 6, p[1] < 16, p[2] < 3 {
            let wasConnected = connected
            var result: [Event] = []
            if connected && mode != Int(p[2]) { result = close() }
            connected = true; lastResponse = time; preset = Int(p[0]); channel = Int(p[1]); mode = Int(p[2])
            if !wasConnected { result += [.connected] }
            return result
        }
        guard connected else { return [] }
        if frame.command == 0x20, mode != 2, p.count == 2, p[0] < 6, p[1] < 16 {
            preset = Int(p[0]); channel = Int(p[1]); return [.preset(preset)]
        }
        if frame.command == 0x22, p.count == 3, p[0] < 3, p[1] < 6, p[2] < 16 {
            let releases = held.values.map { Event.padUp(token: $0) }
            held.removeAll(); down.removeAll(); mode = Int(p[0]); preset = Int(p[1]); channel = Int(p[2])
            return releases
        }
        if frame.command == 0x23, p.count == 1, p[0] != 64, p[0] > 0, mode == 1 {
            return [.action(.previewPage(Int(p[0]) - 64))]
        }
        if frame.command == 0x24, p.count == 1, p[0] != 64, p[0] > 0, mode == 1 {
            return [.action(.playlist(Int(p[0]) - 64))]
        }
        if frame.command == 0x25, p.count == 1, p[0] < 2, mode == 1 {
            return [.action(.fadeout(p[0] == 1))]
        }
        return []
    }
    public func claims(status: UInt8, number: UInt8) -> Bool {
        connected && mode != 2 && status & 0xf0 == 0xb0 && ((102...117).contains(number) || (mode == 0 && number == 23))
    }
    public mutating func midi(status: UInt8, number: UInt8, value: UInt8) -> [Event] {
        guard claims(status: status, number: number), value < 128 else { return [] }
        if mode == 0, number == 23 { return [.action(.padBusVolume(value))] }
        let key = Int(status & 15) * 16 + Int(number - 102)
        if value == 0 {
            down.remove(key)
            return held.removeValue(forKey: key).map { [.padUp(token: $0)] } ?? []
        }
        guard down.insert(key).inserted else { return [] }
        let index = Int(number - 102)
        if mode == 1 { return SMK37Action.pad(index).map { [.action($0)] } ?? [] }
        let token = UUID(); held[key] = token
        return [.padDown(token: token, preset: preset, pad: index)]
    }
}

/// One blue focus across the three lists, separate from red playback and orange
/// queue state. Both native and Remote use the same panel routing rule.
public struct SMK37Navigation: Equatable, Sendable {
    public enum Panel: String, Sendable { case setlist, left }
    public enum Focus: Equatable, Sendable {
        case songs
        case parts(panel: Panel, queued: Bool, marker: UUID)
    }
    public private(set) var focus: Focus = .songs
    public init() {}
    public mutating func selectSongs() { focus = .songs }
    public mutating func selectPart(_ marker: UUID, panel: Panel, queued: Bool) {
        focus = .parts(panel: panel, queued: queued, marker: marker)
    }
    public static func panel(queued: Bool, leftOpen: Bool, setlistOpen: Bool) -> Panel? {
        if leftOpen && setlistOpen { return queued ? .left : .setlist }
        if leftOpen { return .left }
        if setlistOpen { return .setlist }
        return nil
    }
    @discardableResult public mutating func move(queued: Bool, direction: Int,
        leftOpen: Bool, setlistOpen: Bool, markers: [UUID]) -> UUID? {
        guard let panel = Self.panel(queued: queued, leftOpen: leftOpen, setlistOpen: setlistOpen), !markers.isEmpty else { return nil }
        var index = 0
        if case let .parts(_, sameQueue, marker) = focus, sameQueue == queued,
           let old = markers.firstIndex(of: marker) { index = min(markers.count - 1, max(0, old + direction)) }
        let marker = markers[index]; selectPart(marker, panel: panel, queued: queued); return marker
    }
}

/// A MIDI packet may split SysEx anywhere. Bound incomplete messages and ignore
/// realtime bytes without letting them corrupt the custom frame checksum.
public struct SMK37Stream {
    public enum Message: Equatable, Sendable { case sysex([UInt8]), short(UInt8, UInt8, UInt8) }
    private var system: [UInt8] = []
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    public init() {}
    public mutating func feed(_ bytes: [UInt8]) -> [Message] {
        var result: [Message] = []
        for byte in bytes {
            if byte >= 0xf8 { continue }
            if byte == 0xf0 { system = [byte]; data.removeAll(); status = 0; continue }
            if !system.isEmpty {
                if byte == 0xf7 { system.append(byte); result.append(.sysex(system)); system.removeAll(); continue }
                if byte >= 128 || system.count >= 95 { system.removeAll(); status = 0 }
                else { system.append(byte); continue }
            }
            if byte >= 128 { status = byte < 0xf0 ? byte : 0; data.removeAll(); continue }
            guard status != 0 else { continue }
            data.append(byte)
            let count = [0xc0, 0xd0].contains(status & 0xf0) ? 1 : 2
            if data.count == count { result.append(.short(status, data[0], count == 2 ? data[1] : 0)); data.removeAll() }
        }
        return result
    }
}

/// Bound display feedback on the shared Bluetooth radio. Notes are input and
/// never pass through this budget; the connection heartbeat stays independent.
public struct SMK37FeedbackBudget {
    private var tokens = 96.0
    private var updated: Double?
    private var sent: Double?
    public init() {}
    public mutating func allow(bytes: Int, at now: Double) -> Bool {
        guard now.isFinite, bytes > 0, bytes <= 96 else { return false }
        if let updated {
            guard now >= updated else { return false }
            tokens = min(96, tokens + (now - updated) * 1200)
        }
        updated = now
        if let sent, now - sent < 0.02 - 1e-9 { return false }
        guard tokens + 1e-9 >= Double(bytes) else { return false }
        tokens -= Double(bytes); sent = now
        return true
    }
}
