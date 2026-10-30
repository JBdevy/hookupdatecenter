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
    init(reorderable: Bool = true) {
        self.reorderable = reorderable
        if reorderable {
            equalizer = JarasEqualizer.makeNode()
            compressor = JarasDynamics.makeCompressor()
        } else {
            let node = JarasDynamics.makeItemEqualizerCompressor()
            equalizer = node; compressor = node
        }
    }
    let equalizer: AVAudioUnitEffect
    let compressor: AVAudioUnitEffect
    private var limiter: AVAudioUnitEffect?
    private var trigger: AVAudioUnitEffect?
    private var gate: AVAudioUnitEffect?
    /// Paths in project documents stay relative; every graph owns its folder.
    var mediaDirectory: URL? {
        didSet {
            if mediaDirectory != oldValue { triggerSamplePaths.removeAll(); settings = nil }
        }
    }
    var triggerTailDuration: Double {
        guard let settings else { return 0 }
        return settings.effectKeys.reduce(0) { total, key in
            guard settings.kind(of: key) == "CatLive Trigger", settings.isEnabled(key),
                  let node = key == "CatLive Trigger" ? trigger : instanceNodes[key] as? AVAudioUnitEffect else { return total }
            return total + JarasDynamics.triggerSampleDuration(node)
        }
    }
    private var triggerSamplePaths: [String: String] = [:]
    private(set) var sampleErrors: [String: String] = [:]
    private func configureTrigger(_ node: AVAudioUnitEffect, key: String, value: NativeFXSettings, enabled: Bool) {
        let p = value.triggerParameters
        let path = p.samplePath ?? ""
        if triggerSamplePaths[key] != path {
            triggerSamplePaths[key] = path
            do {
                let url: URL?
                if path.isEmpty { url = nil }
                else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
                else if let mediaDirectory { url = mediaDirectory.appendingPathComponent(path) }
                else { throw ProjectError.invalid("The project folder is unavailable.") }
                try JarasDynamics.loadTriggerSample(node, url: url)
                sampleErrors[key] = nil
            } catch {
                try? JarasDynamics.loadTriggerSample(node, url: nil)
                sampleErrors[key] = error.localizedDescription
            }
        }
        JarasDynamics.configureTrigger(node, enabled: enabled, threshold: p.threshold, retrigger: p.retrigger,
            gain: p.gain, mix: p.mix, attack: p.attack, decay: p.decay, sustain: p.sustain, release: p.release)
    }
    private func configureGate(_ node: AVAudioUnitEffect, value: NativeFXSettings, enabled: Bool) {
        let p = value.gateParameters
        JarasDynamics.configureGate(node, enabled: enabled, threshold: p.threshold, attack: p.attack,
            decay: p.decay, hold: p.hold, release: p.release, highPass: p.highPass,
            lowPass: p.lowPass, filterOutput: p.filterOutput)
    }
    private var pitch: AVAudioUnitTimePitch?
    let delay = AVAudioUnitDelay()
    let reverb = JarasDynamics.makeReverb()
    private var itemInputMix: AVAudioMixerNode?
    private var trackEntryMix: AVAudioMixerNode?
    private let outputMix = AVAudioMixerNode()
    private var outputDestination: AVAudioNode?
    private var instanceNodes: [String: AVAudioNode] = [:]
    private var instanceDelayProbes: [String: (JarasAudioAnalysisProbe, JarasAudioAnalysisProbe)] = [:]
    // Adjacent delays share one boundary: the first output is the next input.
    // AVAudioNode permits only one tap per bus, even during an editor switch.
    private var delayAnalysisProbes: [ObjectIdentifier: JarasAudioAnalysisProbe] = [:]
    private var delayAnalysisPeaks: [ObjectIdentifier: (time: Double, values: [Float])] = [:]
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
                case "CatLive Trigger": node = JarasDynamics.makeTrigger()
                case "Cat Gate": node = JarasDynamics.makeGate()
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
            case "CatLive Trigger":
                configureTrigger(node as! AVAudioUnitEffect, key: key, value: value, enabled: value.triggerEnabled == true)
            case "Cat Gate":
                configureGate(node as! AVAudioUnitEffect, value: value, enabled: value.gateEnabled == true)
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
    // Keep processors ready for live edits, but do not render unused ones.
    // Once activated they retain their graph position through bypass ramps.
    private var preparedEffects: Set<String> = ["EQ"]
    private var instrumentMix: AVAudioMixerNode?
    private var observesDelay = false
    private var delayInputProbe: JarasAudioAnalysisProbe?
    private var delayOutputProbe: JarasAudioAnalysisProbe?
    private var stemSeparatorNode: AVAudioUnitEffect?
    private var stemSeparatorStarted = false
    private var stemSeparatorError: String?
    var stemSeparatorStatus: [String: Any]? {
        if let stemSeparatorError { return ["state": "fault", "error": stemSeparatorError] }
        return stemSeparatorNode.map { JarasStemSeparator.status($0) }
    }
    private func configureStemSeparator(_ next: NativeFXSettings) {
        // Legacy projects keep their serialized settings, but separation now
        // generates files from the item menu and never runs in the FX graph.
        stopStemSeparator()
    }
    /// Only offline export may wait for model warmup. UI/audio control paths
    /// start asynchronously and expose progress through stemSeparatorStatus.
    func waitForStemSeparator(cancellation: () -> Bool) throws {
        guard let node = stemSeparatorNode else { return }
        if let stemSeparatorError { throw ProjectError.invalid(stemSeparatorError) }
        guard stemSeparatorStarted else { return }
        let limit = ProcessInfo.processInfo.systemUptime + 60
        while ProcessInfo.processInfo.systemUptime < limit {
            if cancellation() { throw CancellationError() }
            let report = JarasStemSeparator.status(node)
            let state = report["state"] as? String ?? "loading"
            if state == "fault" { throw ProjectError.invalid(report["error"] as? String ?? "CatStem processing failed") }
            if ["priming", "running", "bypassed"].contains(state) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw ProjectError.invalid("CatStem demorou demais para iniciar.")
    }
    var stemSeparatorLatency: Double { stemSeparatorNode?.auAudioUnit.latency ?? 0 }
    /// Cancel a model process while its chain is still owned. Full graph
    /// teardown also cancels it in detach. Cancellation is asynchronous;
    /// the UI never waits for worker termination.
    func stopStemSeparator() {
        guard let node = stemSeparatorNode else { return }
        JarasStemSeparator.stop(node)
        stemSeparatorStarted = false; stemSeparatorError = nil
    }
    /// Export owns this chain on its worker thread and must release its model
    /// lease before starting the next render batch.
    func stopStemSeparatorAndWait() throws {
        guard let node = stemSeparatorNode else { return }
        try JarasStemSeparator.stopAndWait(node, timeout: 5)
        stemSeparatorStarted = false
    }
    func resumeStemSeparator() {
        if engine != nil, let settings { configureStemSeparator(settings) }
    }
    var stemSeparatorWorkerRunning: Bool {
        guard let node = stemSeparatorNode else { return false }
        return JarasStemSeparator.status(node)["workerRunning"] as? Bool == true
    }
    #if os(macOS)
    private(set) var externalNodes: [String: AVAudioUnitEffect] = [:]
    var externalError: Error?
    private var failedExternalPlugins: [String: (ExternalPlugin, Error)] = [:]
    private var instrumentMIDIInput = false
    func enableInstrumentMIDI(_ enabled: Bool) {
        instrumentMIDIInput = enabled
        for node in externalNodes.values { JarasVST3.instrumentMIDIInput(node, enabled: enabled) }
    }
    func externalNode(_ identifier: String) -> AVAudioUnitEffect? {
        guard let node = externalNodes[identifier], JarasVST3.isPluginLoaded(node, identifier: identifier) else { return nil }
        return node
    }
    /// The processor already owns this state. A Save only updates the cached
    /// description, so a later native-parameter edit cannot restore an old preset.
    func rememberCapturedPluginState(_ plugin: ExternalPlugin, source: AVAudioUnitEffect) {
        guard externalNodes[plugin.id] === source,
              let index = settings?.externalPlugins?.firstIndex(where: { $0.id == plugin.id }) else { return }
        settings?.externalPlugins?[index].componentState = plugin.componentState
        settings?.externalPlugins?[index].controllerState = plugin.controllerState
    }
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
        // AVAudioEngine propagates this flag only during prepare/start. VST3
        // setupProcessing happens now, while the export graph is being built,
        // so the processor must receive its owning graph's mode explicitly.
        let offline = engine?.isInManualRenderingMode == true && engine?.manualRenderingMode == .offline
        if node.auAudioUnit.isRenderingOffline != offline { node.auAudioUnit.isRenderingOffline = offline }
        let data = try JSONEncoder().encode([plugin])
        try JarasVST3.configure(node, plugins: JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [])
        JarasVST3.instrumentMIDIInput(node, enabled: instrumentMIDIInput)
        JarasVST3.setSequence(node, notes: !midiSequenceInstrumentsOnly || plugin.category.contains("Instrument") ? midiSequenceNotes : [])
        return node
    }
    private var midiSequenceNotes: [[String: Double]] = []
    private var midiSequenceInstrumentsOnly = false
    func setMIDISequence(_ notes: [[String: Double]], instrumentsOnly: Bool = false, preserveHeld: Bool = false) {
        guard midiSequenceNotes != notes || midiSequenceInstrumentsOnly != instrumentsOnly || preserveHeld else { return }
        midiSequenceNotes = notes; midiSequenceInstrumentsOnly = instrumentsOnly
        for (id, node) in externalNodes {
            let instrument = settings?.externalPlugins?.first(where: { $0.id == id })?.category.contains("Instrument") == true
            JarasVST3.setSequence(node, notes: !instrumentsOnly || instrument ? notes : [], preserveHeld: preserveHeld)
        }
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
        var result: [AVAudioUnit] = [equalizer]
        if equalizer !== compressor { result.append(compressor) }
        result.append(delay)
        result.append(reverb)
        if let pitch { result.append(pitch) }
        if let limiter { result.append(limiter) }
        if let trigger { result.append(trigger) }
        if let gate { result.append(gate) }
        if let stemSeparatorNode { result.append(stemSeparatorNode) }
        #if os(macOS)
        for node in externalNodes.values { result.append(node) }
        #endif
        return result
    }
    var output: AVAudioNode { outputDestination ?? outputMix }
    func setSourceChannelMode(_ mode: Int) { JarasEqualizer.setInputChannelMode(equalizer, mode: Int32(mode)) }
    private var itemFadeClock: (position: Double, host: UInt64, sample: Double) = (0, 0, 0)
    func configureItemFade(_ clip: AudioClip, position: Double, hostTime: UInt64 = 0, sampleTime: Double = 0) {
        itemFadeClock = (position - (clip.fadeTimelineStart ?? clip.startTime), hostTime, sampleTime)
        updateItemFade(clip)
    }
    func updateItemFade(_ clip: AudioClip) {
        JarasEqualizer.setInputFade(equalizer, fadeIn: clip.fadeIn ?? 0, fadeOut: clip.fadeOut ?? 0,
                                    fadeInCurve: clip.fadeInCurve ?? 0, fadeInSCurve: clip.fadeInSCurve ?? 1,
                                    fadeOutCurve: clip.fadeOutCurve ?? 0, fadeOutSCurve: clip.fadeOutSCurve ?? 1,
                                    duration: clip.fadeTimelineDuration ?? clip.duration, position: itemFadeClock.position,
                                    hostTime: itemFadeClock.host, sampleTime: itemFadeClock.sample)
    }
    func setPlaybackBoundary(_ host: UInt64 = 0) { JarasEqualizer.setPlaybackBoundary(equalizer, hostTime: host) }
    func setSourcePolarity(_ inverted: Bool) { JarasEqualizer.setPolarity(equalizer, inverted: inverted) }
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
        if !reorderable {
            let mix = AVAudioMixerNode()
            engine.attach(mix); engine.connect(input, to: mix, format: format)
            itemInputMix = mix; self.input = mix
        }
        settings = nil; sampleRate = 0
        preparedEffects = reorderable ? ["EQ"] : Set(NativeFXSettings.order.dropFirst())
        for node in nodes { engine.attach(node) }
        // Track chains already end at a mixer. Items keep two stable mixer
        // boundaries so editing their processors never resets the player's
        // queue or the time-stretch samples already waiting to be heard.
        outputDestination = reorderable && destinations.count == 1 && destinations[0].bus == 0 ? destinations[0].node : nil
        if outputDestination == nil {
            engine.attach(outputMix)
            if !destinations.isEmpty { engine.connect(outputMix, to: destinations, fromBus: 0, format: format) }
        }
        if reorderable, let source = input as? AVAudioMixerNode, let destination = output as? AVAudioMixerNode {
            // A permanent silent branch keeps upstream players clocked while
            // the independently connected FX entry is rewired. Never replace
            // the source fanout during a live edit (AVAudioEngine resets it).
            let entry = AVAudioMixerNode(); engine.attach(entry)
            trackEntryMix = entry; self.input = entry
            let anchorBus = destination.nextAvailableInputBus == 0 ? 1 : destination.nextAvailableInputBus
            engine.connect(source, to: [AVAudioConnectionPoint(node: entry, bus: 0),
                AVAudioConnectionPoint(node: destination, bus: anchorBus)], fromBus: 0, format: format)
            source.destination(forMixer: destination, bus: anchorBus)!.volume = 0
        }
        apply(NativeFXSettings())
        if let itemInputMix, let first = connected.first {
            // Keep an inaudible connection alive through every graph edit.
            // Its per-destination volume leaves the FX branch at unity and
            // avoids the doubled signal of a temporary audible fanout.
            engine.connect(itemInputMix, to: [AVAudioConnectionPoint(node: first, bus: 0),
                AVAudioConnectionPoint(node: outputMix, bus: 1)], fromBus: 0, format: format)
            itemInputMix.destination(forMixer: outputMix, bus: 1)!.volume = 0
        }
    }
    private func connect(_ next: NativeFXSettings) {
        guard let engine, let input, let format else { return }
        preparedEffects.formUnion(next.effectKeys)
        // Also accept legacy settings with enabled processors but no inserted list.
        preparedEffects.formUnion(NativeFXSettings.order.dropFirst().filter { next.isEnabled($0) })
        var keys = reorderable ? next.effectKeys : NativeFXSettings.order.dropFirst().filter { preparedEffects.contains($0) }
        // Item chains keep their shared native stages stable, but take VST3s
        // and repeated native inserts must still be connected to the signal.
        if !reorderable { keys += next.effectKeys.filter { !keys.contains($0) } }
        keys += NativeFXSettings.order.dropFirst().filter { preparedEffects.contains($0) && !keys.contains($0) }
        if instrumentMix != nil && !keys.contains("Instruments") { keys.insert("Instruments", at: 0) }
        var includedNodes = Set<ObjectIdentifier>()
        let ordered: [AVAudioNode] = keys.compactMap { key in
            // TimePitch's bypass still buffers audio; a disabled/zero shift
            // must take the dry path without adding transform latency.
            if next.kind(of: key) == "Pitch" {
                let value = next.settings(for: key)
                if !next.effectKeys.contains(key) || value.pitchEnabled != true || value.semitones == 0 { return nil }
            }
            if let node = instanceNodes[key] { return node }
            switch key {
            case "Instruments": return instrumentMix
            case "EQ": return equalizer
            case "Compressor": return compressor
            case "Limiter": return limiter
            case "CatLive Trigger": return trigger
            case "Cat Gate": return gate
            case "Pitch": return pitch
            case "Delay": return delay
            case "Reverb": return reverb
            case NativeFXSettings.stemSeparator:
                return nil
            default:
                #if os(macOS)
                return next.externalPlugins?.first(where: { $0.effectKey == key }).flatMap { externalNodes[$0.id] }
                #else
                return nil
                #endif
            }
        }.filter { includedNodes.insert(ObjectIdentifier($0)).inserted }
        guard ordered.map(ObjectIdentifier.init) != connected.map(ObjectIdentifier.init) else { return }
        detachDelayAnalysis()
        // Preserve every unchanged leading connection. In an item chain the
        // combined EQ/compressor is always first: rewiring its player input
        // discards scheduled PCM, even when the player is immediately reconnected.
        var sharedPrefix = 0
        while sharedPrefix < min(ordered.count, connected.count), ordered[sharedPrefix] === connected[sharedPrefix] {
            sharedPrefix += 1
        }
        let bridge = sharedPrefix > 0 ? ordered[sharedPrefix - 1] : input
        // Keep the unchanged prefix in place. Item input/output boundaries
        // retain their silent anchor throughout this rewiring, so neither
        // the player nor its buffered time-stretch audio is restarted.
        if connected.count > sharedPrefix {
            engine.connect(bridge, to: output, fromBus: 0, toBus: 0, format: format)
        }
        for node in connected.dropFirst(sharedPrefix) { engine.disconnectNodeOutput(node) }
        var destination: AVAudioNode = output
        for node in ordered.dropFirst(sharedPrefix).reversed() {
            engine.connect(node, to: destination, fromBus: 0, toBus: 0, format: format)
            destination = node
        }
        engine.connect(bridge, to: destination, fromBus: 0, toBus: 0, format: format)
        connected = ordered
        observe(observedEffects)
    }
    func resetTails() {
        for node in nodes { node.auAudioUnit.reset() }
        for node in instanceNodes.values { (node as? AVAudioUnit)?.auAudioUnit.reset() }
        meterTime = 0; meterCache.removeAll(keepingCapacity: true)
        delayAnalysisPeaks.removeAll(keepingCapacity: true)
    }
    func detach(from engine: AVAudioEngine) {
        if let node = stemSeparatorNode { JarasStemSeparator.stop(node) }
        detachDelayAnalysis()
        for node in instanceNodes.values { engine.detach(node) }; instanceNodes.removeAll()
        for node in nodes { engine.detach(node) }
        if let instrumentMix { engine.detach(instrumentMix) }
        if let itemInputMix { engine.detach(itemInputMix) }; itemInputMix = nil
        if let trackEntryMix { engine.detach(trackEntryMix) }; trackEntryMix = nil
        if outputDestination == nil { engine.detach(outputMix) }
        outputDestination = nil; connected.removeAll(); self.engine = nil; input = nil
        preparedEffects = ["EQ"]
        instrumentMix = nil
        #if os(macOS)
        externalNodes.removeAll(); failedExternalPlugins.removeAll()
        #endif
        stemSeparatorNode = nil; stemSeparatorStarted = false; stemSeparatorError = nil
        trigger = nil; gate = nil; triggerSamplePaths.removeAll(); sampleErrors.removeAll()
    }
    func apply(_ next: NativeFXSettings) {
        let rate = max(8000, format?.sampleRate ?? equalizer.outputFormat(forBus: 0).sampleRate)
        #if os(macOS)
        let retained = Set((next.externalPlugins ?? []).filter { next.inserted.contains($0.effectKey) }.map(\.id))
        guard next != settings || rate != sampleRate || Set(externalNodes.keys).union(failedExternalPlugins.keys) != retained else { return }
        #else
        guard next != settings || rate != sampleRate else { return }
        #endif
        configureStemSeparator(next)
        #if os(macOS)
        failedExternalPlugins = failedExternalPlugins.filter { retained.contains($0.key) }
        for plugin in next.externalPlugins ?? [] where next.inserted.contains(plugin.effectKey) {
            let failed = failedExternalPlugins[plugin.id]
            if plugin != settings?.externalPlugins?.first(where: { $0.id == plugin.id }) || rate != sampleRate ||
                (externalNodes[plugin.id] == nil && failed?.0 != plugin) {
                do {
                    _ = try prepareExternal(plugin)
                    failedExternalPlugins[plugin.id] = nil
                } catch {
                    // One broken insert must never prevent a later instrument
                    // or effect from being prepared. Cache unchanged failures
                    // so a missing library is not reopened on every audio tick.
                    failedExternalPlugins[plugin.id] = (plugin, error)
                }
            }
        }
        externalError = (next.externalPlugins ?? []).compactMap { failedExternalPlugins[$0.id]?.1 }.first
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
        if next.inserted.contains("CatLive Trigger"), trigger == nil {
            let node = JarasDynamics.makeTrigger(); trigger = node; engine?.attach(node)
        }
        if let trigger { configureTrigger(trigger, key: "CatLive Trigger", value: next,
            enabled: next.inserted.contains("CatLive Trigger") && next.triggerEnabled == true) }
        if next.inserted.contains("Cat Gate"), gate == nil {
            let node = JarasDynamics.makeGate(); gate = node; engine?.attach(node)
        }
        if let gate { configureGate(gate, value: next,
            enabled: next.inserted.contains("Cat Gate") && next.gateEnabled == true) }
        configureInstances(next, rate: rate)
        connect(next)
        if !next.inserted.contains(NativeFXSettings.stemSeparator), let node = stemSeparatorNode {
            JarasStemSeparator.stop(node); engine?.detach(node)
            stemSeparatorNode = nil; stemSeparatorStarted = false; stemSeparatorError = nil
        }
        let nativeRetained = Set((next.instances ?? []).filter { next.inserted.contains($0.effectKey) }.map(\.effectKey))
        for key in Set(instanceNodes.keys).subtracting(nativeRetained) {
            if let node = instanceNodes.removeValue(forKey: key) { engine?.detach(node) }
            triggerSamplePaths[key] = nil; sampleErrors[key] = nil
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
        let additions = effects.intersection(Set(NativeFXSettings.order.dropFirst())).subtracting(preparedEffects)
        if !additions.isEmpty {
            preparedEffects.formUnion(additions)
            connect(settings ?? NativeFXSettings())
        }
        for (key, node) in instanceNodes {
            let enabled = effects.contains(key)
            switch settings?.kind(of: key) {
            case "EQ": JarasEqualizer.setAnalysisEnabled(node as! AVAudioUnitEffect, enabled: enabled)
            case "Compressor", "Limiter": JarasDynamics.setCompressorMeteringEnabled(node as! AVAudioUnitEffect, enabled: enabled)
            case "Reverb", "CatLive Trigger", "Cat Gate":
                JarasDynamics.setAnalysisEnabled(node as! AVAudioUnitEffect, input: true, enabled: enabled)
                JarasDynamics.setAnalysisEnabled(node as! AVAudioUnitEffect, input: false, enabled: enabled)
            default: break
            }
        }
        JarasEqualizer.setAnalysisEnabled(equalizer, enabled: effects.contains("EQ"))
        JarasDynamics.setCompressorMeteringEnabled(compressor, enabled: effects.contains("Compressor"))
        if let limiter { JarasDynamics.setCompressorMeteringEnabled(limiter, enabled: effects.contains("Limiter")) }
        JarasDynamics.setAnalysisEnabled(reverb, input: true, enabled: effects.contains("Reverb"))
        JarasDynamics.setAnalysisEnabled(reverb, input: false, enabled: effects.contains("Reverb"))
        for (key, node) in [("CatLive Trigger", trigger), ("Cat Gate", gate)] {
            if let node {
                JarasDynamics.setAnalysisEnabled(node, input: true, enabled: effects.contains(key))
                JarasDynamics.setAnalysisEnabled(node, input: false, enabled: effects.contains(key))
            }
        }
        observesDelay = effects.contains("Delay"); updateDelayAnalysis()
    }
    private func detachDelayAnalysis() {
        for probe in delayAnalysisProbes.values { probe.detach() }
        delayAnalysisProbes.removeAll(); delayAnalysisPeaks.removeAll()
        instanceDelayProbes.removeAll()
        delayInputProbe = nil; delayOutputProbe = nil
    }
    private func updateDelayAnalysis() {
        var boundaries: [String: (AVAudioNode, AVAudioNode)] = [:]
        func include(_ key: String, node: AVAudioNode) {
            guard let index = connected.firstIndex(where: { $0 === node }),
                  let predecessor = index > 0 ? connected[index - 1] : input else { return }
            boundaries[key] = (predecessor, node)
        }
        if observesDelay { include("Delay", node: delay) }
        for (key, node) in instanceNodes where node is AVAudioUnitDelay && observedEffects.contains(key) {
            include(key, node: node)
        }
        let retained = Set(boundaries.values.flatMap { [ObjectIdentifier($0.0), ObjectIdentifier($0.1)] })
        // Release obsolete taps first; never remove a shared tap through one
        // effect's old pair while another effect still needs the same node.
        for id in Set(delayAnalysisProbes.keys).subtracting(retained) {
            if let probe = delayAnalysisProbes.removeValue(forKey: id) {
                probe.detach(); delayAnalysisPeaks[ObjectIdentifier(probe)] = nil
            }
        }
        func probe(for node: AVAudioNode) -> JarasAudioAnalysisProbe {
            let id = ObjectIdentifier(node)
            if let probe = delayAnalysisProbes[id] { return probe }
            let probe = JarasAudioAnalysisProbe(); probe.attach(to: node)
            delayAnalysisProbes[id] = probe
            return probe
        }
        delayInputProbe = nil; delayOutputProbe = nil; instanceDelayProbes.removeAll()
        for (key, nodes) in boundaries {
            let pair = (probe(for: nodes.0), probe(for: nodes.1))
            if key == "Delay" { delayInputProbe = pair.0; delayOutputProbe = pair.1 }
            else { instanceDelayProbes[key] = pair }
        }
    }
    private func delayPeaks(_ probe: JarasAudioAnalysisProbe?) -> [Float] {
        guard let probe else { return [0, 0] }
        let id = ObjectIdentifier(probe), now = ProcessInfo.processInfo.systemUptime
        if let cached = delayAnalysisPeaks[id], now - cached.time < 1.0 / 40 { return cached.values }
        let values = probe.takePeaks().map(\.floatValue)
        delayAnalysisPeaks[id] = (now, values)
        return values
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
            case "Reverb", "CatLive Trigger", "Cat Gate": return JarasDynamics.analysisPeaks(node as! AVAudioUnitEffect, input: true).map(\.floatValue) + JarasDynamics.analysisPeaks(node as! AVAudioUnitEffect, input: false).map(\.floatValue)
            case "Delay": return delayPeaks(instanceDelayProbes[effect]?.0) + delayPeaks(instanceDelayProbes[effect]?.1)
            default: return [0,0,0,0]
            }
        }
        if let node = effect == "CatLive Trigger" ? trigger : (effect == "Cat Gate" ? gate : nil) {
            return JarasDynamics.analysisPeaks(node, input: true).map(\.floatValue) + JarasDynamics.analysisPeaks(node, input: false).map(\.floatValue)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - meterTime > 1.0 / 40 {
            meterTime = now
            let compressor = compressorPeaks()
            let delayIn = delayPeaks(delayInputProbe)
            let delayOut = delayPeaks(delayOutputProbe)
            let reverbIn = JarasDynamics.analysisPeaks(reverb, input: true).map(\.floatValue)
            let reverbOut = JarasDynamics.analysisPeaks(reverb, input: false).map(\.floatValue)
            meterCache = ["Compressor":compressor, "Delay":delayIn+delayOut, "Reverb":reverbIn+reverbOut, "Limiter":limiter.map { JarasDynamics.takeCompressorPeaks($0).map(\.floatValue) } ?? [0,0,0,0]]
        }
        return meterCache[effect] ?? [0,0,0,0]
    }
    func compressorPeaks() -> [Float] { JarasDynamics.takeCompressorPeaks(compressor).map(\.floatValue) }
}

/// An isolated input-only graph owned by the recording writer. It never reads
/// the playback buses, so existing items cannot be printed into a new take.
final class RecordingInputProcessor {
    private final class Feed {
        let buffer: AVAudioPCMBuffer
        var offset = 0
        init(_ format: AVAudioFormat) { buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)! }
    }
    private let engine = AVAudioEngine()
    private let chain = NativeEffectsChain()
    private let feed: Feed
    private let source: AVAudioSourceNode
    private let output: AVAudioPCMBuffer
    private var position = 0.0
    private(set) var latency: Int
    private var settings: NativeFXSettings
    init(format: AVAudioFormat, settings: NativeFXSettings, mediaDirectory: URL? = nil) throws {
        // Native track processors use a stereo bus even for a mono input.
        self.settings = settings
        chain.mediaDirectory = mediaDirectory
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)!
        let feed = Feed(stereo); self.feed = feed
        output = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4096)!
        source = AVAudioSourceNode(format: stereo) { _, _, count, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for channel in 0..<list.count {
                guard let destination = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(count) {
                    let at = feed.offset + i
                    destination[i] = at < Int(feed.buffer.frameLength) ? feed.buffer.floatChannelData![min(channel, 1)][at] : 0
                }
            }
            feed.offset += Int(count)
            return noErr
        }
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096)
        engine.attach(source)
        chain.attach(to: engine, input: source, format: stereo,
                     destinations: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0)])
        chain.apply(settings)
        #if os(macOS)
        if let error = chain.externalError { throw error }
        #endif
        engine.prepare(); try engine.start()
        latency = max(0, Int(((source.latency + source.outputPresentationLatency) * format.sampleRate).rounded()))
    }
    deinit { engine.stop() }
    // Parameters are applied on the same worker that renders this graph.
    func update(_ settings: NativeFXSettings) throws {
        guard self.settings != settings else { return }
        chain.apply(settings); self.settings = settings
        #if os(macOS)
        if let error = chain.externalError { throw error }
        #endif
        latency = max(0, Int(((source.latency + source.outputPresentationLatency) * output.format.sampleRate).rounded()))
    }
    func process(_ buffer: AVAudioPCMBuffer) throws {
        let count = Int(buffer.frameLength)
        feed.buffer.frameLength = buffer.frameLength; feed.offset = 0
        for channel in 0..<2 {
            feed.buffer.floatChannelData![channel].update(from: buffer.floatChannelData![min(channel, Int(buffer.format.channelCount) - 1)], count: count)
        }
        #if os(macOS)
        chain.externalTransport(position: position, tempo: 120, beats: 4, unit: 4, playing: true)
        #endif
        let status = try engine.renderOffline(buffer.frameLength, to: output)
        guard status == .success, output.frameLength == buffer.frameLength else {
            throw ProjectError.invalid("The recording effects could not process the input audio.")
        }
        for channel in 0..<Int(buffer.format.channelCount) {
            buffer.floatChannelData![channel].update(from: output.floatChannelData![channel], count: count)
        }
        position += Double(count) / buffer.format.sampleRate
    }
}
