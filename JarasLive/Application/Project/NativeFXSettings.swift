import Foundation
public struct EQBand: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var frequency: Double
    public var gain = 0.0
    public var q = 0.707
    public var type = "bell"
    public var slope = 12
    public var enabled = true
    public init(frequency: Double, type: String = "bell") { self.frequency = frequency; self.type = type }
    public func coefficients(rate: Double) -> [[Double]] {
        guard enabled else { return [] }
        let w = 2 * Double.pi * min(rate * 0.475, max(10, frequency)) / rate
        let c = cos(w), s = sin(w), a = pow(10, gain / 40)
        func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> [Double] { [b0/a0,b1/a0,b2/a0,a1/a0,a2/a0] }
        if type == "lowCut" || type == "highCut" {
            let high = type == "lowCut"
            let order = max(1, min(32, slope / 6))
            if order == 1 {
                let k = tan(w / 2), b0 = (high ? 1 : k) / (1 + k)
                return [[b0, high ? -b0 : b0, 0, (k - 1) / (k + 1), 0]]
            }
            return (0..<(order / 2)).map { stage in
                let butterworthQ = 1 / (2 * sin(Double.pi * Double(2 * stage + 1) / Double(2 * order)))
                let alpha = s / (2 * butterworthQ)
                return high ? normalized((1+c)/2, -(1+c), (1+c)/2, 1+alpha, -2*c, 1-alpha) : normalized((1-c)/2, 1-c, (1-c)/2, 1+alpha, -2*c, 1-alpha)
            }
        }
        let alpha = s / (2 * max(0.1, q))
        if type == "lowShelf" {
            let v = 2 * sqrt(a) * alpha
            return [normalized(a*((a+1)-(a-1)*c+v), 2*a*((a-1)-(a+1)*c), a*((a+1)-(a-1)*c-v), (a+1)+(a-1)*c+v, -2*((a-1)+(a+1)*c), (a+1)+(a-1)*c-v)]
        }
        if type == "highShelf" {
            let v = 2 * sqrt(a) * alpha
            return [normalized(a*((a+1)+(a-1)*c+v), -2*a*((a-1)+(a+1)*c), a*((a+1)+(a-1)*c-v), (a+1)-(a-1)*c+v, 2*((a-1)-(a+1)*c), (a+1)-(a-1)*c-v)]
        }
        return [normalized(1+alpha*a, -2*c, 1-alpha*a, 1+alpha/a, -2*c, 1-alpha/a)]
    }
    public func response(frequency: Double, rate: Double = 48000) -> Double {
        let w = 2 * Double.pi * frequency / rate
        return coefficients(rate: rate).reduce(0) { result, k in
            let nr = k[0]+k[1]*cos(w)+k[2]*cos(2*w), ni = -k[1]*sin(w)-k[2]*sin(2*w)
            let dr = 1+k[3]*cos(w)+k[4]*cos(2*w), di = -k[3]*sin(w)-k[4]*sin(2*w)
            return result + 10*log10(max(1e-20,(nr*nr+ni*ni)/max(1e-20,dr*dr+di*di)))
        }
    }
}
public enum InstrumentVelocityCurve: String, Codable, CaseIterable, Sendable {
    case soft, medium, hard
    public var exponent: Double { switch self { case .soft: return 0.65; case .medium: return 1; case .hard: return 1.6 } }
    public var index: Int { switch self { case .soft: return 0; case .medium: return 1; case .hard: return 2 } }
    public func value(_ input: Double) -> Double { pow(min(1, max(0, input)), exponent) }
}
public struct InstrumentVelocityParameters: Codable, Equatable, Sendable {
    public var curve: InstrumentVelocityCurve = .medium
    public var cutoffMinimum = 20000.0
    public init() {}
}
public struct InstrumentCutoffParameters: Codable, Equatable, Sendable {
    public var frequency = 20000.0
    public var attack = 0.0, hold = 0.0, decay = 0.3, sustain = 1.0, release = 0.3, depth = 0.0
    public init() {}
    public func validate() throws {
        guard [frequency, attack, hold, decay, sustain, release, depth].allSatisfy(\.isFinite),
              (20...20000).contains(frequency), (0...10).contains(attack), (0...10).contains(hold),
              (0.001...10).contains(decay), (0...1).contains(sustain), (0.001...20).contains(release), (0...10).contains(depth)
        else { throw ProjectError.invalid("Invalid cutoff envelope") }
    }
}
public struct InstrumentControllerParameters: Codable, Equatable, Sendable {
    public var modulation: Bool
    public var pitchBend: Bool
    public var monophonic: Bool?
    public var volume: Double?
    public init(modulation: Bool = false, pitchBend: Bool = false, monophonic: Bool? = nil) { self.modulation = modulation; self.pitchBend = pitchBend; self.monophonic = monophonic }
}
public struct InstrumentParameters: Codable, Equatable, Sendable {
    public var controllers: InstrumentControllerParameters?
    public var velocity: InstrumentVelocityParameters?
    public var cutoff: InstrumentCutoffParameters?
    public var gain = 0.0
    public var attack = 0.0, hold = 10.0, decay = 10.0, sustain = 1.0, release = 0.3
    public init(drums: Bool = false) { if drums { release = 20 } }
    public func validate() throws {
        try cutoff?.validate()
        if let volume = controllers?.volume { guard volume.isFinite, (-96...0).contains(volume) else { throw ProjectError.invalid("Invalid controller volume") } }
        if let velocity { guard velocity.cutoffMinimum.isFinite, (20...20000).contains(velocity.cutoffMinimum) else { throw ProjectError.invalid("Invalid velocity cutoff") } }
        guard [gain, attack, hold, decay, sustain, release].allSatisfy(\.isFinite),
              (-24...12).contains(gain), (0...10).contains(attack), (0...10).contains(hold),
              (0.001...10).contains(decay), (0...1).contains(sustain), (0.001...20).contains(release)
        else { throw ProjectError.invalid("Invalid instrument parameters") }
    }
}
public struct ExternalPlugin: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var classID: String, name: String, path: String
    public var category = ""
    public var bypassed = false
    public var componentState: String?, controllerState: String?
    public var effectKey: String { "External:" + id }
    public init(classID: String, name: String, path: String, category: String = "") { self.classID = classID; self.name = name; self.path = path; self.category = category }
}
public struct NativeFXInstance: Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var kind: String
    public var settings: NativeFXSettings
    public var effectKey: String { "Native:" + id }
    public init(kind: String, settings: NativeFXSettings) { self.kind = kind; self.settings = settings }
}
public struct NativeLimiterSettings: Codable, Equatable, Sendable {
    public var inputGain = 0.0
    public var ceiling = -0.1
    public var release = 0.1
    public init() {}
    public func validate() throws {
        guard [inputGain, ceiling, release].allSatisfy(\.isFinite),
              (-24...24).contains(inputGain), (-24...0).contains(ceiling), (0.01...3).contains(release)
        else { throw ProjectError.invalid("Invalid limiter settings") }
    }
}
public struct NativeFXSettings: Codable, Equatable, Sendable {
    public var instances: [NativeFXInstance]?

    public var externalPlugins: [ExternalPlugin]?
    public var instrumentID: String?
    public var instrumentParameters: InstrumentParameters?
    public var inserted: [String] = []
    public static let order = ["Instruments", "EQ", "Compressor", "Pitch", "Delay", "Reverb", "Limiter"]
    public var eqEnabled = false
    public var bands = [EQBand(frequency: 30, type: "lowCut"), EQBand(frequency: 200), EQBand(frequency: 1000), EQBand(frequency: 5000), EQBand(frequency: 18000, type: "highCut")]
    public var instrumentBypassed: Bool?
    public var compressorEnabled = false
    public var threshold = -20.0, ratio = 4.0, attack = 0.005, release = 0.1, makeup = 0.0
    public var limiterEnabled: Bool?
    public var limiter: NativeLimiterSettings?
    public var limiterParameters: NativeLimiterSettings {
        get { limiter ?? NativeLimiterSettings() }
        set { limiter = newValue }
    }
    public var pitchEnabled: Bool?
    public var pitchSemitones: Double?
    public var semitones: Double { pitchSemitones ?? 0 }
    public var delayEnabled = false
    public var delayTime = 0.25, feedback = 25.0, delayMix = 20.0
    public var reverbEnabled = false
    public var reverbMix = 20.0
    public var reverbRoom = 1
    public var reverbDecay = 2.0, reverbLowCut = 80.0, reverbHighCut = 12000.0
    public init() {}
    public func validateForClip() throws {
        try validate()
        guard inserted.allSatisfy({ Self.order.dropFirst().contains($0) }),
              instances?.isEmpty != false, externalPlugins?.isEmpty != false, instrumentID == nil, instrumentParameters == nil, instrumentBypassed == nil
        else { throw ProjectError.invalid("Items support EQ, Compressor, Pitch, Delay, Reverb and Limiter only") }
    }
    public func validate() throws {
        try limiter?.validate()
        try instrumentParameters?.validate()
        guard semitones.isFinite, (-12...12).contains(semitones), semitones == semitones.rounded() else { throw ProjectError.invalid("Invalid pitch") }
        let native = instances ?? []
        guard Set(native.map(\.id)).count == native.count else { throw ProjectError.invalid("Duplicate FX instance") }
        for instance in native {
            guard !instance.id.isEmpty, Self.order.contains(instance.kind), instance.settings.instances?.isEmpty != false,
                  instance.settings.externalPlugins?.isEmpty != false, instance.settings.inserted == [instance.kind]
            else { throw ProjectError.invalid("Invalid FX instance") }
            try instance.settings.validate()
        }
        let external = externalPlugins ?? []
        guard Set(external.map(\.id)).count == external.count,
              external.allSatisfy({ !$0.id.isEmpty && $0.classID.count == 32 && $0.classID.allSatisfy(\.isHexDigit) && !$0.name.isEmpty && !$0.path.isEmpty }) else { throw ProjectError.invalid("Invalid external plugin") }
        guard Set(inserted).count == inserted.count, inserted.allSatisfy({ effect in Self.order.contains(effect) || external.contains(where: { $0.effectKey == effect }) || native.contains(where: { $0.effectKey == effect }) }), bands.count <= 10, Set(bands.map(\.id)).count == bands.count,
              bands.allSatisfy({ $0.frequency.isFinite && (20...20000).contains($0.frequency) && $0.gain.isFinite && (-24...24).contains($0.gain) && $0.q.isFinite && (0.1...18).contains($0.q) && [6,12,24,36,48,72,96,192].contains($0.slope) && ["bell","lowCut","highCut","lowShelf","highShelf"].contains($0.type) }),
              [threshold, ratio, attack, release, makeup, delayTime, feedback, delayMix, reverbMix, reverbDecay, reverbLowCut, reverbHighCut].allSatisfy(\.isFinite),
              (-60...0).contains(threshold), (1...20).contains(ratio), (0.0001...0.2).contains(attack), (0.01...3).contains(release), (-12...24).contains(makeup),
              (0.01...2).contains(delayTime), (0...90).contains(feedback), (0...100).contains(delayMix), (0...100).contains(reverbMix), (0...2).contains(reverbRoom), (0.1...20).contains(reverbDecay), (20...2000).contains(reverbLowCut), (2000...20000).contains(reverbHighCut)
        else { throw ProjectError.invalid("Invalid FX settings") }
    }
}

extension NativeFXSettings {
    public var effectKeys: [String] { inserted }
    public func kind(of key: String) -> String { instances?.first { $0.effectKey == key }?.kind ?? key }
    public func settings(for key: String) -> Self { instances?.first { $0.effectKey == key }?.settings ?? self }
    public var instrumentKeys: [String] { inserted.filter { kind(of: $0) == "Instruments" && settings(for: $0).instrumentID != nil } }
    @discardableResult public mutating func appendNative(_ kind: String, instrument: String? = nil, parameters: InstrumentParameters? = nil) -> String {
        if !inserted.contains(kind) {
            inserted.append(kind); setEnabled(kind, enabled: true)
            if kind == "Instruments" { instrumentID = instrument; instrumentParameters = parameters; instrumentBypassed = false }
            return kind
        }
        var value = Self(); value.inserted = [kind]; value.setEnabled(kind, enabled: true)
        if kind == "Instruments" { value.instrumentID = instrument; value.instrumentParameters = parameters; value.instrumentBypassed = false }
        let instance = NativeFXInstance(kind: kind, settings: value)
        instances = (instances ?? []) + [instance]; inserted.append(instance.effectKey)
        return instance.effectKey
    }
    public mutating func removeInstance(_ key: String) { instances?.removeAll { $0.effectKey == key } }

    public func isEnabled(_ effect: String) -> Bool {
        if let instance = instances?.first(where: { $0.effectKey == effect }) { return instance.settings.isEnabled(instance.kind) }
        if let plugin = externalPlugins?.first(where: { $0.effectKey == effect }) { return !plugin.bypassed }
        switch effect { case "Instruments": return instrumentID != nil && instrumentBypassed != true; case "EQ": return eqEnabled; case "Compressor": return compressorEnabled; case "Limiter": return limiterEnabled == true; case "Pitch": return pitchEnabled == true; case "Delay": return delayEnabled; case "Reverb": return reverbEnabled; default: return false }
    }
    public mutating func setEnabled(_ effect: String, enabled: Bool) {
        if let index = instances?.firstIndex(where: { $0.effectKey == effect }), let kind = instances?[index].kind { instances?[index].settings.setEnabled(kind, enabled: enabled); return }
        if let index = externalPlugins?.firstIndex(where: { $0.effectKey == effect }) { externalPlugins?[index].bypassed = !enabled; return }
        switch effect { case "Instruments": instrumentBypassed = !enabled; case "EQ": eqEnabled = enabled; case "Compressor": compressorEnabled = enabled; case "Limiter": limiterEnabled = enabled; case "Pitch": pitchEnabled = enabled; case "Delay": delayEnabled = enabled; case "Reverb": reverbEnabled = enabled; default: break }
    }
    /// Editors for different effects can remain open; each updates only its own parameters.
    public func merging(effect: String, from draft: Self) -> Self {
        var next = self
        if let index = next.instances?.firstIndex(where: { $0.effectKey == effect }), let instance = next.instances?[index] {
            next.instances?[index].settings = instance.settings.merging(effect: instance.kind, from: draft.settings(for: effect))
            return next
        }
        switch effect {
        case "Instruments": next.instrumentID = draft.instrumentID; next.instrumentParameters = draft.instrumentParameters
        case "EQ": next.eqEnabled = draft.eqEnabled; next.bands = draft.bands
        case "Compressor":
            next.compressorEnabled = draft.compressorEnabled; next.threshold = draft.threshold; next.ratio = draft.ratio
            next.attack = draft.attack; next.release = draft.release; next.makeup = draft.makeup
        case "Limiter": next.limiterEnabled = draft.limiterEnabled; next.limiter = draft.limiter
        case "Pitch": next.pitchEnabled = draft.pitchEnabled; next.pitchSemitones = draft.pitchSemitones
        case "Delay": next.delayEnabled = draft.delayEnabled; next.delayTime = draft.delayTime; next.feedback = draft.feedback; next.delayMix = draft.delayMix
        case "Reverb": next.reverbEnabled = draft.reverbEnabled; next.reverbRoom = draft.reverbRoom; next.reverbMix = draft.reverbMix; next.reverbDecay = draft.reverbDecay; next.reverbLowCut = draft.reverbLowCut; next.reverbHighCut = draft.reverbHighCut
        default: break
        }
        return next
    }
}

public enum EffectPresentation {
    public static func title(_ effect: String) -> String {
        switch effect {
        case "EQ": return "Jaras EQ"
        case "Reverb": return "JarasVerb"
        case "Pitch": return "JarasPitch"
        case "Delay": return "JarasDelay"
        case "Compressor": return "JarasComp"
        case "Limiter": return "Jaras Limiter"
        default: return "JarasInstruments"
        }
    }
}
