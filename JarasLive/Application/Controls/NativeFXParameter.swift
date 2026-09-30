import Foundation

/// Stable parameter identifiers keep MIDI assignments valid when windows close
/// or EQ bands change order. They never identify a band by its array position.
public struct NativeFXParameter: Codable, Equatable {
    public enum Key: String, Codable {
        case pitchSemitones
        case enabled, threshold, ratio, makeup, attack, release
        case delayTime, feedback, delayMix, reverbMix, reverbDecay, reverbLowCut, reverbHighCut, reverbRoom
        case bandFrequency, bandGain, bandQ, bandType, bandSlope
        case instrumentVolume, instrumentGain, instrumentAttack, instrumentHold, instrumentDecay, instrumentSustain, instrumentRelease
        case velocityCutoff, velocityCurve, cutoffFrequency, cutoffDepth, cutoffAttack, cutoffHold, cutoffDecay, cutoffSustain, cutoffRelease
        case modulation, pitchBend
    }
    public var effect: String
    public var key: Key
    public var band: UUID?
    public var name: String
    public var minimum: Double
    public var maximum: Double
    public var logarithmic: Bool
    public var choices: [String]?
    public init(effect: String, key: Key, band: UUID? = nil, name: String, range: ClosedRange<Double>, logarithmic: Bool = false, choices: [String]? = nil) {
        self.effect = effect; self.key = key; self.band = band; self.name = name
        minimum = range.lowerBound; maximum = range.upperBound; self.logarithmic = logarithmic; self.choices = choices
    }
    public func value(_ midi: UInt8) -> Double {
        if midi == 0 { return minimum }
        if midi >= 127 { return maximum }
        let fraction = Double(midi) / 127
        guard logarithmic else { return minimum + fraction * (maximum - minimum) }
        let offset = minimum == 0 ? 0.001 : 0
        return (minimum + offset) * pow((maximum + offset) / (minimum + offset), fraction) - offset
    }
    @discardableResult public func apply(_ midi: UInt8, to settings: inout NativeFXSettings) -> Bool {
        guard settings.inserted.contains(effect), minimum.isFinite, maximum.isFinite, minimum <= maximum,
              !logarithmic || (minimum >= 0 && maximum > minimum) else { return false }
        if let index = settings.instances?.firstIndex(where: { $0.effectKey == effect }), var instance = settings.instances?[index] {
            var parameter = self; parameter.effect = instance.kind
            let applied = parameter.apply(midi, to: &instance.settings)
            settings.instances?[index] = instance; return applied
        }
        let value = value(midi), enabled = midi >= 64
        switch key {
        case .enabled: settings.setEnabled(effect, enabled: enabled)
        case .pitchSemitones: settings.pitchSemitones = min(12, max(-12, value.rounded()))
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
