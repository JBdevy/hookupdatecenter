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
    private(set) var catSynthVoices: [String: JarasCatSynth] = [:]
    private(set) var drummerVoices: [String: DrummerPadVoice] = [:]
    var offlineDrums = false
    private var drumSequence: [[String: Double]] = []
    func setDrumSequence(_ notes: [[String: Double]]) {
        guard notes != drumSequence else { return }
        drumSequence = notes
        for voice in drummerVoices.values { voice.source.setSequenceNotes(notes) }
        for voice in catSynthVoices.values { voice.setSequenceNotes(notes) }
    }
    func drumClock(head: Int, position: Double, clock: Double, running: Bool, loopStart: Double, loopEnd: Double) {
        for voice in catSynthVoices.values {
            voice.sequenceHead(Int32(head), position: position, clock: clock, running: running, loopStart: loopStart, loopEnd: loopEnd)
        }
        for voice in drummerVoices.values {
            voice.source.sequenceHead(Int32(head), position: position, clock: clock, running: running && voice.enabled, loopStart: loopStart, loopEnd: loopEnd)
        }
    }
    func drumMIDI(_ status: UInt8, _ note: UInt8, _ velocity: UInt8) {
        for voice in catSynthVoices.values { voice.receiveStatus(status, key: note, value: velocity) }
        for voice in drummerVoices.values where voice.enabled {
            if status & 0xf0 == 0x90 && velocity > 0 { voice.source.midiNote(UInt(note), velocity: UInt(velocity)) }
            if status & 0xf0 == 0xb0 && (note == 120 || note == 123) { voice.source.silence() }
        }
    }
    private func configureCatSynths(_ next: NativeFXSettings, rate: Double) {
        guard let engine, let format else { return }
        for key in next.effectKeys where next.kind(of: key) == "CatSynth" {
            let voice: JarasCatSynth
            if let existing = catSynthVoices[key] { voice = existing }
            else {
                voice = JarasCatSynth(sampleRate: rate)
                engine.attach(voice.mix)
                engine.attach(voice.node)
                engine.connect(voice.node, to: voice.mix, fromBus: 0, toBus: 1, format: format)
                voice.setSequenceNotes(drumSequence)
                catSynthVoices[key] = voice
            }
            let bank = next.settings(for: key).catSynth ?? CatSynthBank()
            let index = min(CatSynthBank.count - 1, max(0, bank.selected))
            let defaults = JarasCatSynth.factoryPatch(UInt(index))
            let values = bank.slots.indices.contains(index) ? bank.slots[index]?.map { NSNumber(value: $0) } : nil
            voice.configurePatch(values ?? defaults, enabled: next.isEnabled(key))
        }
    }
    private func configureDrums(_ next: NativeFXSettings, rate: Double) {
        guard let engine, let format else { return }
        for key in next.effectKeys {
            guard let kind = DrummerPadKind(rawValue: next.kind(of: key)) else { continue }
            let voice: DrummerPadVoice
            if let existing = drummerVoices[key] { voice = existing }
            else {
                voice = DrummerPadVoice(kind: kind, rate: rate)
                engine.attach(voice.mixer); engine.attach(voice.source.node)
                engine.connect(voice.source.node, to: voice.mixer, fromBus: 0, toBus: 1, format: format)
                drummerVoices[key] = voice
                voice.source.setSequenceNotes(drumSequence)
            }
            voice.apply(next.settings(for: key).drumKit(kind), enabled: next.isEnabled(key), offline: offlineDrums)
        }
    }
    private let reorderable: Bool
    private let preparesInactiveEffects: Bool
    init(reorderable: Bool = true, preparesInactiveEffects: Bool = true) {
        self.reorderable = reorderable
        self.preparesInactiveEffects = preparesInactiveEffects
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
    private var pitch: AVAudioUnitEffect?

    private func configurePitch(_ node: AVAudioUnitEffect, settings: NativeFXSettings, enabled: Bool) {
        let pitch = enabled ? Float(settings.semitones) : 0
        let formant = enabled ? Float(settings.formantSemitones) : 0
        JarasPitchFormant.configure(node, pitch: pitch, formant: formant)
    }

    private var channelDelays: [String: AVAudioUnitEffect] = [:]
    private func setDelayChannels(_ key: String, value: NativeFXSettings) {
        let channels = value.channels(for: "Delay")
        if channels == 3 && channelDelays[key] == nil { return }
        let node: AVAudioUnitEffect
        if let existing = channelDelays[key] { node = existing }
        else {
            node = JarasDynamics.makeChannelDelay()
            channelDelays[key] = node
            engine?.attach(node)
        }
        JarasDynamics.setEffectChannels(node, mask: UInt(channels))
        JarasDynamics.configureChannelDelay(node, enabled: value.delayEnabled, delay: value.delayTime,
            feedback: value.feedback, mix: value.delayMix)
    }

    private var creativeNodes: [String: AVAudioUnitEffect] = [:]
    private func configureCreativeEffects(_ next: NativeFXSettings) {
        for key in next.effectKeys {
            guard let kind = NativeCreativeEffect(rawValue: next.kind(of: key)) else { continue }
            let value = next.settings(for: key)
            let node: AVAudioUnitEffect
            if let existing = creativeNodes[key] {
                if settings?.settings(for: key) == value { continue }
                node = existing
            } else {
                guard let index = NativeCreativeEffect.allCases.firstIndex(of: kind) else { continue }
                node = JarasCreativeEffects.makeEffect(index + 1)
                creativeNodes[key] = node
                engine?.attach(node)
                if kind == .divisionGate { JarasCreativeEffects.setTempoMap(node, points: externalTempoPoints) }
            }
            let parameters = value.creativeParameters(kind) ?? [:]
            JarasCreativeEffects.configure(node, enabled: value.isEnabled(kind.rawValue),
                parameters: kind.parameters.map { NSNumber(value: parameters[$0.key] ?? $0.initial) })
        }
    }
    var hasClockedEffects: Bool {
        #if os(macOS)
        if !externalNodes.isEmpty { return true }
        #endif
        return creativeNodes.keys.contains { settings?.kind(of: $0) == NativeCreativeEffect.divisionGate.rawValue }
    }
    private var gateNodes: [AVAudioUnitEffect] {
        creativeNodes.compactMap { settings?.kind(of: $0.key) == NativeCreativeEffect.divisionGate.rawValue ? $0.value : nil }
    }
    private var delayNode: AVAudioUnitDelay?
    private var reverbNode: AVAudioUnitEffect?
    var delay: AVAudioUnitDelay {
        if let delayNode { return delayNode }
        let node = AVAudioUnitDelay(), value = settings ?? NativeFXSettings()
        node.bypass = !value.delayEnabled; node.delayTime = value.delayTime
        node.feedback = Float(value.feedback); node.wetDryMix = Float(value.delayMix)
        delayNode = node; engine?.attach(node)
        return node
    }
    var reverb: AVAudioUnitEffect {
        if let reverbNode { return reverbNode }
        let node = JarasDynamics.makeReverb(), value = settings ?? NativeFXSettings()
        JarasDynamics.configureReverb(node, enabled: value.reverbEnabled, space: value.reverbRoom,
            mix: value.reverbMix, decay: value.reverbDecay, lowCut: value.reverbLowCut, highCut: value.reverbHighCut)
        reverbNode = node; engine?.attach(node)
        return node
    }
    private var itemInputMix: AVAudioMixerNode?
    private var trackEntryMix: AVAudioMixerNode?
    private var silentClockMix: AVAudioMixerNode?
    private lazy var outputMix = AVAudioMixerNode()
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
            guard DrummerPadKind(rawValue: instance.kind) == nil, instance.kind != "Arpeggiator", instance.kind != "CatSynth", NativeCreativeEffect(rawValue: instance.kind) == nil else { continue }
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
                case "Pitch": node = JarasPitchFormant.makeNode()
                case "Delay": node = AVAudioUnitDelay()
                default: node = JarasDynamics.makeReverb()
                }
                instanceNodes[key] = node; engine?.attach(node)
            }
            if settings?.settings(for: key) == value && rate == sampleRate { continue }
            switch instance.kind {
            case "EQ":
                JarasEqualizer.setEffectChannels(node as! AVAudioUnitEffect, mask: UInt(value.channels(for: "EQ")))
                JarasEqualizer.configure(node as! AVAudioUnitEffect, coefficients: value.bands.flatMap { $0.coefficients(rate: rate) }.map { $0.map(NSNumber.init(value:)) }, enabled: value.eqEnabled)
            case "Compressor":
                JarasDynamics.setEffectChannels(node as! AVAudioUnitEffect, mask: UInt(value.channels(for: "Compressor")))
                JarasDynamics.configureCompressor(node as! AVAudioUnitEffect, enabled: value.compressorEnabled, threshold: value.threshold, ratio: value.ratio, attack: value.attack, release: value.release, gain: value.makeup)
            case "Limiter":
                let parameters = value.limiterParameters
                JarasDynamics.configureLimiter(node as! AVAudioUnitEffect, enabled: value.limiterEnabled == true, gain: parameters.inputGain, ceiling: parameters.ceiling, release: parameters.release)
            case "CatLive Trigger":
                configureTrigger(node as! AVAudioUnitEffect, key: key, value: value, enabled: value.triggerEnabled == true)
            case "Cat Gate":
                configureGate(node as! AVAudioUnitEffect, value: value, enabled: value.gateEnabled == true)
            case "Pitch":
                configurePitch(node as! AVAudioUnitEffect, settings: value, enabled: value.pitchEnabled == true)
            case "Delay":
                let delay = node as! AVAudioUnitDelay
                delay.bypass = !value.delayEnabled; delay.delayTime = value.delayTime
                delay.feedback = Float(value.feedback); delay.wetDryMix = Float(value.delayMix)
                setDelayChannels(key, value: value)
            case "Reverb":
                JarasDynamics.setEffectChannels(node as! AVAudioUnitEffect, mask: UInt(value.channels(for: "Reverb")))
                JarasDynamics.configureReverb(node as! AVAudioUnitEffect, enabled: value.reverbEnabled, space: value.reverbRoom, mix: value.reverbMix, decay: value.reverbDecay, lowCut: value.reverbLowCut, highCut: value.reverbHighCut)
            default: break
            }
        }
    }
    private weak var engine: AVAudioEngine?
    private var input: AVAudioNode?
    private var format: AVAudioFormat?
    private var connected: [AVAudioNode] = []
    private var connectionsInstalled = false
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
    #endif
    private var externalTempoSections: [TimelineTempoSection]?
    private var externalTempoPoints: [[String: NSNumber]] = []
    func externalTimeline(_ sections: [TimelineTempoSection]) {
        guard externalTempoSections != sections else { return }
        externalTempoSections = sections
        externalTempoPoints = sections.map { ["seconds": NSNumber(value: $0.start), "bpm": NSNumber(value: $0.bpm),
            "beats": NSNumber(value: $0.beats), "unit": NSNumber(value: $0.unit)] }
        for node in gateNodes { JarasCreativeEffects.setTempoMap(node, points: externalTempoPoints) }
        #if os(macOS)
        for node in externalNodes.values { JarasVST3.setTempoMap(node, points: externalTempoPoints) }
        #endif
    }
    func externalTimelineTransport(position: Double, clock: Double, playing: Bool, loopStart: Double, loopEnd: Double) {
        for node in gateNodes {
            JarasCreativeEffects.transport(node, position: position, clock: clock, playing: playing, loopStart: loopStart, loopEnd: loopEnd, tempo: 120)
        }
        #if os(macOS)
        for node in externalNodes.values {
            JarasVST3.transportClock(node, position: position, clock: clock, playing: playing, loopStart: loopStart, loopEnd: loopEnd)
        }
        #endif
    }

    func offlineCreativeTransport(position: Double, tempo: Double, playing: Bool) {
        for node in gateNodes {
            JarasCreativeEffects.transport(node, position: position, clock: .nan, playing: playing, loopStart: 0, loopEnd: 0, tempo: tempo)
        }
    }

    #if os(macOS)
    func enableInstrumentMIDI(_ enabled: Bool) {
        instrumentMIDIInput = enabled
        for node in externalNodes.values { JarasVST3.instrumentMIDIInput(node, enabled: enabled) }
    }
    func externalNode(_ identifier: String) -> AVAudioUnitEffect? {
        guard let node = externalNodes[identifier], JarasVST3.isPluginLoaded(node, identifier: identifier) else { return nil }
        return node
    }
    /// The processor already owns this state. A capture only updates the cached
    /// description, so a later native-parameter edit cannot restore an old preset.
    func rememberCapturedPluginState(_ plugin: ExternalPlugin, source: AVAudioUnitEffect) {
        guard externalNodes[plugin.id] === source,
              let index = settings?.externalPlugins?.firstIndex(where: { $0.id == plugin.id }) else { return }
        settings?.externalPlugins?[index].componentState = plugin.componentState
        settings?.externalPlugins?[index].controllerState = plugin.controllerState
        JarasVST3.rememberCapturedState(source, identifier: plugin.id,
            component: plugin.componentState, controller: plugin.controllerState)
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
        if externalTempoSections != nil { JarasVST3.setTempoMap(node, points: externalTempoPoints) }
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
        if let delayNode { result.append(delayNode) }
        if let reverbNode { result.append(reverbNode) }
        if let pitch { result.append(pitch) }
        if let limiter { result.append(limiter) }
        if let trigger { result.append(trigger) }
        if let gate { result.append(gate) }
        for node in creativeNodes.values { result.append(node) }
        for node in channelDelays.values { result.append(node) }
        if let stemSeparatorNode { result.append(stemSeparatorNode) }
        #if os(macOS)
        for node in externalNodes.values { result.append(node) }
        #endif
        return result
    }
    var output: AVAudioNode { outputDestination ?? outputMix }
    func setSourceChannelMode(_ mode: Int) { JarasEqualizer.setInputChannelMode(equalizer, mode: Int32(mode)) }
    static func overlapEnvelopes(for track: Track) -> [String: Data] {
        guard UserDefaults.standard.bool(forKey: StemLayoutPreferences.crossfadeKey), track.usesStackedStems else { return [:] }
        let entries: [[Any]] = track.clips.compactMap { clip in
            guard clip.duration > 0, clip.muted != true, clip.midi == nil, clip.text == nil, !clip.isImage,
                  (clip.audioFile ?? track.audioFile) != nil else { return nil }
            return [clip.id.uuidString.lowercased(), clip.startTime, clip.startTime + clip.duration]
        }
        return entries.count > 1 ? JarasEqualizer.overlapEnvelopes(entries) : [:]
    }
    private var overlapEnvelope: Data?
    func setOverlapEnvelope(_ envelope: Data?) {
        guard overlapEnvelope != envelope else { return }
        overlapEnvelope = envelope
        JarasEqualizer.setOverlapEnvelope(equalizer, data: envelope)
    }
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
    func setItemGain(_ gain: Double) { JarasEqualizer.setItemGain(equalizer, gain: gain) }
    var instrumentInput: AVAudioMixerNode {
        if let instrumentMix { return instrumentMix }
        let mixer = AVAudioMixerNode(); instrumentMix = mixer
        if let engine { engine.attach(mixer); connect(settings ?? NativeFXSettings()) }
        return mixer
    }
    private var settings: NativeFXSettings?
    private var sampleRate = 0.0
    func attach(to engine: AVAudioEngine, input: AVAudioNode, format: AVAudioFormat, destinations: [AVAudioConnectionPoint] = [], clockDestination: AVAudioMixerNode? = nil) {
        self.engine = engine; self.input = input; self.format = format
        if !reorderable && (preparesInactiveEffects || !(input is AVAudioMixerNode)) {
            let mix = AVAudioMixerNode()
            engine.attach(mix); engine.connect(input, to: mix, format: format)
            itemInputMix = mix; self.input = mix
        }
        settings = nil; sampleRate = 0; connectionsInstalled = false
        // Prepared PCM sources retain their own sample clock through an FX
        // edit. They need the combined source/EQ stage, but hundreds of dry
        // items must not render unused Delay and Reverb processors. An effect
        // joins the stable prefix when first inserted and remains warm after.
        if reorderable {
            preparedEffects = ["EQ"]
        } else {
            preparedEffects = !preparesInactiveEffects ? ["EQ"] : Set(NativeFXSettings.order.dropFirst())
        }
        // Keep the track EQ connected for its editor's graph-free RTA.
        // Other unused track processors stay outside the engine until needed.
        // Item chains retain their source gain, channel mode and fade stage.
        if !reorderable || preparesInactiveEffects {
            for node in nodes { engine.attach(node) }
        }
        // Prepared items already have a source-rate converter at the input.
        // Reuse it for the stable fanout instead of inserting another mixer.
        // Keep the output anchor: reconnecting even a prepared source's
        // converter during playback discards its buffered rate-converted PCM.
        outputDestination = reorderable && destinations.count == 1 && destinations[0].bus == 0 ? destinations[0].node : nil
        if outputDestination == nil {
            engine.attach(outputMix)
            if !destinations.isEmpty { engine.connect(outputMix, to: destinations, fromBus: 0, format: format) }
        }
        if reorderable, let source = input as? AVAudioMixerNode, let destination = clockDestination ?? (output as? AVAudioMixerNode) {
            // A permanent silent branch keeps upstream players clocked while
            // the independently connected FX entry is rewired. Never replace
            // the source fanout during a live edit (AVAudioEngine resets it).
            let entry = AVAudioMixerNode(); engine.attach(entry)
            trackEntryMix = entry; self.input = entry
            connectClockedInput(source, to: entry, clock: destination, bus: max(1, destination.nextAvailableInputBus), engine: engine, format: format)
        }
        apply(NativeFXSettings())
        if !reorderable, let anchor = self.input as? AVAudioMixerNode, let first = connected.first {
            // Keep an inaudible connection alive through every graph edit.
            // Its per-destination volume leaves the FX branch at unity and
            // avoids the doubled signal of a temporary audible fanout.
            connectClockedInput(anchor, to: first, clock: outputMix, bus: 1, engine: engine, format: format)
        }
    }
    private func connectClockedInput(_ source: AVAudioMixerNode, to first: AVAudioNode, clock: AVAudioMixerNode,
                                     bus: AVAudioNodeBus, engine: AVAudioEngine, format: AVAudioFormat) {
        let fx = AVAudioConnectionPoint(node: first, bus: 0)
        #if os(macOS)
        engine.connect(source, to: [fx, AVAudioConnectionPoint(node: clock, bus: bus)], fromBus: 0, format: format)
        if let destination = source.destination(forMixer: clock, bus: bus) {
            destination.volume = 0
            return
        }
        #endif
        // iPadOS 16 can return no mixing destination while attaching a live
        // track. Mute the clock branch before connecting it to the source.
        let silent = AVAudioMixerNode()
        silentClockMix = silent
        engine.attach(silent)
        silent.outputVolume = 0
        engine.connect(silent, to: clock, fromBus: 0, toBus: bus, format: format)
        engine.connect(source, to: [fx, AVAudioConnectionPoint(node: silent, bus: 0)], fromBus: 0, format: format)
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
        func node(for key: String) -> AVAudioNode? {
            // Keep the latency of an inserted Pitch instance fixed during
            // knob moves and bypass, including the neutral setting.
            if next.kind(of: key) == "Pitch" && !next.effectKeys.contains(key) { return nil }
            if let voice = catSynthVoices[key] { return next.inserted.contains(key) ? voice.mix : nil }
            if let voice = drummerVoices[key] { return next.inserted.contains(key) ? voice.mixer : nil }
            if let node = creativeNodes[key] { return node }
            if let alternate = channelDelays[key], next.settings(for: key).channels(for: "Delay") != 3 { return alternate }
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
            case "Arpeggiator", NativeFXSettings.stemSeparator:
                return nil
            default:
                #if os(macOS)
                return next.externalPlugins?.first(where: { $0.effectKey == key }).flatMap { externalNodes[$0.id] }
                #else
                return nil
                #endif
            }
        }
        var ordered: [AVAudioNode] = []
        for key in keys {
            guard let processor = node(for: key), includedNodes.insert(ObjectIdentifier(processor)).inserted else { continue }
            ordered.append(processor)
        }
        guard !connectionsInstalled || ordered.map(ObjectIdentifier.init) != connected.map(ObjectIdentifier.init) else { return }
        for node in ordered where node.engine == nil { engine.attach(node) }
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
        for node in connected.dropFirst(sharedPrefix) where node.engine === engine {
            engine.disconnectNodeOutput(node)
        }
        var destination: AVAudioNode = output
        for node in ordered.dropFirst(sharedPrefix).reversed() {
            engine.connect(node, to: destination, fromBus: 0, toBus: 0, format: format)
            destination = node
        }
        engine.connect(bridge, to: destination, fromBus: 0, toBus: 0, format: format)
        connected = ordered; connectionsInstalled = true
        observe(observedEffects)
    }
    func resetTails() {
        for node in nodes where !JarasRequestNativePlaybackReset(node) { node.auAudioUnit.reset() }
        for case let node as AVAudioUnit in instanceNodes.values where !JarasRequestNativePlaybackReset(node) {
            node.auAudioUnit.reset()
        }
        meterTime = 0; meterCache.removeAll(keepingCapacity: true)
        delayAnalysisPeaks.removeAll(keepingCapacity: true)
    }
    func detach(from engine: AVAudioEngine) {
        for voice in drummerVoices.values { engine.detach(voice.source.node); engine.detach(voice.mixer) }
        for voice in catSynthVoices.values { engine.detach(voice.node); engine.detach(voice.mix) }
        catSynthVoices.removeAll()
        drummerVoices.removeAll(); drumSequence.removeAll()
        if let node = stemSeparatorNode { JarasStemSeparator.stop(node) }
        detachDelayAnalysis()
        for node in instanceNodes.values { engine.detach(node) }; instanceNodes.removeAll()
        for node in nodes where node.engine === engine { engine.detach(node) }
        if let instrumentMix { engine.detach(instrumentMix) }
        if let itemInputMix { engine.detach(itemInputMix) }; itemInputMix = nil
        if let trackEntryMix { engine.detach(trackEntryMix) }; trackEntryMix = nil
        if let silentClockMix { engine.detach(silentClockMix) }; silentClockMix = nil
        if outputDestination == nil { engine.detach(outputMix) }
        outputDestination = nil; connected.removeAll(); connectionsInstalled = false; self.engine = nil; input = nil
        preparedEffects = ["EQ"]
        creativeNodes.removeAll(); channelDelays.removeAll(); externalTempoSections = nil; externalTempoPoints = []
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
        configureDrums(next, rate: rate)
        configureCatSynths(next, rate: rate)
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
            let node = JarasPitchFormant.makeNode()
            pitch = node; engine?.attach(node)
        }
        if let pitch {
            configurePitch(pitch, settings: next, enabled: next.inserted.contains("Pitch") && next.pitchEnabled == true)
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
        configureCreativeEffects(next)
        configureInstances(next, rate: rate)
        if next.inserted.contains("Delay") { setDelayChannels("Delay", value: next) }
        let removedCreative = Set(creativeNodes.keys).subtracting(next.effectKeys)
        let removedCreativeNodes = removedCreative.compactMap { creativeNodes.removeValue(forKey: $0) }
        // Rewire the old chain while its mixers still belong to the engine.
        // Disconnecting a detached node raises an Objective-C exception in AVFAudio.
        connect(next)
        for key in Array(catSynthVoices.keys) where !next.inserted.contains(key) {
            guard let voice = catSynthVoices.removeValue(forKey: key) else { continue }
            engine?.detach(voice.node); engine?.detach(voice.mix)
        }
        for key in Array(drummerVoices.keys) where !next.inserted.contains(key) {
            guard let voice = drummerVoices.removeValue(forKey: key) else { continue }
            engine?.detach(voice.source.node)
            engine?.detach(voice.mixer)
        }
        for node in removedCreativeNodes { engine?.detach(node) }
        if !next.inserted.contains(NativeFXSettings.stemSeparator), let node = stemSeparatorNode {
            JarasStemSeparator.stop(node); engine?.detach(node)
            stemSeparatorNode = nil; stemSeparatorStarted = false; stemSeparatorError = nil
        }
        let nativeRetained = Set((next.instances ?? []).filter { next.inserted.contains($0.effectKey) }.map(\.effectKey))
        for key in Set(instanceNodes.keys).subtracting(nativeRetained) {
            if let node = instanceNodes.removeValue(forKey: key) { engine?.detach(node) }
            if let alternate = channelDelays.removeValue(forKey: key) { engine?.detach(alternate) }
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
        JarasEqualizer.setEffectChannels(equalizer, mask: UInt(next.channels(for: "EQ")))
        JarasDynamics.setEffectChannels(compressor, mask: UInt(next.channels(for: "Compressor")))
        if let reverbNode { JarasDynamics.setEffectChannels(reverbNode, mask: UInt(next.channels(for: "Reverb"))) }
        if rateChanged || previous?.bands != next.bands || previous?.eqEnabled != next.eqEnabled {
            let coefficients = next.bands.flatMap { $0.coefficients(rate: rate) }.map { $0.map(NSNumber.init(value:)) }
            JarasEqualizer.configure(equalizer, coefficients: coefficients, enabled: next.eqEnabled)
        }
        if previous?.compressorEnabled != next.compressorEnabled || previous?.threshold != next.threshold || previous?.ratio != next.ratio || previous?.attack != next.attack || previous?.release != next.release || previous?.makeup != next.makeup {
            JarasDynamics.configureCompressor(compressor, enabled: next.compressorEnabled, threshold: next.threshold, ratio: next.ratio, attack: next.attack, release: next.release, gain: next.makeup)
        }
        if let delay = delayNode {
            if previous?.delayEnabled != next.delayEnabled { delay.bypass = !next.delayEnabled }
            if previous?.delayTime != next.delayTime { delay.delayTime = next.delayTime }
            if previous?.feedback != next.feedback { delay.feedback = Float(next.feedback) }
            if previous?.delayMix != next.delayMix { delay.wetDryMix = Float(next.delayMix) }
        }
        if let reverb = reverbNode, previous?.reverbEnabled != next.reverbEnabled || previous?.reverbRoom != next.reverbRoom || previous?.reverbMix != next.reverbMix || previous?.reverbDecay != next.reverbDecay || previous?.reverbLowCut != next.reverbLowCut || previous?.reverbHighCut != next.reverbHighCut {
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
        if let reverb = reverbNode {
            JarasDynamics.setAnalysisEnabled(reverb, input: true, enabled: effects.contains("Reverb"))
            JarasDynamics.setAnalysisEnabled(reverb, input: false, enabled: effects.contains("Reverb"))
        }
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
        if observesDelay {
            let node = channelDelays["Delay"].flatMap { alternate in connected.contains { $0 === alternate } ? alternate : nil }
            include("Delay", node: node ?? delay)
        }
        for (key, node) in instanceNodes where node is AVAudioUnitDelay && observedEffects.contains(key) {
            let alternate = channelDelays[key].flatMap { candidate in connected.contains { $0 === candidate } ? candidate : nil }
            include(key, node: alternate ?? node)
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
            let reverbIn = reverbNode.map { JarasDynamics.analysisPeaks($0, input: true).map(\.floatValue) } ?? [0, 0]
            let reverbOut = reverbNode.map { JarasDynamics.analysisPeaks($0, input: false).map(\.floatValue) } ?? [0, 0]
            meterCache = ["Compressor":compressor, "Delay":delayIn+delayOut, "Reverb":reverbIn+reverbOut, "Limiter":limiter.map { JarasDynamics.takeCompressorPeaks($0).map(\.floatValue) } ?? [0,0,0,0]]
        }
        return meterCache[effect] ?? [0,0,0,0]
    }
    func compressorReduction(for key: String) -> Double {
        guard let settings, settings.kind(of: key) == "Compressor", settings.isEnabled(key),
              let node = key == "Compressor" ? compressor : instanceNodes[key] as? AVAudioUnitEffect else { return 0 }
        return Double(JarasDynamics.compressorReduction(node))
    }
    func gainReduction(silent: Bool) -> Double? {
        guard let settings else { return nil }
        var result = -1.0
        for key in settings.effectKeys {
            let kind = settings.kind(of: key)
            let enabled = !silent && settings.isEnabled(key)
            switch kind {
            case "Compressor": result = max(result, enabled ? compressorReduction(for: key) : 0)
            case "Limiter":
                let node = key == "Limiter" ? limiter : instanceNodes[key] as? AVAudioUnitEffect
                result = max(result, enabled ? node.map { Double(JarasDynamics.compressorReduction($0)) } ?? 0 : 0)
            case "Soft Clipper":
                result = max(result, enabled ? creativeNodes[key].map { Double(JarasCreativeEffects.gainReduction($0)) } ?? 0 : 0)
            default: break
            }
            #if os(macOS)
            if let plugin = settings.externalPlugins?.first(where: { $0.effectKey == key }),
                    let node = externalNodes[plugin.id] {
                let db = Double(JarasVST3.gainReduction(node, identifier: plugin.id))
                if db >= 0 { result = max(result, silent ? 0 : db) }
            }
            #endif
        }
        return result >= 0 ? result : nil
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
        chain.offlineCreativeTransport(position: position, tempo: 120, playing: true)
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
