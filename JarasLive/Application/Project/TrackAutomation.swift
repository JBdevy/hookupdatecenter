import Foundation

public enum AutomationMode: String, Codable, CaseIterable, Sendable {
    case trimRead, read, touch, latch, write
    public var title: String {
        switch self { case .trimRead: return "Trim / Read"; case .read: return "Read"; case .touch: return "Touch"; case .latch: return "Latch"; case .write: return "Write" }
    }
    public var writes: Bool { self == .touch || self == .latch || self == .write }
}
public enum EnvelopeShape: String, Codable, CaseIterable, Sendable {
    case linear, square, smooth, fastStart, fastEnd
    public var title: String {
        switch self { case .linear: return "Linear"; case .square: return "Square"; case .smooth: return "Smooth"; case .fastStart: return "Fast start"; case .fastEnd: return "Fast end" }
    }
    public func interpolate(_ x: Double) -> Double {
        switch self { case .linear: return x; case .square: return 0; case .smooth: return x*x*(3-2*x); case .fastStart: return 1-pow(1-x,3); case .fastEnd: return x*x*x }
    }
}
public struct EnvelopePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var time: Double
    public var value: Double
    public var shape: EnvelopeShape = .linear
    public init(id: UUID = UUID(), time: Double, value: Double, shape: EnvelopeShape = .linear) {
        self.id = id; self.time = time; self.value = value; self.shape = shape
    }
}
public struct AutomationTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case volume, pan, mute, nativeFX, externalFX }
    public var kind: Kind
    public var native: NativeFXParameter?
    public var plugin: String?
    public var parameter: UInt32?
    public init(_ kind: Kind, native: NativeFXParameter? = nil, plugin: String? = nil, parameter: UInt32? = nil) {
        self.kind = kind; self.native = native; self.plugin = plugin; self.parameter = parameter
    }
    public var key: String {
        switch kind {
        case .nativeFX: return "native/\(native?.effect ?? "")/\(native?.key.rawValue ?? "")/\(native?.band?.uuidString ?? "")/\(native?.source ?? -1)"
        case .externalFX: return "external/\(plugin ?? "")/\(parameter ?? 0)"
        default: return kind.rawValue
        }
    }
}
public struct TrackEnvelope: Codable, Equatable, Identifiable, Sendable {
    /// Imported amplitude envelopes interpolate gain, rather than decibels.
    public enum ValueScale: String, Codable, Sendable { case linearGain }
    public var id = UUID()
    public var target: AutomationTarget
    public var name: String
    public var enabled = true
    public var visible = true
    public var armed = false
    public var defaultValue: Double
    public var valueScale: ValueScale?
    public var points: [EnvelopePoint] = []
    public init(target: AutomationTarget, name: String, defaultValue: Double) {
        self.target = target; self.name = name; self.defaultValue = min(1, max(0, defaultValue))
    }
    public func value(at time: Double) -> Double {
        guard let first = points.first else { return defaultValue }
        guard time > first.time else { return first.value }
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].time <= time { low = mid + 1 } else { high = mid } }
        let a = points[low - 1]
        guard low < points.count else { return a.value }
        let b = points[low], fraction = (time - a.time) / (b.time - a.time)
        let progress = a.shape.interpolate(fraction)
        if valueScale == .linearGain {
            let first = Self.gain(a.value), last = Self.gain(b.value)
            return Self.normalizedGain(first + (last - first) * progress)
        }
        return a.value + (b.value - a.value) * progress
    }
    public mutating func insert(_ point: EnvelopePoint) {
        guard point.time.isFinite, point.time >= 0, point.value.isFinite else { return }
        var point = point; point.value = min(1, max(0, point.value))
        points.removeAll { $0.id == point.id || abs($0.time - point.time) < 0.000001 }
        let index = points.firstIndex { $0.time > point.time } ?? points.count
        points.insert(point, at: index)
    }
    /// Replace only the written interval, preserving playback on both sides.
    public mutating func write(from previous: Double?, to time: Double, value: Double) {
        guard time.isFinite, time >= 0, value.isFinite else { return }
        if previous == nil || time < (previous ?? time) {
            let head = self.value(at: max(0, time - 0.00001)), tail = self.value(at: time + 0.00001)
            if time > 0.00001 { insert(EnvelopePoint(time: time - 0.00001, value: head)) }
            insert(EnvelopePoint(time: time + 0.00001, value: tail))
        } else if let previous, time > previous {
            let oldTail = self.value(at: time + 0.00001)
            points.removeAll { $0.time > previous && $0.time <= time }
            insert(EnvelopePoint(time: time + 0.00001, value: oldTail))
        }
        insert(EnvelopePoint(time: time, value: value))
    }
    public static func gain(_ normalized: Double) -> Double { normalized <= 0 ? 0 : pow(10, (-96 + min(1, normalized)*108)/20) }
    public static func normalizedGain(_ gain: Double) -> Double { gain <= 0 ? 0 : min(1, max(0, (20*log10(gain)+96)/108)) }
}

extension AudioClip {
    /// Take envelopes belong to media time. Trims, moves and tempo fragments
    /// already carry the source offset/rate, so points do not need rewriting.
    public func automationTime(at timelinePosition: Double) -> Double {
        // Media may repeat, while its take envelope continues across the item.
        let source = (automationSourceOffset ?? sourceOffset) + max(0, timelinePosition - startTime) * audioRate
        return max(0, source)
    }
    public func automatedValues(at timelinePosition: Double) -> AutomationPlaybackValues {
        (automation ?? TrackAutomation()).evaluate(at: automationTime(at: timelinePosition),
            gain: gain ?? 1, pan: pan ?? 0, muted: muted == true,
            fx: fx ?? NativeFXSettings(), take: true, bypassFX: fxBypassed == true)
    }
}

public struct AutomationPlaybackValues {
    public var gain: Double
    public var pan: Double
    public var muted: Bool
    public var fx: NativeFXSettings
    public var nativeActive = false
    public var external: [(target: AutomationTarget, value: Double)] = []
}
public struct TrackAutomation: Codable, Equatable, Sendable {
    public var enabled = true
    public var mode: AutomationMode = .trimRead
    public var envelopes: [TrackEnvelope] = []
    /// Env controls both lane visibility and playback automation.
    public var lanesVisible: Bool?
    public init() {}
    public var active: [TrackEnvelope] { enabled ? visibleEnvelopes.filter(\.enabled) : [] }
    public var visibleEnvelopes: [TrackEnvelope] { !enabled || lanesVisible == false ? [] : envelopes.filter(\.visible) }
    public mutating func toggleLanes(volume: Double, volumeName: String) {
        if !visibleEnvelopes.isEmpty { lanesVisible = false; enabled = false; return }
        if envelopes.isEmpty {
            envelopes = [TrackEnvelope(target: AutomationTarget(.volume), name: volumeName, defaultValue: TrackEnvelope.normalizedGain(volume))]
        } else if !envelopes.contains(where: \.visible) {
            for index in envelopes.indices { envelopes[index].visible = true }
        }
        lanesVisible = true; enabled = true
    }
    public func validate() throws {
        guard Set(envelopes.map(\.id)).count == envelopes.count,
              Set(envelopes.map { $0.target.key }).count == envelopes.count else { throw ProjectError.invalid("Duplicate automation envelope") }
        for envelope in envelopes {
            guard envelope.defaultValue.isFinite, (0...1).contains(envelope.defaultValue), !envelope.name.isEmpty else { throw ProjectError.invalid("Invalid automation envelope") }
            if envelope.target.kind == .nativeFX {
                guard let p = envelope.target.native, !p.effect.isEmpty, p.minimum.isFinite, p.maximum.isFinite, p.maximum > p.minimum,
                      !p.logarithmic || p.minimum >= 0 else { throw ProjectError.invalid("Invalid automation parameter") }
            }
            if envelope.target.kind == .externalFX {
                guard envelope.target.plugin?.isEmpty == false, envelope.target.parameter != nil else { throw ProjectError.invalid("Invalid plugin automation parameter") }
            }
            var previous = -Double.infinity, identifiers = Set<UUID>()
            for point in envelope.points {
                guard identifiers.insert(point.id).inserted, point.time.isFinite, point.time >= 0, point.time > previous,
                      point.value.isFinite, (0...1).contains(point.value) else { throw ProjectError.invalid("Invalid envelope point") }
                previous = point.time
            }
        }
    }
    /// Pure evaluation shared by real-time item voices and offline rendering.
    public func evaluate(at time: Double, gain: Double, pan: Double, muted: Bool,
                         fx: NativeFXSettings, take: Bool = false, bypassFX: Bool = false) -> AutomationPlaybackValues {
        var result = AutomationPlaybackValues(gain: gain, pan: pan, muted: muted, fx: fx)
        guard enabled else { return result }
        let curves = take ? envelopes.filter(\.enabled) : active
        for envelope in curves {
            let value = envelope.value(at: time)
            switch envelope.target.kind {
            case .volume:
                let level = TrackEnvelope.gain(value)
                result.gain = take ? gain * level : mode == .trimRead ? gain * level / max(0.000001, TrackEnvelope.gain(envelope.defaultValue)) : level
            case .pan:
                let position = value * 2 - 1
                result.pan = min(1, max(-1, take ? pan + position : mode == .trimRead ? pan + position - (envelope.defaultValue * 2 - 1) : position))
            case .mute: result.muted = take ? muted || value >= 0.5 : value >= 0.5
            case .nativeFX:
                if !bypassFX, envelope.target.native?.apply(normalized: value, to: &result.fx) == true { result.nativeActive = true }
            case .externalFX:
                if !bypassFX { result.external.append((envelope.target, value)) }
            }
        }
        return result
    }
}
