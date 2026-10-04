import AVFoundation
import AudioToolbox

struct EQAnalysisFrame: Sendable {
    let input: Data?
    let output: Data?
    let sampleRate: Double
}

// Each chain is confined to its owning audio graph/control thread. Offline
// export owns separate instances and never touches the live graph.
final class NativeEffectsChain {
    private let reorderable: Bool
    init(reorderable: Bool = true) { self.reorderable = reorderable }
    let equalizer = JarasEqualizer.makeNode()
    let compressor = JarasDynamics.makeCompressor()
    private var limiter: AVAudioUnitEffect?
    private var pitch: AVAudioUnitTimePitch?
    let delay = AVAudioUnitDelay()
    let reverb = JarasDynamics.makeReverb()
    private let outputMix = AVAudioMixerNode()
    private var instanceNodes: [String: AVAudioNode] = [:]
    private var instanceDelayProbes: [String: (JarasAudioAnalysisProbe, JarasAudioAnalysisProbe)] = [:]
    private var observedEffects = Set<String>()
    func instrumentInput(for key: String) -> AVAudioMixerNode? {
        key == "Instruments" ? instrumentInput : instanceNodes[key] as? AVAudioMixerNode
    }
    private func configureInstances(_ next: NativeFXSettings, rate: Double) {
        for instance in next.instances ?? [] where next.inserted.contains(instance.effectKey) {
            let key = instance.effectKey, value = instance.settings
            let node: AVAudioNode
            if let existing = instanceNodes[key] { node = existing }
            else {
                switch instance.kind {
                case "Instruments": node = AVAudioMixerNode()
                case "EQ": node = JarasEqualizer.makeNode()
                case "Compressor": node = JarasDynamics.makeCompressor()
                case "Limiter": node = JarasDynamics.makeLimiter()
                case "Pitch": let pitch = AVAudioUnitTimePitch(); pitch.rate = 1; pitch.overlap = 8; node = pitch
                case "Delay": node = AVAudioUnitDelay()
                default: node = JarasDynamics.makeReverb()
                }
                instanceNodes[key] = node; engine?.attach(node)
            }
            if settings?.settings(for: key) == value && rate == sampleRate { continue }
            switch instance.kind {
            case "EQ":
                JarasEqualizer.configure(node as! AVAudioUnitEffect, coefficients: value.bands.flatMap { $0.coefficients(rate: rate) }.map { $0.map(NSNumber.init(value:)) }, enabled: value.eqEnabled)
            case "Compressor":
                JarasDynamics.configureCompressor(node as! AVAudioUnitEffect, enabled: value.compressorEnabled, threshold: value.threshold, ratio: value.ratio, attack: value.attack, release: value.release, gain: value.makeup)
            case "Limiter":
                let parameters = value.limiterParameters
                JarasDynamics.configureLimiter(node as! AVAudioUnitEffect, enabled: value.limiterEnabled == true, gain: parameters.inputGain, ceiling: parameters.ceiling, release: parameters.release)
            case "Pitch":
                let pitch = node as! AVAudioUnitTimePitch
                pitch.pitch = Float(value.semitones * 100); pitch.bypass = value.pitchEnabled != true || value.semitones == 0
            case "Delay":
                let delay = node as! AVAudioUnitDelay
                delay.bypass = !value.delayEnabled; delay.delayTime = value.delayTime
                delay.feedback = Float(value.feedback); delay.wetDryMix = Float(value.delayMix)
            case "Reverb":
                JarasDynamics.configureReverb(node as! AVAudioUnitEffect, enabled: value.reverbEnabled, space: value.reverbRoom, mix: value.reverbMix, decay: value.reverbDecay, lowCut: value.reverbLowCut, highCut: value.reverbHighCut)
            default: break
            }
        }
    }
    private weak var engine: AVAudioEngine?
    private var input: AVAudioNode?
    private var format: AVAudioFormat?
    private var connected: [AVAudioNode] = []
    private var instrumentMix: AVAudioMixerNode?
    private var observesDelay = false
    private var delayInputProbe: JarasAudioAnalysisProbe?
    private var delayOutputProbe: JarasAudioAnalysisProbe?
    #if os(macOS)
    private(set) var externalNodes: [String: AVAudioUnitEffect] = [:]
    var externalError: Error?
    private var instrumentMIDIInput = false
    func enableInstrumentMIDI(_ enabled: Bool) {
        instrumentMIDIInput = enabled
        for node in externalNodes.values { JarasVST3.instrumentMIDIInput(node, enabled: enabled) }
    }
    func externalNode(_ identifier: String) -> AVAudioUnitEffect? { externalNodes[identifier] }
    func prepareExternal(_ plugin: ExternalPlugin) throws -> AVAudioUnitEffect {
        let node: AVAudioUnitEffect
        if let existing = externalNodes[plugin.id] { node = existing }
        else {
            node = JarasVST3.makeNode()
            if let engine { engine.attach(node) }
            if let format {
                try node.auAudioUnit.inputBusses[0].setFormat(format)
                try node.auAudioUnit.outputBusses[0].setFormat(format)
            }
            externalNodes[plugin.id] = node
        }
        let data = try JSONEncoder().encode([plugin])
        try JarasVST3.configure(node, plugins: JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [])
        JarasVST3.instrumentMIDIInput(node, enabled: instrumentMIDIInput)
        JarasVST3.setSequence(node, notes: midiSequenceNotes)
        return node
    }
    private var midiSequenceNotes: [[String: Double]] = []
    func setMIDISequence(_ notes: [[String: Double]]) {
        guard midiSequenceNotes != notes else { return }
        midiSequenceNotes = notes
        for node in externalNodes.values { JarasVST3.setSequence(node, notes: notes) }
    }
    func setMIDISequenceClock(head: Int, position: Double, clock: Double, running: Bool, loopStart: Double, loopEnd: Double) {
        for node in externalNodes.values { JarasVST3.sequenceClock(node, head: Int32(head), position: position, clock: clock, running: running, loopStart: loopStart, loopEnd: loopEnd) }
    }
    func sendExternalMIDI(status: UInt8, number: UInt8, value: UInt8) {
        for node in externalNodes.values { JarasVST3.sendMIDI(node, status: status, data1: number, data2: value) }
    }
    func silenceExternal() { for node in externalNodes.values { JarasVST3.silence(node) } }
    func releaseExternal() {
        for node in externalNodes.values { try? JarasVST3.configure(node, plugins: []) }
    }
    func externalTransport(position: Double, tempo: Double, beats: Int32, unit: Int32, playing: Bool) {
        for node in externalNodes.values { JarasVST3.transport(node, position: position, tempo: tempo, beats: beats, unit: unit, playing: playing) }
    }
    #endif
    private var nodes: [AVAudioUnit] {
        #if os(macOS)
        return [equalizer, compressor, delay, reverb] + (pitch.map { [$0] } ?? []) + (limiter.map { [$0] } ?? []) + Array(externalNodes.values)
        #else
        return [equalizer, compressor, delay, reverb] + (pitch.map { [$0] } ?? []) + (limiter.map { [$0] } ?? [])
        #endif
    }
    var output: AVAudioNode { outputMix }
    func setSourceChannelMode(_ mode: Int) { JarasEqualizer.setInputChannelMode(equalizer, mode: Int32(mode)) }
    private var itemFadeClock: (position: Double, host: UInt64, sample: Double) = (0, 0, 0)
    func configureItemFade(_ clip: AudioClip, position: Double, hostTime: UInt64 = 0, sampleTime: Double = 0) {
        itemFadeClock = (position - (clip.fadeTimelineStart ?? clip.startTime), hostTime, sampleTime)
        updateItemFade(clip)
    }
    func updateItemFade(_ clip: AudioClip) {
        JarasEqualizer.setInputFade(equalizer, fadeIn: clip.fadeIn ?? 0, fadeOut: clip.fadeOut ?? 0,
                                    duration: clip.fadeTimelineDuration ?? clip.duration, position: itemFadeClock.position,
                                    hostTime: itemFadeClock.host, sampleTime: itemFadeClock.sample)
    }
    func setPlaybackBoundary(_ host: UInt64 = 0) { JarasEqualizer.setPlaybackBoundary(equalizer, hostTime: host) }
    func setSourceGain(_ gain: Double) { JarasEqualizer.setInputGain(equalizer, gain: gain) }
    var instrumentInput: AVAudioMixerNode {
        if let instrumentMix { return instrumentMix }
        let mixer = AVAudioMixerNode(); instrumentMix = mixer
        if let engine { engine.attach(mixer); connect(settings ?? NativeFXSettings()) }
        return mixer
    }
    private var settings: NativeFXSettings?
    private var sampleRate = 0.0
    func attach(to engine: AVAudioEngine, input: AVAudioNode, format: AVAudioFormat, destinations: [AVAudioConnectionPoint] = []) {
        self.engine = engine; self.input = input; self.format = format
        settings = nil; sampleRate = 0
        for node in nodes { engine.attach(node) }
        engine.attach(outputMix)
        if !destinations.isEmpty { engine.connect(output, to: destinations, fromBus: 0, format: format) }
        apply(NativeFXSettings())
    }
    private func connect(_ next: NativeFXSettings) {
        guard let engine, let input, let format else { return }
        var keys = reorderable ? next.effectKeys : Array(NativeFXSettings.order.dropFirst())
        // Uninserted native processors stay bypassed in the graph, preserving
        // their identity and avoiding reconnections for ordinary knob edits.
        keys += NativeFXSettings.order.dropFirst().filter { !keys.contains($0) }
        if instrumentMix != nil && !keys.contains("Instruments") { keys.insert("Instruments", at: 0) }
        let ordered: [AVAudioNode] = keys.compactMap { key in
            if let node = instanceNodes[key] { return node }
            switch key {
            case "Instruments": return instrumentMix
            case "EQ": return equalizer
            case "Compressor": return compressor
            case "Limiter": return limiter
            case "Pitch": return pitch
            case "Delay": return delay
            case "Reverb": return reverb
            default:
                #if os(macOS)
                return next.externalPlugins?.first(where: { $0.effectKey == key }).flatMap { externalNodes[$0.id] }
                #else
                return nil
                #endif
            }
        }
        guard ordered.map(ObjectIdentifier.init) != connected.map(ObjectIdentifier.init) else { return }
        delayInputProbe?.detach(); delayOutputProbe?.detach()
        // Keep the upstream players connected to a live destination while
        // rebuilding the processors. Disconnecting the input first causes
        // AVAudioEngine to discard their scheduled PCM during a live reorder.
        engine.connect(input, to: outputMix, fromBus: 0, toBus: 0, format: format)
        for node in connected { engine.disconnectNodeOutput(node) }
        var destination: AVAudioNode = outputMix
        for node in ordered.reversed() {
            if let mixer = destination as? AVAudioMixerNode { engine.connect(node, to: mixer, fromBus: 0, toBus: 0, format: format) }
            else { engine.connect(node, to: destination, format: format) }
            destination = node
        }
        if let mixer = destination as? AVAudioMixerNode { engine.connect(input, to: mixer, fromBus: 0, toBus: 0, format: format) }
        else { engine.connect(input, to: destination, format: format) }
        connected = ordered
        observe(observedEffects)
    }
    func resetTails() {
        for node in nodes { node.auAudioUnit.reset() }
        for node in instanceNodes.values { (node as? AVAudioUnit)?.auAudioUnit.reset() }
        meterTime = 0; meterCache.removeAll(keepingCapacity: true)
    }
    func detach(from engine: AVAudioEngine) {
        delayInputProbe?.detach(); delayOutputProbe?.detach()
        for probes in instanceDelayProbes.values { probes.0.detach(); probes.1.detach() }; instanceDelayProbes.removeAll()
        for node in instanceNodes.values { engine.detach(node) }; instanceNodes.removeAll()
        for node in nodes { engine.detach(node) }
        if let instrumentMix { engine.detach(instrumentMix) }
        engine.detach(outputMix); connected.removeAll(); self.engine = nil; input = nil
        instrumentMix = nil
        #if os(macOS)
        externalNodes.removeAll()
        #endif
    }
    func apply(_ next: NativeFXSettings) {
        let rate = max(8000, format?.sampleRate ?? equalizer.outputFormat(forBus: 0).sampleRate)
        #if os(macOS)
        let retained = Set((next.externalPlugins ?? []).filter { next.inserted.contains($0.effectKey) }.map(\.id))
        guard next != settings || rate != sampleRate || Set(externalNodes.keys) != retained else { return }
        #else
        guard next != settings || rate != sampleRate else { return }
        #endif
        #if os(macOS)
        do {
            for plugin in next.externalPlugins ?? [] where next.inserted.contains(plugin.effectKey) {
                if plugin != settings?.externalPlugins?.first(where: { $0.id == plugin.id }) || rate != sampleRate {
                    _ = try prepareExternal(plugin)
                }
            }
            externalError = nil
        } catch { externalError = error }
        #endif
        if next.inserted.contains("Pitch"), pitch == nil {
            let node = AVAudioUnitTimePitch(); node.rate = 1; node.overlap = 8
            pitch = node; engine?.attach(node)
        }
        if let pitch {
            pitch.pitch = Float(next.semitones * 100)
            pitch.bypass = !next.inserted.contains("Pitch") || next.pitchEnabled != true || next.semitones == 0
        }
        if next.inserted.contains("Limiter"), limiter == nil {
            let node = JarasDynamics.makeLimiter(); limiter = node; engine?.attach(node)
        }
        if let limiter {
            let parameters = next.limiterParameters
            JarasDynamics.configureLimiter(limiter, enabled: next.inserted.contains("Limiter") && next.limiterEnabled == true,
                gain: parameters.inputGain, ceiling: parameters.ceiling, release: parameters.release)
        }
        configureInstances(next, rate: rate)
        connect(next)
        let nativeRetained = Set((next.instances ?? []).filter { next.inserted.contains($0.effectKey) }.map(\.effectKey))
        for key in Set(instanceNodes.keys).subtracting(nativeRetained) {
            if let probes = instanceDelayProbes.removeValue(forKey: key) { probes.0.detach(); probes.1.detach() }
            if let node = instanceNodes.removeValue(forKey: key) { engine?.detach(node) }
        }
        #if os(macOS)
        for identifier in Set(externalNodes.keys).subtracting(retained) {
            if let node = externalNodes.removeValue(forKey: identifier) { engine?.detach(node) }
        }
        #endif
        let previous = settings
        let rateChanged = rate != sampleRate
        settings = next; sampleRate = rate
        if rateChanged || previous?.bands != next.bands || previous?.eqEnabled != next.eqEnabled {
            let coefficients = next.bands.flatMap { $0.coefficients(rate: rate) }.map { $0.map(NSNumber.init(value:)) }
            JarasEqualizer.configure(equalizer, coefficients: coefficients, enabled: next.eqEnabled)
        }
        if previous?.compressorEnabled != next.compressorEnabled || previous?.threshold != next.threshold || previous?.ratio != next.ratio || previous?.attack != next.attack || previous?.release != next.release || previous?.makeup != next.makeup {
            JarasDynamics.configureCompressor(compressor, enabled: next.compressorEnabled, threshold: next.threshold, ratio: next.ratio, attack: next.attack, release: next.release, gain: next.makeup)
        }
        if previous?.delayEnabled != next.delayEnabled { delay.bypass = !next.delayEnabled }
        if previous?.delayTime != next.delayTime { delay.delayTime = next.delayTime }
        if previous?.feedback != next.feedback { delay.feedback = Float(next.feedback) }
        if previous?.delayMix != next.delayMix { delay.wetDryMix = Float(next.delayMix) }
        if previous?.reverbEnabled != next.reverbEnabled || previous?.reverbRoom != next.reverbRoom || previous?.reverbMix != next.reverbMix || previous?.reverbDecay != next.reverbDecay || previous?.reverbLowCut != next.reverbLowCut || previous?.reverbHighCut != next.reverbHighCut {
            JarasDynamics.configureReverb(reverb, enabled: next.reverbEnabled, space: next.reverbRoom, mix: next.reverbMix, decay: next.reverbDecay, lowCut: next.reverbLowCut, highCut: next.reverbHighCut)
        }
    }
    private var meterTime = 0.0
    private var meterCache: [String:[Float]] = [:]
    func observe(_ effects: Set<String>) {
        observedEffects = effects
        for (key, node) in instanceNodes {
            let enabled = effects.contains(key)
            switch settings?.kind(of: key) {
            case "EQ": JarasEqualizer.setAnalysisEnabled(node as! AVAudioUnitEffect, enabled: enabled)
            case "Compressor", "Limiter": JarasDynamics.setCompressorMeteringEnabled(node as! AVAudioUnitEffect, enabled: enabled)
            case "Reverb":
                JarasDynamics.setAnalysisEnabled(node as! AVAudioUnitEffect, input: true, enabled: enabled)
                JarasDynamics.setAnalysisEnabled(node as! AVAudioUnitEffect, input: false, enabled: enabled)
            case "Delay":
                if enabled, let index = connected.firstIndex(where: { $0 === node }), let predecessor = index > 0 ? connected[index - 1] : input {
                    let probes = instanceDelayProbes[key] ?? (JarasAudioAnalysisProbe(), JarasAudioAnalysisProbe())
                    instanceDelayProbes[key] = probes; probes.0.attach(to: predecessor); probes.1.attach(to: node)
                } else if let probes = instanceDelayProbes[key] { probes.0.detach(); probes.1.detach() }
            default: break
            }
        }
        JarasEqualizer.setAnalysisEnabled(equalizer, enabled: effects.contains("EQ"))
        JarasDynamics.setCompressorMeteringEnabled(compressor, enabled: effects.contains("Compressor"))
        if let limiter { JarasDynamics.setCompressorMeteringEnabled(limiter, enabled: effects.contains("Limiter")) }
        JarasDynamics.setAnalysisEnabled(reverb, input: true, enabled: effects.contains("Reverb"))
        JarasDynamics.setAnalysisEnabled(reverb, input: false, enabled: effects.contains("Reverb"))
        observesDelay = effects.contains("Delay"); updateDelayAnalysis()
    }
    private func updateDelayAnalysis() {
        guard observesDelay, let index = connected.firstIndex(where: { $0 === delay }),
              let predecessor = index > 0 ? connected[index - 1] : input else {
            delayInputProbe?.detach(); delayOutputProbe?.detach(); return
        }
        if delayInputProbe == nil { delayInputProbe = JarasAudioAnalysisProbe() }
        if delayOutputProbe == nil { delayOutputProbe = JarasAudioAnalysisProbe() }
        delayInputProbe?.attach(to: predecessor); delayOutputProbe?.attach(to: delay)
    }
    func spectrum(_ effect: String) -> Data? {
        if let node = instanceNodes[effect] {
            if node is AVAudioUnitDelay { return instanceDelayProbes[effect]?.1.frame() }
            return (node as? AVAudioUnitEffect).flatMap { JarasDynamics.analysisFrame($0, input: false) }
        }
        return effect == "Delay" ? delayOutputProbe?.frame() : JarasDynamics.analysisFrame(reverb, input: false)
    }
    func eqSpectrumFrame(_ effect: String = "EQ") -> EQAnalysisFrame? {
        let equalizer = (instanceNodes[effect] as? AVAudioUnitEffect) ?? self.equalizer
        let input = JarasEqualizer.analysisFrame(equalizer, input: true)
        let output = JarasEqualizer.analysisFrame(equalizer, input: false)
        guard input != nil || output != nil else { return nil }
        return EQAnalysisFrame(input: input, output: output, sampleRate: equalizer.outputFormat(forBus: 0).sampleRate)
    }
    func effectPeaks(_ effect: String) -> [Float] {
        if let node = instanceNodes[effect] {
            switch settings?.kind(of: effect) {
            case "Compressor", "Limiter": return JarasDynamics.takeCompressorPeaks(node as! AVAudioUnitEffect).map(\.floatValue)
            case "Reverb": return JarasDynamics.analysisPeaks(node as! AVAudioUnitEffect, input: true).map(\.floatValue) + JarasDynamics.analysisPeaks(node as! AVAudioUnitEffect, input: false).map(\.floatValue)
            case "Delay": return (instanceDelayProbes[effect]?.0.takePeaks().map(\.floatValue) ?? [0,0]) + (instanceDelayProbes[effect]?.1.takePeaks().map(\.floatValue) ?? [0,0])
            default: return [0,0,0,0]
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - meterTime > 1.0 / 40 {
            meterTime = now
            let compressor = compressorPeaks()
            let delayIn = delayInputProbe?.takePeaks().map(\.floatValue) ?? [0, 0]
            let delayOut = delayOutputProbe?.takePeaks().map(\.floatValue) ?? [0, 0]
            let reverbIn = JarasDynamics.analysisPeaks(reverb, input: true).map(\.floatValue)
            let reverbOut = JarasDynamics.analysisPeaks(reverb, input: false).map(\.floatValue)
            meterCache = ["Compressor":compressor, "Delay":delayIn+delayOut, "Reverb":reverbIn+reverbOut, "Limiter":limiter.map { JarasDynamics.takeCompressorPeaks($0).map(\.floatValue) } ?? [0,0,0,0]]
        }
        return meterCache[effect] ?? [0,0,0,0]
    }
    func compressorPeaks() -> [Float] { JarasDynamics.takeCompressorPeaks(compressor).map(\.floatValue) }
}
