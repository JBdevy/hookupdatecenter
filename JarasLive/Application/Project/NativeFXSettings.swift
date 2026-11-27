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
    public var attack = 0.0, hold = 10.0, decay = 10.0, sustain = 1.0, release = 0.16
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
    public var araState: String?
    public var effectKey: String { "External:" + id }
    fileprivate var hasValidClassID: Bool {
        if classID.count == 32 && classID.allSatisfy(\.isHexDigit) { return true }
        let fields = classID.split(separator: "-", omittingEmptySubsequences: false)
        return fields.count == 4 && fields[0] == "AU" &&
            fields.dropFirst().allSatisfy { $0.count == 8 && $0.allSatisfy(\.isHexDigit) }
    }
    public init(classID: String, name: String, path: String, category: String = "") { self.classID = classID; self.name = name; self.path = path; self.category = category }
}
public struct NativeFXInstance: Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var kind: String
    public var settings: NativeFXSettings
    /// Retains identity when a legacy stage is promoted by reordering an item.
    public var legacyOrigin: String? = nil
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
/// Independent controls for the five sources of a track's CatStem processor.
/// Order is Vocal, Drum, Bass, Guitar, Other (including piano).
public struct NativeStemMix: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var gain = 1.0
        public var mute = false
        public var solo = false
        public init() {}
    }
    public var sources = Array(repeating: Source(), count: 5)
    public init() {}
    public func validate() throws {
        guard sources.count == 5, sources.allSatisfy({ $0.gain.isFinite && (0...4).contains($0.gain) })
        else { throw ProjectError.invalid("Invalid CatStem source controls") }
    }
    public var gains: [Double] {
        let soloed = sources.contains { $0.solo }
        return sources.map { $0.mute || (soloed && !$0.solo) ? 0 : $0.gain }
    }
}
public struct NativeTriggerSettings: Codable, Equatable, Sendable {
    public var samplePath: String?
    public var threshold = -30.0, retrigger = 0.08, gain = 0.0, mix = 100.0
    public var attack = 0.0, decay = 0.1, sustain = 1.0, release = 0.02
    public init() {}
    public func validate() throws {
        guard [threshold,retrigger,gain,mix,attack,decay,sustain,release].allSatisfy(\.isFinite),
              (-80...0).contains(threshold), (0.005...2).contains(retrigger), (-24...24).contains(gain),
              (0...100).contains(mix), (0...10).contains(attack), (0...10).contains(decay),
              (0...1).contains(sustain), (0...20).contains(release) else { throw ProjectError.invalid("Invalid trigger settings") }
        if let samplePath {
            guard !samplePath.isEmpty, !samplePath.hasPrefix("/"), !samplePath.contains("\\"),
                  !samplePath.contains(":"), samplePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }),
                  ["wav","mp3"].contains(URL(fileURLWithPath: samplePath).pathExtension.lowercased())
            else { throw ProjectError.invalid("Invalid trigger sample path") }
        }
    }
}
public struct NativeGateSettings: Codable, Equatable, Sendable {
    public var threshold = -40.0, attack = 0.001, decay = 0.02, hold = 0.05, release = 0.1
    public var highPass = 20.0, lowPass = 20000.0
    public var filterOutput = false
    public init() {}
    public func validate() throws {
        guard [threshold,attack,decay,hold,release,highPass,lowPass].allSatisfy(\.isFinite),
              (-80...0).contains(threshold), (0...2).contains(attack), (0...2).contains(decay),
              (0...2).contains(hold), (0...5).contains(release),
              (20...20000).contains(highPass), (20...20000).contains(lowPass), highPass <= lowPass
        else { throw ProjectError.invalid("Invalid gate settings") }
    }
}
public enum NativeCreativeEffect: String, CaseIterable, Sendable {
    case chorus = "Chorus", phaser = "Phaser", amp = "Amp", divisionGate = "Gate Divisor", softClipper = "Soft Clipper"
    case graphicEQ = "EQ - 31 Band"

    private static let graphicEQLabels = [
        "20", "25", "31.5", "40", "50", "63", "80", "100", "125", "160", "200", "250", "315", "400",
        "500", "630", "800", "1k", "1.25k", "1.6k", "2k", "2.5k", "3.15k", "4k", "5k", "6.3k",
        "8k", "10k", "12.5k", "16k", "20k"
    ]

    public struct Parameter: Sendable {
        public let key: String
        public let title: String
        public let range: ClosedRange<Double>
        public let initial: Double
        public let unit: String
        init(_ key: String, _ title: String, _ range: ClosedRange<Double>, _ initial: Double, _ unit: String) {
            self.key = key; self.title = title; self.range = range; self.initial = initial; self.unit = unit
        }
    }

    public var parameters: [Parameter] {
        switch self {
        case .chorus: return [
            .init("rate", "Rate", 0.05...8, 0.8, "Hz"), .init("depth", "Depth", 0...10, 3, "ms"),
            .init("mix", "Mix", 0...100, 40, "%")]
        case .phaser: return [
            .init("rate", "Rate", 0.05...8, 0.4, "Hz"), .init("depth", "Depth", 0...100, 70, "%"),
            .init("feedback", "Feedback", 0...85, 27, "%"), .init("mix", "Mix", 0...100, 50, "%")]
        case .amp: return [
            .init("drive", "Drive", 0...36, 12, "dB"), .init("tone", "Tone", 0...100, 55, "%"),
            .init("output", "Output", -24...12, -6, "dB"), .init("mix", "Mix", 0...100, 100, "%")]
        case .softClipper: return [
            .init("drive", "Drive", 0...24, 0, "dB"), .init("ceiling", "Ceiling", -24...0, -0.1, "dB"),
            .init("softness", "Softness", 1...100, 40, "%")]
        case .divisionGate: return [
            .init("division", "Division", 2...32, 16, ""), .init("depth", "Depth", 0...100, 100, "%"),
            .init("smoothing", "Smoothing", 0.2...30, 4, "ms"), .init("steps", "Steps", 0...65535, 0x5b5b, "")]
        case .graphicEQ: return Self.graphicEQLabels.enumerated().map { index, title in
            .init("band\(index)", title, -12...12, 0, "dB")
        } + [.init("output", "Output", -12...12, 0, "dB")]
        }
    }
}

public struct CatSynthBank: Codable, Equatable, Sendable {
    public static let count = 8
    public static let parameterCount = 34
    public static let presetNameLimit = 20
    public var selected = 0
    public var slots: [[Float]?] = Array(repeating: nil, count: count)
    public var names: [String?]?

    public init() {}

    public func validate() throws {
        guard (0..<Self.count).contains(selected), slots.count == Self.count,
              slots.allSatisfy({ $0.map { $0.count == Self.parameterCount && $0.allSatisfy(\.isFinite) } ?? true }),
              names.map({ $0.count == Self.count && $0.allSatisfy { ($0?.count ?? 0) <= Self.presetNameLimit } }) ?? true else {
            throw ProjectError.invalid("Invalid CatSynth presets")
        }
    }
}

public struct NativeArpeggiatorSettings: Codable, Equatable, Sendable {
    public static let divisions = [2, 4, 6, 8, 12, 16, 24, 32, 48]
    public static let directions = ["Up", "Down", "Up / Down", "As Played"]

    public var division: Int
    public var direction: Int
    public var octaves: Int
    public var gate: Int
    public var sync: Bool
    public var bpm: Int

    public init(division: Int = 16, direction: Int = 0, octaves: Int = 1, gate: Int = 75,
                sync: Bool = true, bpm: Int = 120) {
        self.division = Self.divisions.contains(division) ? division : 16
        self.direction = max(0, min(Self.directions.count - 1, direction))
        self.octaves = max(1, min(4, octaves))
        self.gate = max(5, min(100, gate))
        self.sync = sync
        self.bpm = max(20, min(400, bpm))
    }

    private enum CodingKeys: String, CodingKey { case division, direction, octaves, gate, sync, bpm }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(division: values.decodeIfPresent(Int.self, forKey: .division) ?? 16,
                      direction: values.decodeIfPresent(Int.self, forKey: .direction) ?? 0,
                      octaves: values.decodeIfPresent(Int.self, forKey: .octaves) ?? 1,
                      gate: values.decodeIfPresent(Int.self, forKey: .gate) ?? 75,
                      sync: values.decodeIfPresent(Bool.self, forKey: .sync) ?? true,
                      bpm: values.decodeIfPresent(Int.self, forKey: .bpm) ?? 120)
    }

    public var gateFraction: Double { Double(gate) / 100 }
    public func interval(transportBPM: Double) -> Double {
        240 / (Double(division) * max(20, sync ? transportBPM : Double(bpm)))
    }

    public func step(_ index: Int, count: Int, pitchAt: (Int) -> Int) -> (note: Int, transpose: Int) {
        guard count > 0 else { return (0, 0) }
        var available = count
        for octave in 1..<octaves {
            for i in 0..<count where pitchAt(i) + octave * 12 <= 127 { available += 1 }
        }
        var step = index % available
        if direction == 1 {
            step = available - step - 1
        } else if direction == 2 && available > 1 {
            let period = 2 * available - 2
            step = index % period
            if step >= available { step = period - step }
        }
        if step < count { return (step, 0) }
        step -= count
        for octave in 1..<octaves {
            for i in 0..<count where pitchAt(i) + octave * 12 <= 127 {
                if step == 0 { return (i, octave * 12) }
                step -= 1
            }
        }
        return (0, 0)
    }
}

public struct NativeConvolutionSettings: Codable, Equatable, Sendable {
    public static let presets = ["Room 1", "Room 2", "Hall 1", "Hall 2"]
    public var preset = 0
    public var mix = 20.0
    public var impulsePath: String?
    public init() {}

    func validate() throws {
        guard Self.presets.indices.contains(preset), (0...100).contains(mix) else {
            throw ProjectError.invalid("Invalid convolution reverb settings.")
        }
        if let path = impulsePath {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  ["wav", "aif", "aiff"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                throw ProjectError.invalid("Invalid impulse response path.")
            }
        }
    }
}

extension WaveLFOEnvelope {
    public func validate() throws {
        guard [attack, decay, release].allSatisfy({ (0...60).contains($0) }),
              (0...1).contains(sustain) else { throw ProjectError.invalid("Invalid Wave LFO envelope") }
    }
}

public struct NativeFXSettings: Codable, Equatable, Sendable {
    public var instances: [NativeFXInstance]?

    public var externalPlugins: [ExternalPlugin]?
    public var instrumentID: String?
    public var instrumentParameters: InstrumentParameters?
    public var inserted: [String] = []
    public static let order = ["Instruments", "CatSynth", "Arpeggiator", "EQ", "Compressor", "Pitch", "Delay", "Reverb", reverbConvolution, "Limiter", "CatLive Trigger", "Cat Gate"] + DrummerPadKind.allCases.map(\.rawValue) + NativeCreativeEffect.allCases.map(\.rawValue)
    public static let stemSeparator = "CatStemSeparation 5"
    public static let waveLFOName = WaveLFOEnvelope.name
    public var waveLFOEnabled: Bool?
    public var waveLFO: WaveLFOEnvelope?
    public var waveLFOParameters: WaveLFOEnvelope {
        get { waveLFO ?? WaveLFOEnvelope() }
        set { waveLFO = newValue }
    }
    public var activeWaveLFO: WaveLFOEnvelope? {
        waveLFOEnabled == true && inserted.contains(Self.waveLFOName) ? waveLFOParameters : nil
    }
    public static let reverbConvolution = "Reverb-Convolution"
    public var convolutionEnabled: Bool?
    public var convolution: NativeConvolutionSettings?
    public var convolutionParameters: NativeConvolutionSettings {
        get { convolution ?? NativeConvolutionSettings() }
        set { convolution = newValue }
    }
    public var catSynth: CatSynthBank?
    public var catSynthEnabled: Bool?
    public var drummer16: DrummerPadKit?
    public var drummer48: DrummerPadKit?
    public var drummer16Enabled: Bool?
    public var drummer48Enabled: Bool?
    public func drumKit(_ kind: DrummerPadKind) -> DrummerPadKit {
        (kind == .compact ? drummer16 : drummer48) ?? DrummerPadKit(kind)
    }
    public mutating func setDrumKit(_ kit: DrummerPadKit, for kind: DrummerPadKind) {
        if kind == .compact { drummer16 = kit } else { drummer48 = kit }
    }
    public var arpeggiatorEnabled: Bool?
    public var arpeggiator: NativeArpeggiatorSettings?
    public var chorusEnabled: Bool?
    public var phaserEnabled: Bool?
    public var ampEnabled: Bool?
    public var softClipperEnabled: Bool?
    public var softClipper: [String: Double]?
    public var graphicEQEnabled: Bool?
    public var graphicEQ: [String: Double]?
    public var divisionGateEnabled: Bool?
    public var chorus: [String: Double]?
    public var phaser: [String: Double]?
    public var amp: [String: Double]?
    public var divisionGate: [String: Double]?
    public var eqChannels: Int?
    public var compressorChannels: Int?
    public var delayChannels: Int?
    public var reverbChannels: Int?

    public var hasCreativeEffects: Bool { NativeCreativeEffect.allCases.contains { isEnabled($0.rawValue) } }
    public func creativeParameters(_ effect: NativeCreativeEffect) -> [String: Double]? {
        switch effect {
        case .chorus: return chorus
        case .phaser: return phaser
        case .amp: return amp
        case .softClipper: return softClipper
        case .graphicEQ: return graphicEQ
        case .divisionGate: return divisionGate
        }
    }
    public mutating func setCreativeParameters(_ values: [String: Double]?, for effect: NativeCreativeEffect) {
        switch effect {
        case .chorus: chorus = values
        case .phaser: phaser = values
        case .amp: amp = values
        case .softClipper: softClipper = values
        case .graphicEQ: graphicEQ = values
        case .divisionGate: divisionGate = values
        }
    }
    public func channels(for effect: String) -> Int {
        switch effect {
        case "EQ": return eqChannels ?? 3
        case "Compressor": return compressorChannels ?? 3
        case "Delay": return delayChannels ?? 3
        case "Reverb": return reverbChannels ?? 3
        default: return 3
        }
    }
    public mutating func setChannels(_ mask: Int, for effect: String) {
        let value = mask == 3 ? nil : mask
        switch effect {
        case "EQ": eqChannels = value
        case "Compressor": compressorChannels = value
        case "Delay": delayChannels = value
        case "Reverb": reverbChannels = value
        default: break
        }
    }
    public var triggerEnabled: Bool?
    public var trigger: NativeTriggerSettings?
    public var triggerParameters: NativeTriggerSettings {
        get { trigger ?? NativeTriggerSettings() }
        set { trigger = newValue }
    }
    public var gateEnabled: Bool?
    public var gate: NativeGateSettings?
    public var gateParameters: NativeGateSettings {
        get { gate ?? NativeGateSettings() }
        set { gate = newValue }
    }
    public var stemSeparatorEnabled: Bool?
    public var stemMix: NativeStemMix?
    public var stemParameters: NativeStemMix {
        get { stemMix ?? NativeStemMix() }
        set { stemMix = newValue }
    }
    // A non-nil list distinguishes a bypassed strip, even when it had no active inserts.
    public var mixerBypassRestore: [String]?
    public var bypassAppliedBySession: Bool?
    public var sessionFXBypassed: Bool?
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
    public var pitchFormant: Double?
    public var formantSemitones: Double { min(12, max(-12, pitchFormant ?? 0)) }
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
        if inserted.contains("Instruments") {
            guard instrumentID?.isEmpty == false else { throw ProjectError.invalid("Invalid instrument") }
        } else if instrumentID != nil || instrumentParameters != nil || instrumentBypassed != nil {
            throw ProjectError.invalid("Invalid instrument")
        }
        for instance in instances ?? [] { try instance.settings.validateForClip() }
    }
    public func validate() throws {
        for effect in NativeCreativeEffect.allCases {
            guard let values = creativeParameters(effect) else { continue }
            let parameters = effect.parameters
            for (key, value) in values {
                guard parameters.first(where: { $0.key == key })?.range.contains(value) == true else {
                    throw ProjectError.invalid("Invalid FX settings")
                }
            }
        }
        guard [eqChannels, compressorChannels, delayChannels, reverbChannels]
            .compactMap({ $0 }).allSatisfy({ (0...3).contains($0) }) else { throw ProjectError.invalid("Invalid FX channel selection") }
        try catSynth?.validate()
        try drummer16?.validate(.compact)
        try drummer48?.validate(.full)
        try trigger?.validate()
        try convolution?.validate()
        try waveLFO?.validate()
        try gate?.validate()
        try stemMix?.validate()
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
              external.allSatisfy({ !$0.id.isEmpty && $0.hasValidClassID && !$0.name.isEmpty && !$0.path.isEmpty }) else { throw ProjectError.invalid("Invalid external plugin") }
        guard Set(inserted).count == inserted.count, inserted.allSatisfy({ effect in Self.order.contains(effect) || effect == Self.waveLFOName || effect == Self.stemSeparator || external.contains(where: { $0.effectKey == effect }) || native.contains(where: { $0.effectKey == effect }) }), bands.count <= 10, Set(bands.map(\.id)).count == bands.count,
              bands.allSatisfy({ $0.frequency.isFinite && (20...20000).contains($0.frequency) && $0.gain.isFinite && (-24...24).contains($0.gain) && $0.q.isFinite && (0.1...18).contains($0.q) && [6,12,24,36,48,72,96,192].contains($0.slope) && ["bell","lowCut","highCut","lowShelf","highShelf"].contains($0.type) }),
              [threshold, ratio, attack, release, makeup, delayTime, feedback, delayMix, reverbMix, reverbDecay, reverbLowCut, reverbHighCut].allSatisfy(\.isFinite),
              (-60...0).contains(threshold), (1...20).contains(ratio), (0.0001...0.2).contains(attack), (0.01...3).contains(release), (-12...24).contains(makeup),
              (0.01...2).contains(delayTime), (0...90).contains(feedback), (0...100).contains(delayMix), (0...100).contains(reverbMix), (0...2).contains(reverbRoom), (0.1...20).contains(reverbDecay), (20...2000).contains(reverbLowCut), (2000...20000).contains(reverbHighCut)
        else { throw ProjectError.invalid("Invalid FX settings") }
    }
}

extension NativeFXSettings {
    public var effectKeys: [String] { inserted.filter { kind(of: $0) != Self.stemSeparator } }
    public func isInstrument(_ key: String) -> Bool {
        if let plugin = externalPlugins?.first(where: { $0.effectKey == key }) {
            return plugin.category.localizedCaseInsensitiveContains("Instrument")
        }
        let type = kind(of: key)
        return type == "Instruments" || type == "CatSynth" || DrummerPadKind(rawValue: type) != nil
    }
    public func addsInstrument(comparedTo previous: NativeFXSettings) -> Bool {
        inserted.contains { !previous.inserted.contains($0) && isInstrument($0) }
    }
    public var hasDrummerPad: Bool { effectKeys.contains { DrummerPadKind(rawValue: kind(of: $0)) != nil && isEnabled($0) } }
    public var hasNativeMIDIInstrument: Bool {
        hasDrummerPad || effectKeys.contains { kind(of: $0) == "CatSynth" && isEnabled($0) }
    }
    public var midiArpeggio: NativeArpeggiatorSettings? {
        guard let key = effectKeys.first(where: { kind(of: $0) == "Arpeggiator" && isEnabled($0) }) else { return nil }
        return settings(for: key).arpeggiator ?? NativeArpeggiatorSettings()
    }
    public var arpeggiatesMIDI: Bool { midiArpeggio != nil }
    public var allBypassed: Bool { !inserted.isEmpty && inserted.allSatisfy { !isEnabled($0) } }
    public mutating func setStripBypass(_ on: Bool, fromSession: Bool) {
        if on {
            guard mixerBypassRestore == nil else { return }
            mixerBypassRestore = effectKeys.filter(isEnabled)
            bypassAppliedBySession = fromSession ? true : nil
            setAllBypassed(true)
        } else if let restore = mixerBypassRestore {
            mixerBypassRestore = nil
            bypassAppliedBySession = nil
            for key in restore where inserted.contains(key) { setEnabled(key, enabled: true) }
        }
    }
    public mutating func maintainStripBypass() {
        guard var restore = mixerBypassRestore else { return }
        for key in effectKeys where isEnabled(key) {
            if !restore.contains(key) { restore.append(key) }
            setEnabled(key, enabled: false)
        }
        mixerBypassRestore = restore.filter { inserted.contains($0) }
    }
    public mutating func setAllBypassed(_ bypassed: Bool) {
        for effect in inserted { setEnabled(effect, enabled: !bypassed) }
    }
    /// Item audio keeps the original native stages before repeated inserts
    /// and external plugins. Show that execution order without rewriting the
    /// persisted insertion order. Explicit reordering promotes these legacy
    /// stages to ordinary independent inserts before changing their order.
    public var clipEffectKeys: [String] {
        let originals = ([Self.waveLFOName] + Self.order.dropFirst()).filter { inserted.contains($0) }
        return originals + effectKeys.filter { !originals.contains($0) }
    }
    /// Keep the existing document/audio format: independent native instances
    /// already execute in insertion order on every platform. Promote only on
    /// an actual move, leaving unopened/unchanged legacy chains untouched.
    @discardableResult public mutating func reorderClipEffect(_ effect: String, before target: String?) -> String? {
        let current = clipEffectKeys
        guard effect != Self.waveLFOName, target != Self.waveLFOName, effect != target, current.contains(effect), target == nil || current.contains(target!) else { return nil }
        var ordered = current.filter { $0 != effect }
        ordered.insert(effect, at: target.flatMap { ordered.firstIndex(of: $0) } ?? ordered.count)
        guard ordered != current else { return nil }
        var replacements: [String: String] = [:]
        var promoted: [NativeFXInstance] = []
        for key in Self.order.dropFirst() where inserted.contains(key) {
            var value = Self().merging(effect: key, from: self)
            value.inserted = [key]
            var instance = NativeFXInstance(kind: key, settings: value)
            instance.legacyOrigin = key
            replacements[key] = instance.effectKey; promoted.append(instance)
        }
        // Bypass the old stages without resetting their coefficients while
        // their audio graph is still live. Resetting an EQ to default cuts
        // during its bypass ramp would briefly filter the signal twice.
        for key in replacements.keys { setEnabled(key, enabled: false) }
        instances = (instances ?? []) + promoted
        inserted = ordered.map { replacements[$0] ?? $0 }
        return replacements[effect] ?? effect
    }
    public func kind(of key: String) -> String { instances?.first { $0.effectKey == key }?.kind ?? key }
    public func settings(for key: String) -> Self { instances?.first { $0.effectKey == key }?.settings ?? self }
    public var instrumentKeys: [String] { inserted.filter { kind(of: $0) == "Instruments" && settings(for: $0).instrumentID != nil } }
    @discardableResult public mutating func appendNative(_ kind: String, instrument: String? = nil, parameters: InstrumentParameters? = nil, asInstance: Bool = false) -> String {
        if kind == Self.waveLFOName {
            if !inserted.contains(kind) { inserted.insert(kind, at: 0) }
            setEnabled(kind, enabled: true)
            return kind
        }
        if kind == Self.stemSeparator { return kind } // Removed: separation is an offline item action.
        if !asInstance && !inserted.contains(kind) {
            // A new insertion owns fresh parameters, including legacy projects
            // that retained values after removing their original native stage.
            self = merging(effect: kind, from: Self())
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
    public mutating func removeEffect(_ key: String) {
        guard inserted.contains(key) else { return }
        if Self.order.contains(key) || key == Self.waveLFOName || key == Self.stemSeparator {
            self = merging(effect: key, from: Self())
            if key == "Instruments" { instrumentBypassed = nil }
        }
        inserted.removeAll { $0 == key }
        externalPlugins?.removeAll { $0.effectKey == key }
        removeInstance(key)
    }

    public func isEnabled(_ effect: String) -> Bool {
        if let instance = instances?.first(where: { $0.effectKey == effect }) { return instance.settings.isEnabled(instance.kind) }
        if let plugin = externalPlugins?.first(where: { $0.effectKey == effect }) { return !plugin.bypassed }
        if effect == Self.waveLFOName { return waveLFOEnabled == true }
        if effect == Self.reverbConvolution { return convolutionEnabled == true }
        if effect == NativeCreativeEffect.graphicEQ.rawValue { return graphicEQEnabled == true }
        switch effect { case "CatSynth": return catSynthEnabled == true; case "Drummer Pad 16": return drummer16Enabled == true; case "Drummer Pad 48": return drummer48Enabled == true; case "Arpeggiator": return arpeggiatorEnabled == true; case "Chorus": return chorusEnabled == true; case "Phaser": return phaserEnabled == true; case "Amp": return ampEnabled == true; case "Soft Clipper": return softClipperEnabled == true; case "Gate Divisor": return divisionGateEnabled == true; case "CatLive Trigger": return triggerEnabled == true; case "Cat Gate": return gateEnabled == true; case Self.stemSeparator: return false; case "Instruments": return instrumentID != nil && instrumentBypassed != true; case "EQ": return eqEnabled; case "Compressor": return compressorEnabled; case "Limiter": return limiterEnabled == true; case "Pitch": return pitchEnabled == true; case "Delay": return delayEnabled; case "Reverb": return reverbEnabled; default: return false }
    }
    public mutating func setEnabled(_ effect: String, enabled: Bool) {
        if let index = instances?.firstIndex(where: { $0.effectKey == effect }), let kind = instances?[index].kind { instances?[index].settings.setEnabled(kind, enabled: enabled); return }
        if let index = externalPlugins?.firstIndex(where: { $0.effectKey == effect }) { externalPlugins?[index].bypassed = !enabled; return }
        if effect == Self.waveLFOName { waveLFOEnabled = enabled; return }
        if effect == Self.reverbConvolution { convolutionEnabled = enabled; return }
        if effect == NativeCreativeEffect.graphicEQ.rawValue { graphicEQEnabled = enabled; return }
        switch effect { case "CatSynth": catSynthEnabled = enabled; case "Drummer Pad 16": drummer16Enabled = enabled; case "Drummer Pad 48": drummer48Enabled = enabled; case "Arpeggiator": arpeggiatorEnabled = enabled; case "Chorus": chorusEnabled = enabled; case "Phaser": phaserEnabled = enabled; case "Amp": ampEnabled = enabled; case "Soft Clipper": softClipperEnabled = enabled; case "Gate Divisor": divisionGateEnabled = enabled; case "CatLive Trigger": triggerEnabled = enabled; case "Cat Gate": gateEnabled = enabled; case Self.stemSeparator:
            stemSeparatorEnabled = enabled
            // Older projects used CatStem only as an offline editor. Opening
            // them must not silently insert a new high-latency audio processor.
            if enabled && stemMix == nil { stemMix = NativeStemMix() }
        case "Instruments": instrumentBypassed = !enabled; case "EQ": eqEnabled = enabled; case "Compressor": compressorEnabled = enabled; case "Limiter": limiterEnabled = enabled; case "Pitch": pitchEnabled = enabled; case "Delay": delayEnabled = enabled; case "Reverb": reverbEnabled = enabled; default: break }
    }
    /// Editors for different effects can remain open; each updates only its own parameters.
    public func merging(effect: String, from draft: Self) -> Self {
        var next = self
        if let index = next.instances?.firstIndex(where: { $0.effectKey == effect }), let instance = next.instances?[index] {
            next.instances?[index].settings = instance.settings.merging(effect: instance.kind, from: draft.settings(for: effect))
            return next
        }
        if let creative = NativeCreativeEffect(rawValue: effect) {
            next.setEnabled(effect, enabled: draft.isEnabled(effect))
            next.setCreativeParameters(draft.creativeParameters(creative), for: creative)
            return next
        }
        if effect == Self.waveLFOName {
            next.waveLFOEnabled = draft.waveLFOEnabled
            next.waveLFO = draft.waveLFO
            return next
        }
        if effect == Self.reverbConvolution {
            next.convolutionEnabled = draft.convolutionEnabled
            next.convolution = draft.convolution
            return next
        }
        next.setChannels(draft.channels(for: effect), for: effect)
        switch effect {
        case "CatSynth": next.catSynth = draft.catSynth; next.catSynthEnabled = draft.catSynthEnabled
        case "Drummer Pad 16": next.drummer16 = draft.drummer16; next.drummer16Enabled = draft.drummer16Enabled
        case "Drummer Pad 48": next.drummer48 = draft.drummer48; next.drummer48Enabled = draft.drummer48Enabled
        case "Arpeggiator": next.arpeggiatorEnabled = draft.arpeggiatorEnabled; next.arpeggiator = draft.arpeggiator
        case "CatLive Trigger": next.triggerEnabled = draft.triggerEnabled; next.trigger = draft.trigger
        case "Cat Gate": next.gateEnabled = draft.gateEnabled; next.gate = draft.gate
        case Self.stemSeparator: next.stemSeparatorEnabled = draft.stemSeparatorEnabled; next.stemMix = draft.stemMix
        case "Instruments": next.instrumentID = draft.instrumentID; next.instrumentParameters = draft.instrumentParameters
        case "EQ": next.eqEnabled = draft.eqEnabled; next.bands = draft.bands
        case "Compressor":
            next.compressorEnabled = draft.compressorEnabled; next.threshold = draft.threshold; next.ratio = draft.ratio
            next.attack = draft.attack; next.release = draft.release; next.makeup = draft.makeup
        case "Limiter": next.limiterEnabled = draft.limiterEnabled; next.limiter = draft.limiter
        case "Pitch": next.pitchEnabled = draft.pitchEnabled; next.pitchSemitones = draft.pitchSemitones; next.pitchFormant = draft.pitchFormant
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
        case NativeFXSettings.stemSeparator: return NativeFXSettings.stemSeparator
        case "CatLive Trigger", "Cat Gate": return effect
        case "EQ": return "CatLive EQ"
        case "Reverb": return "CatLive Reverb"
        case "Pitch": return "CatLive Pitch"
        case "Delay": return "CatLive Delay"
        case "Compressor": return "CatLive Compressor"
        case "Limiter": return "CatLive Limiter"
        case "Instruments": return "CatLive Instruments"
        default: return effect
        }
    }
}

public extension NativeFXSettings {
    var samplePaths: Set<String> {
        var paths = Set<String>()
        if inserted.contains("CatLive Trigger"), let path = trigger?.samplePath { paths.insert(path) }
        if inserted.contains(Self.reverbConvolution), let path = convolution?.impulsePath { paths.insert(path) }
        for instance in instances ?? [] where inserted.contains(instance.effectKey) { paths.formUnion(instance.settings.samplePaths) }
        return paths
    }
    mutating func remapSamples(_ mapping: [String:String]) {
        if let path = trigger?.samplePath, let replacement = mapping[path] { trigger?.samplePath = replacement }
        if let path = convolution?.impulsePath, let replacement = mapping[path] { convolution?.impulsePath = replacement }
        for i in (instances ?? []).indices { instances?[i].settings.remapSamples(mapping) }
    }
}
