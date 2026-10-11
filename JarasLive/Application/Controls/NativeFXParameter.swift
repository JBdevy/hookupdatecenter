import Foundation

/// Stable parameter identifiers keep MIDI assignments valid when windows close
/// or EQ bands change order. They never identify a band by its array position.
public struct NativeFXParameter: Codable, Equatable, Sendable {
    public enum Key: String, Codable, Sendable {
        case limiterGain, limiterCeiling, limiterRelease
        case pitchSemitones
        case enabled, threshold, ratio, makeup, attack, release
        case delayTime, feedback, delayMix, reverbMix, reverbDecay, reverbLowCut, reverbHighCut, reverbRoom
        case bandFrequency, bandGain, bandQ, bandType, bandSlope
        case instrumentVolume, instrumentGain, instrumentAttack, instrumentHold, instrumentDecay, instrumentSustain, instrumentRelease
        case velocityCutoff, velocityCurve, cutoffFrequency, cutoffDepth, cutoffAttack, cutoffHold, cutoffDecay, cutoffSustain, cutoffRelease
        case modulation, pitchBend
        case stemGain, stemMute, stemSolo
    }
    public var effect: String
    public var key: Key
    public var band: UUID?
    public var source: Int?
    public var name: String
    public var minimum: Double
    public var maximum: Double
    public var logarithmic: Bool
    public var choices: [String]?
    public init(effect: String, key: Key, band: UUID? = nil, source: Int? = nil, name: String, range: ClosedRange<Double>, logarithmic: Bool = false, choices: [String]? = nil) {
        self.effect = effect; self.key = key; self.band = band; self.source = source; self.name = name
        minimum = range.lowerBound; maximum = range.upperBound; self.logarithmic = logarithmic; self.choices = choices
    }
    public func value(_ midi: UInt8) -> Double {
        value(normalized: Double(midi) / 127)
    }
    public func value(normalized: Double) -> Double {
        let fraction = min(1, max(0, normalized))
        if fraction == 0 { return minimum }
        if fraction == 1 { return maximum }
        guard logarithmic else { return minimum + fraction * (maximum - minimum) }
        let offset = minimum == 0 ? 0.001 : 0
        return (minimum + offset) * pow((maximum + offset) / (minimum + offset), fraction) - offset
    }
    @discardableResult public func apply(_ midi: UInt8, to settings: inout NativeFXSettings) -> Bool {
        apply(normalized: Double(midi) / 127, to: &settings)
    }
    @discardableResult public func apply(normalized: Double, to settings: inout NativeFXSettings) -> Bool {
        guard normalized.isFinite, settings.inserted.contains(effect), minimum.isFinite, maximum.isFinite, minimum <= maximum,
              !logarithmic || (minimum >= 0 && maximum > minimum) else { return false }
        if let index = settings.instances?.firstIndex(where: { $0.effectKey == effect }), var instance = settings.instances?[index] {
            var parameter = self; parameter.effect = instance.kind
            let applied = parameter.apply(normalized: normalized, to: &instance.settings)
            settings.instances?[index] = instance; return applied
        }
        let value = value(normalized: normalized), enabled = normalized >= 0.5
        switch key {
        case .stemGain, .stemMute, .stemSolo:
            guard let source, (0..<5).contains(source) else { return false }
            var mix = settings.stemParameters
            if key == .stemGain { mix.sources[source].gain = value }
            if key == .stemMute { mix.sources[source].mute = enabled }
            if key == .stemSolo { mix.sources[source].solo = enabled }
            settings.stemParameters = mix
        case .enabled: settings.setEnabled(effect, enabled: enabled)
        case .pitchSemitones: settings.pitchSemitones = min(12, max(-12, value.rounded()))
        case .limiterGain: settings.limiterParameters.inputGain = min(24, max(-24, value))
        case .limiterCeiling: settings.limiterParameters.ceiling = min(0, max(-24, value))
        case .limiterRelease: settings.limiterParameters.release = min(3, max(0.01, value))
        case .threshold: settings.threshold = value
        case .ratio: settings.ratio = value
        case .makeup: settings.makeup = value
        case .attack: settings.attack = value
        case .release: settings.release = value
        case .delayTime: settings.delayTime = value
        case .feedback: settings.feedback = value
        case .delayMix: settings.delayMix = value
        case .reverbMix: settings.reverbMix = value
        case .reverbDecay: settings.reverbDecay = value
        case .reverbLowCut: settings.reverbLowCut = value
        case .reverbHighCut: settings.reverbHighCut = value
        case .reverbRoom: settings.reverbRoom = Int(value.rounded())
        case .bandFrequency, .bandGain, .bandQ, .bandType, .bandSlope:
            guard let index = settings.bands.firstIndex(where: { $0.id == band }) else { return false }
            switch key {
            case .bandFrequency: settings.bands[index].frequency = value
            case .bandGain: settings.bands[index].gain = value
            case .bandQ: settings.bands[index].q = value
            case .bandSlope:
                let slopes = [6,12,24,36,48,72,96,192]
                settings.bands[index].slope = slopes[min(7, max(0, Int(value.rounded())))]
            case .bandType:
                guard let choices, !choices.isEmpty else { return false }
                settings.bands[index].type = choices[min(choices.count - 1, max(0, Int(value.rounded())))]
            default: break
            }
        case .instrumentVolume, .instrumentGain, .instrumentAttack, .instrumentHold, .instrumentDecay, .instrumentSustain, .instrumentRelease:
            var parameters = settings.instrumentParameters ?? InstrumentParameters()
            switch key {
            case .instrumentVolume: var controllers = parameters.controllers ?? InstrumentControllerParameters(); controllers.volume = min(0, max(-96, value)); parameters.controllers = controllers
            case .instrumentGain: parameters.gain = value
            case .instrumentAttack: parameters.attack = value
            case .instrumentHold: parameters.hold = value
            case .instrumentDecay: parameters.decay = value
            case .instrumentSustain: parameters.sustain = value
            case .instrumentRelease: parameters.release = value
            default: break
            }
            settings.instrumentParameters = parameters
        case .velocityCutoff, .velocityCurve:
            var parameters = settings.instrumentParameters ?? InstrumentParameters()
            var velocity = parameters.velocity ?? InstrumentVelocityParameters()
            if key == .velocityCutoff { velocity.cutoffMinimum = value }
            else { velocity.curve = InstrumentVelocityCurve.allCases[min(2, max(0, Int(value.rounded())))] }
            parameters.velocity = velocity; settings.instrumentParameters = parameters
        case .cutoffFrequency, .cutoffDepth, .cutoffAttack, .cutoffHold, .cutoffDecay, .cutoffSustain, .cutoffRelease:
            var parameters = settings.instrumentParameters ?? InstrumentParameters()
            var cutoff = parameters.cutoff ?? InstrumentCutoffParameters()
            switch key {
            case .cutoffFrequency: cutoff.frequency = value
            case .cutoffDepth: cutoff.depth = value
            case .cutoffAttack: cutoff.attack = value
            case .cutoffHold: cutoff.hold = value
            case .cutoffDecay: cutoff.decay = value
            case .cutoffSustain: cutoff.sustain = value
            case .cutoffRelease: cutoff.release = value
            default: break
            }
            parameters.cutoff = cutoff; settings.instrumentParameters = parameters
        case .modulation, .pitchBend:
            var parameters = settings.instrumentParameters ?? InstrumentParameters()
            var controllers = parameters.controllers ?? InstrumentControllerParameters()
            if key == .modulation { controllers.modulation = enabled } else { controllers.pitchBend = enabled }
            parameters.controllers = controllers; settings.instrumentParameters = parameters
        }
        return true
    }
}

public extension NativeFXParameter {
    func normalized(_ value: Double) -> Double {
        let offset = minimum == 0 ? 0.001 : 0
        let fraction = logarithmic ? log((max(minimum, value)+offset)/(minimum+offset)) / log((maximum+offset)/(minimum+offset)) : (value-minimum)/(maximum-minimum)
        return min(1, max(0, fraction))
    }
    func currentValue(in chain: NativeFXSettings) -> Double {
        let s = chain.settings(for: effect), p = s.instrumentParameters ?? InstrumentParameters()
        switch key {
        case .stemGain, .stemMute, .stemSolo:
            guard let source, (0..<5).contains(source) else { return minimum }
            let item = s.stemParameters.sources[source]
            return key == .stemGain ? item.gain : (key == .stemMute ? item.mute : item.solo) ? 1 : 0
        case .enabled: return chain.isEnabled(effect) ? 1 : 0
        case .pitchSemitones: return s.semitones
        case .limiterGain: return s.limiterParameters.inputGain
        case .limiterCeiling: return s.limiterParameters.ceiling
        case .limiterRelease: return s.limiterParameters.release
        case .threshold: return s.threshold
        case .ratio: return s.ratio
        case .makeup: return s.makeup
        case .attack: return s.attack
        case .release: return s.release
        case .delayTime: return s.delayTime
        case .feedback: return s.feedback
        case .delayMix: return s.delayMix
        case .reverbMix: return s.reverbMix
        case .reverbDecay: return s.reverbDecay
        case .reverbLowCut: return s.reverbLowCut
        case .reverbHighCut: return s.reverbHighCut
        case .reverbRoom: return Double(s.reverbRoom)
        case .bandFrequency, .bandGain, .bandQ, .bandType, .bandSlope:
            guard let band = s.bands.first(where: { $0.id == self.band }) else { return minimum }
            switch key {
            case .bandFrequency: return band.frequency
            case .bandGain: return band.gain
            case .bandQ: return band.q
            case .bandType: return Double(choices?.firstIndex(of: band.type) ?? 0)
            case .bandSlope: return Double([6,12,24,36,48,72,96,192].firstIndex(of: band.slope) ?? 0)
            default: return minimum
            }
        case .instrumentVolume: return p.controllers?.volume ?? 0
        case .instrumentGain: return p.gain
        case .instrumentAttack: return p.attack
        case .instrumentHold: return p.hold
        case .instrumentDecay: return p.decay
        case .instrumentSustain: return p.sustain
        case .instrumentRelease: return p.release
        case .velocityCutoff: return p.velocity?.cutoffMinimum ?? 20000
        case .velocityCurve: return Double((p.velocity?.curve ?? .medium).index)
        case .cutoffFrequency: return p.cutoff?.frequency ?? 20000
        case .cutoffDepth: return p.cutoff?.depth ?? 0
        case .cutoffAttack: return p.cutoff?.attack ?? 0
        case .cutoffHold: return p.cutoff?.hold ?? 0
        case .cutoffDecay: return p.cutoff?.decay ?? 0.3
        case .cutoffSustain: return p.cutoff?.sustain ?? 1
        case .cutoffRelease: return p.cutoff?.release ?? 0.3
        case .modulation: return p.controllers?.modulation == true ? 1 : 0
        case .pitchBend: return p.controllers?.pitchBend == true ? 1 : 0
        }
    }
    static func automationParameters(in settings: NativeFXSettings) -> [NativeFXParameter] {
        var result: [NativeFXParameter] = []
        for effect in settings.inserted {
            let kind = settings.kind(of: effect), s = settings.settings(for: effect)
            guard NativeFXSettings.order.contains(kind) || kind == NativeFXSettings.stemSeparator else { continue }
            func add(_ key: Key, _ name: String, _ range: ClosedRange<Double>, log: Bool = false, band: UUID? = nil, choices: [String]? = nil) {
                result.append(NativeFXParameter(effect: effect, key: key, band: band, name: name, range: range, logarithmic: log, choices: choices))
            }
            add(.enabled, "Enabled", 0...1)
            switch kind {
            case NativeFXSettings.stemSeparator:
                for (source, name) in ["Vocal", "Drum", "Bass", "Guitar", "Other"].enumerated() {
                    for (key, suffix, range) in [(Key.stemGain, "Gain", 0.0...4.0), (.stemMute, "Mute", 0.0...1.0), (.stemSolo, "Solo", 0.0...1.0)] {
                        result.append(NativeFXParameter(effect: effect, key: key, source: source, name: name + " · " + suffix, range: range))
                    }
                }
            case "EQ":
                for (index, band) in s.bands.enumerated() {
                    let prefix = "Band \(index+1) · "
                    add(.bandFrequency, prefix+"Frequency", 20...20000, log: true, band: band.id)
                    add(.bandGain, prefix+"Gain", -24...24, band: band.id)
                    add(.bandQ, prefix+"Q", 0.1...18, log: true, band: band.id)
                    add(.bandSlope, prefix+"Slope", 0...7, band: band.id, choices: ["6", "12", "24", "36", "48", "72", "96", "192"])
                    add(.bandType, prefix+"Type", 0...4, band: band.id, choices: ["bell", "lowCut", "highCut", "lowShelf", "highShelf"])
                }
            case "Compressor":
                add(.threshold, "Threshold", -60...0); add(.ratio, "Ratio", 1...20); add(.makeup, "Gain", -12...24)
                add(.attack, "Attack", 0.0001...0.2, log: true); add(.release, "Release", 0.01...3, log: true)
            case "Limiter":
                add(.limiterGain, "Input gain", -24...24); add(.limiterCeiling, "Ceiling", -24...0); add(.limiterRelease, "Release", 0.01...3, log: true)
            case "Pitch": add(.pitchSemitones, "Semitones", -12...12)
            case "Delay": add(.delayTime, "Time", 0.01...2, log: true); add(.feedback, "Feedback", 0...90); add(.delayMix, "Mix", 0...100)
            case "Reverb":
                add(.reverbMix, "Mix", 0...100); add(.reverbDecay, "Decay", 0.1...20, log: true)
                add(.reverbLowCut, "Low Cut", 20...2000, log: true); add(.reverbHighCut, "High Cut", 2000...20000, log: true)
                add(.reverbRoom, "Space", 0...2, choices: ["Room", "Hall", "Plate"])
            case "Instruments":
                add(.instrumentVolume, "Volume", -96...0); add(.instrumentGain, "Gain", -24...12)
                add(.instrumentAttack, "Attack", 0...10); add(.instrumentHold, "Hold", 0...10)
                add(.instrumentDecay, "Decay", 0.001...10); add(.instrumentSustain, "Sustain", 0...1); add(.instrumentRelease, "Release", 0.001...20)
                add(.velocityCutoff, "Velocity cutoff", 20...20000, log: true); add(.velocityCurve, "Velocity curve", 0...2, choices: ["Soft", "Medium", "Hard"])
                add(.cutoffFrequency, "Cutoff", 20...20000, log: true); add(.cutoffDepth, "Cutoff depth", 0...10)
                add(.cutoffAttack, "Cutoff attack", 0...10); add(.cutoffHold, "Cutoff hold", 0...10)
                add(.cutoffDecay, "Cutoff decay", 0.001...10); add(.cutoffSustain, "Cutoff sustain", 0...1); add(.cutoffRelease, "Cutoff release", 0.001...20)
                add(.modulation, "Modulation", 0...1); add(.pitchBend, "Pitch bend", 0...1)
            default: break
            }
        }
        return result
    }
}
