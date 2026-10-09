import Foundation
import AVFoundation
import Accelerate

struct AudioExportProgress: Sendable {
    let completed: Int
    let total: Int
    let fileName: String
    let fraction: Double
    let waveform: [Float]
    let clipped: [Bool]
    let peak: Float
}
final class AudioExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
/// Resolve library files and defaults on the UI thread before the offline job.
struct OfflineMIDIInstrument: Sendable {
    let url: URL
    let parameters: InstrumentParameters
    let drums: Bool
    let monophonic: Bool
}
/// A separate offline graph advances every requested output in the same render
/// call. PCM and file I/O stay on the export worker, never on the UI/audio device.
final class OfflineAudioExport {
    private final class Bus {
        let mix = AVAudioMixerNode(), processedMix = AVAudioMixerNode(), pan = AVAudioMixerNode()
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        var effects: NativeEffectsChain?
        var output: AVAudioNode { pan }
    }
    private final class Voice {
        let player: AVAudioPlayerNode
        let file: AVAudioFile
        let clip: AudioClip
        let end: Double
        let origin: Double
        var cursor: Double
        init(player: AVAudioPlayerNode, file: AVAudioFile, clip: AudioClip, start: Double, end: Double, origin: Double) {
            self.origin = origin
            self.player = player; self.file = file; self.clip = clip; cursor = start; self.end = end
        }
        func schedule(until deadline: Double) {
            let rate = file.processingFormat.sampleRate
            let limit = min(end,deadline)
            while cursor < limit - 0.5 / rate / clip.audioRate {
                let elapsed = clip.sourceOffset + (cursor - clip.startTime) * clip.audioRate
                var first = AVAudioFramePosition((elapsed * rate).rounded())
                var boundary = file.length
                if let length = clip.loopLength {
                    let begin = max(0,AVAudioFramePosition(((clip.loopStart ?? 0) * rate).rounded()))
                    boundary = min(file.length,begin + AVAudioFramePosition((length * rate).rounded()))
                    let frames = boundary - begin
                    guard frames > 0 else { cursor = end; return }
                    first = begin + ((first - begin) % frames + frames) % frames
                }
                let count = min(boundary - first, AVAudioFramePosition(((limit-cursor) * rate * clip.audioRate).rounded()), Int64(UInt32.max))
                guard first >= 0, count > 0 else { cursor = end; return }
                player.scheduleSegment(file,startingFrame: first,frameCount: AVAudioFrameCount(count),at: nil,completionHandler: nil)
                cursor += Double(count) / rate / clip.audioRate
            }
        }
    }
    private final class Writer {
        let job: AudioExportJob, temporary: URL, destination: URL
        var file: AVAudioFile?
        var mp3: JarasMP3StreamEncoder?
        var largeWave: ExtAudioFileRef?
        let encoding: AudioExportEncoding
        var buffer: AVAudioPCMBuffer?
        let format: AVAudioFormat
        let frames: Int64
        var written: Int64 = 0
        var waveform = [Float](repeating: 0,count: 600)
        var clipped = [Bool](repeating: false,count: 600)
        var peak: Float = 0
        init(job: AudioExportJob, directory: URL, format: AVAudioFormat, encoding: AudioExportEncoding) throws {
            self.encoding = encoding
            self.job = job; destination = directory.appendingPathComponent(job.fileName)
            temporary = directory.appendingPathComponent(".jaras-render-" + UUID().uuidString + "." + encoding.format.fileExtension)
            frames = Int64((job.duration * format.sampleRate).rounded())
            self.format = format
        }
        func write(_ source: AVAudioPCMBuffer, channels: Int, startingAt offset: Int = 0) throws {
            let count = min(Int64(source.frameLength) - Int64(offset),frames-written)
            guard count > 0 else { return }
            if buffer == nil {
                if encoding.format == .mp3 {
                    mp3 = try JarasMP3StreamEncoder(url: temporary,sampleRate: Int(format.sampleRate),channels: encoding.channels,bitRate: encoding.bitrate)
                } else if encoding.format == .wav && Double(frames)*Double(encoding.channels*encoding.bitDepth/8) > Double(UInt32.max)-4096 {
                    var description = AudioStreamBasicDescription(mSampleRate: format.sampleRate,mFormatID: kAudioFormatLinearPCM,
                        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,mBytesPerPacket: UInt32(encoding.channels*encoding.bitDepth/8),
                        mFramesPerPacket: 1,mBytesPerFrame: UInt32(encoding.channels*encoding.bitDepth/8),mChannelsPerFrame: UInt32(encoding.channels),mBitsPerChannel: UInt32(encoding.bitDepth),mReserved: 0)
                    var status = ExtAudioFileCreateWithURL(temporary as CFURL,kAudioFileRF64Type,&description,nil,AudioFileFlags.eraseFile.rawValue,&largeWave)
                    guard status == noErr, let largeWave else { throw NSError(domain: NSOSStatusErrorDomain,code: Int(status)) }
                    var client = format.streamDescription.pointee
                    status = ExtAudioFileSetProperty(largeWave,kExtAudioFileProperty_ClientDataFormat,UInt32(MemoryLayout<AudioStreamBasicDescription>.size),&client)
                    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain,code: Int(status)) }
                } else {
                    file = try AVAudioFile(forWriting: temporary,settings: [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:format.sampleRate,
                        AVNumberOfChannelsKey:encoding.channels,AVLinearPCMBitDepthKey:encoding.bitDepth,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:encoding.format == .aiff],commonFormat: .pcmFormatFloat32,interleaved: false)
                }
                buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 4096)!
            }
            let buffer = self.buffer!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<encoding.channels {
                let input = source.floatChannelData![channels+channel].advanced(by: offset), output = buffer.floatChannelData![channel]
                if encoding.channels == 1 {
                    vDSP_vadd(source.floatChannelData![channels].advanced(by: offset),1,source.floatChannelData![channels+1].advanced(by: offset),1,output,1,vDSP_Length(count))
                    var half: Float = 0.5; vDSP_vsmul(output,1,&half,output,1,vDSP_Length(count))
                } else { output.update(from: input,count: Int(count)) }
                for frame in 0..<Int(count) {
                    let sample = abs(output[frame])
                    guard sample.isFinite else { throw AudioExportFailure.invalidPCM }
                    let bin = min(599,Int((written+Int64(frame)) * 600 / max(1,frames)))
                    waveform[bin] = max(waveform[bin],sample)
                    if sample >= 1 { clipped[bin] = true }
                    peak = max(peak,sample)
                }
            }
            if let mp3 { try mp3.write(buffer) }
            else if let largeWave {
                let status = ExtAudioFileWrite(largeWave,buffer.frameLength,buffer.audioBufferList)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain,code: Int(status)) }
            } else { try file?.write(from: buffer) }

            written += count
        }
        func finish() throws {
            if let mp3 { try mp3.finish() }; mp3 = nil
            if let ref = largeWave {
                largeWave = nil
                let status = ExtAudioFileDispose(ref)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain,code: Int(status)) }
            }
            file = nil; buffer = nil
            // Publishing happens only after every file finished successfully.
            guard written == frames else { throw AudioExportFailure.incomplete }
        }
        func cleanup() { file = nil; mp3 = nil; if let ref = largeWave { ExtAudioFileDispose(ref); largeWave = nil }; try? FileManager.default.removeItem(at: temporary) }
    }
    static func run(project: Project, song: Song, plan: AudioExportPlan, mediaDirectory: URL, outputDirectory: URL,
                    sampleRate: Double, encoding: AudioExportEncoding = AudioExportEncoding(), secondaryEncoding: AudioExportEncoding? = nil, cancellation: AudioExportCancellation,
                    midiInstruments: [String: OfflineMIDIInstrument]? = nil,
                    includeHardwareOutputs: Bool = false,
                    midiInstrumentsByTrack: [UUID: [String: OfflineMIDIInstrument]] = [:],
                    progress: (AudioExportProgress) -> Void) throws {
        try AudioLicenseAccess.shared.requireAccess()
        guard !plan.jobs.isEmpty else { throw AudioExportFailure.empty }
        guard [44100.0,48000.0].contains(sampleRate) else { throw AudioExportFailure.invalidFormat }
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory,withIntermediateDirectories: true)
        for job in plan.jobs {
            guard !fm.fileExists(atPath: outputDirectory.appendingPathComponent(job.fileName).path) else { throw AudioExportFailure.exists(job.fileName) }
        }
        guard [16,24,32].contains(encoding.bitDepth), [0,1,2].contains(encoding.channels), [128,160,192,224,256,320].contains(encoding.bitrate) else { throw AudioExportFailure.invalidFormat }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate,channels: 2)!
        var writers: [Writer] = []
        var published: [URL] = []
        defer { writers.forEach { $0.cleanup() } }
        do {
            var sourceChannels: [String: Int] = [:]
            for job in plan.jobs {
                var settings = job.output == 1 ? secondaryEncoding ?? encoding : encoding
                if settings.channels == 0 {
                    guard let track = song.tracks.first(where: { $0.id == job.track }),
                          let clip = track.clips.first(where: { $0.id == job.clip }),
                          let audio = clip.audioFile ?? track.audioFile else { throw AudioExportFailure.invalidFormat }
                    if let cached = sourceChannels[audio.path] { settings.channels = cached }
                    else {
                        let file = try AudioFileRead.openMedia(mediaDirectory.appendingPathComponent(audio.path))
                        settings.channels = Int(file.processingFormat.channelCount)
                        sourceChannels[audio.path] = settings.channels
                    }
                }
                guard [16,24,32].contains(settings.bitDepth), [1,2].contains(settings.channels),
                      [128,160,192,224,256,320].contains(settings.bitrate) else { throw AudioExportFailure.invalidFormat }
                let fileFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,channels: AVAudioChannelCount(settings.channels))!
                writers.append(try Writer(job: job,directory: outputDirectory,format: fileFormat,encoding: settings))
            }
            // Stems have independent local origins and durations. Track exports
            // share a range and graph, including folder and Master processing.
            let stems = plan.jobs.first?.clip != nil
            var batches: [[Int]] = []
            if stems {
                // Bound graph/file memory for very large item selections.
                for start in stride(from: 0,to: writers.count,by: 200) { batches.append(Array(start..<min(start+200,writers.count))) }
            } else {
                for index in writers.indices {
                    if let batch = batches.firstIndex(where: { writers[$0[0]].job.start == writers[index].job.start && writers[$0[0]].job.end == writers[index].job.end && writers[$0[0]].job.minimumClipStart == writers[index].job.minimumClipStart }) { batches[batch].append(index) }
                    else { batches.append([index]) }
                }
            }
            var completed = 0
            for batch in batches {
                if cancellation.cancelled { throw CancellationError() }
                let current = batch.map { writers[$0] }
                try render(project: project,song: song,writers: current,mediaDirectory: mediaDirectory,format: stereo,
                           cancellation: cancellation,midiInstruments: midiInstruments,includeHardwareOutputs: includeHardwareOutputs,
                           midiInstrumentsByTrack: midiInstrumentsByTrack,completed: completed,total: writers.count,progress: progress)
                for writer in current { try writer.finish() }
                completed += batch.count
            }
            if cancellation.cancelled { throw CancellationError() }
            for writer in writers {
                // moveItem refuses to replace a destination created during export.
                try fm.moveItem(at: writer.temporary,to: writer.destination); published.append(writer.destination)
            }
            if let last = writers.last { progress(AudioExportProgress(completed: writers.count,total: writers.count,fileName: last.job.fileName,fraction: 1,waveform: last.waveform,clipped: last.clipped,peak: last.peak)) }
        } catch {
            // Roll back only new files from this export; existing files are preserved.
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
    }
    private static func render(project: Project, song: Song, writers: [Writer], mediaDirectory: URL, format: AVAudioFormat,
                               cancellation: AudioExportCancellation,midiInstruments: [String: OfflineMIDIInstrument]?,includeHardwareOutputs: Bool,
                               midiInstrumentsByTrack: [UUID: [String: OfflineMIDIInstrument]],completed: Int,total: Int,
                               progress: (AudioExportProgress) -> Void) throws {
        let engine = AVAudioEngine()
        var effectChains: [NativeEffectsChain] = []
        defer {
            engine.stop()
            #if os(macOS)
            for effects in effectChains { try? effects.stopStemSeparatorAndWait() }
            #endif
            effectChains.forEach { $0.detach(from: engine) }
        }
        var laneKeys: [String: Int] = [:], writerLanes: [Int] = []
        for writer in writers {
            let key = writer.job.clip?.uuidString ?? writer.job.track?.uuidString ?? "Master"
            let lane = laneKeys[key] ?? laneKeys.count
            laneKeys[key] = lane; writerLanes.append(lane)
        }
        let count = AVAudioChannelCount(laneKeys.count * 2)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count)!
        let packed = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,channelLayout: layout)
        try engine.enableManualRenderingMode(.offline,format: packed,maximumFrameCount: 4096)
        engine.connect(engine.mainMixerNode,to: engine.outputNode,format: packed)
        var buses: [UUID:Bus] = [:]
        let hasMaster = writers.contains { $0.job.track == nil }
        func feedsMaster(_ track: Track) -> Bool {
            track.outputPatches.contains(.master) || (includeHardwareOutputs && project.masterSolo != true &&
                track.outputPatches.contains { $0.firstChannel > 0 })
        }
        var needed = Set(writers.compactMap { $0.job.track })
        if hasMaster { needed.formUnion(song.tracks.filter(feedsMaster).map(\.id)) }
        let connections = song.trackConnections
        var changed = true
        while changed {
            let before = needed.count
            needed.formUnion(connections.filter { needed.contains($0.destination) }.map(\.source))
            needed.formUnion(song.tracks.filter { track in
                guard let parent = track.parentTrackID, needed.contains(parent) else { return false }
                return track.outputPatches.contains(.masterGroup)
            }.map(\.id))
            changed = needed.count != before
        }
        var voices: [Voice] = []
        var midiSamplers: [JarasSoundFont] = []
        defer { midiSamplers.forEach { $0.silence() } }
        var clickGenerators: [JarasMetronomeGenerator] = []
        defer { withExtendedLifetime(clickGenerators) {} }
        var starts: [(AVAudioPlayerNode,AVAudioTime,Double)] = []
        var sourceClocks: [(AVAudioNode, (Double) -> Void)] = []
        var itemFades: [(NativeEffectsChain, AudioClip, Double, Double, Double)] = []
        let preroll = 4096
        func makeBus(fx: NativeFXSettings?, volume: Double, pan: Double, muted: Bool, mono: Bool = false, phaseInverted: Bool = false) throws -> Bus {
            let bus = Bus()
            for node in [bus.mix,bus.processedMix,bus.gain,bus.pan] as [AVAudioNode] { engine.attach(node) }
            engine.connect(bus.processedMix,to: bus.gain,format: format)
            if mono || phaseInverted {
                let matrix = JarasEqualizer.makeNode(); engine.attach(matrix)
                if mono { JarasEqualizer.setInputChannelMode(matrix, mode: 3) }
                JarasEqualizer.setPolarity(matrix, inverted: phaseInverted)
                engine.connect(bus.gain, to: matrix, format: format)
                engine.connect(matrix, to: bus.pan, format: format)
            } else { engine.connect(bus.gain,to: bus.pan,format: format) }
            if let fx, fx.eqEnabled || fx.compressorEnabled || fx.delayEnabled || fx.reverbEnabled || fx.pitchEnabled == true || fx.limiterEnabled == true || fx.externalPlugins?.isEmpty == false || fx.instances?.isEmpty == false || !fx.instrumentKeys.isEmpty || fx.isEnabled(NativeFXSettings.stemSeparator) {
                let effects = NativeEffectsChain(); bus.effects = effects
                effectChains.append(effects)
                effects.attach(to: engine,input: bus.mix,format: format,destinations: [AVAudioConnectionPoint(node: bus.processedMix,bus: 0)])
                effects.apply(fx)
                #if os(macOS)
                effects.externalTransport(position: writers[0].job.start - Double(preroll) / format.sampleRate, tempo: song.bpm, beats: Int32(song.meterBeats), unit: Int32(song.meterUnit), playing: true)
                if let error = effects.externalError { throw error }
                #endif
            } else { engine.connect(bus.mix,to: bus.processedMix,format: format) }
            bus.gain.globalGain = Float(max(-96,min(24,20*log10(max(0.00000001,volume)))))
            bus.pan.outputVolume = muted || volume <= 0 ? 0 : 1; bus.pan.pan = Float(pan)
            let silence = AVAudioSourceNode(format: format) { silent,_,_,buffers in
                silent.pointee = true
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) { if let data = buffer.mData { memset(data,0,Int(buffer.mDataByteSize)) } }
                return noErr
            }
            engine.attach(silence); engine.connect(silence,to: bus.mix,fromBus: 0,toBus: 0,format: format)
            return bus
        }
        var links: [ObjectIdentifier:[AVAudioConnectionPoint]] = [:]
        var nodes: [ObjectIdentifier:AVAudioNode] = [:]
        func link(_ from: AVAudioNode, _ to: AVAudioNode, _ bus: AVAudioNodeBus) {
            let id = ObjectIdentifier(from); nodes[id] = from
            links[id,default:[]].append(AVAudioConnectionPoint(node: to,bus: bus))
        }
        let multiplexer = JarasExportMultiplexer.makeNode(laneKeys.count)
        engine.attach(multiplexer)
        engine.connect(multiplexer,to: engine.mainMixerNode,format: packed)
        var capturedLanes: Set<Int> = []
        var capturedNodes: [Int: AVAudioNode] = [:]
        func capture(_ node: AVAudioNode,index: Int) {
            let index = writerLanes[index]
            guard capturedLanes.insert(index).inserted else { return }
            capturedNodes[index] = node
            let lane = AVAudioMixerNode(); engine.attach(lane)
            engine.connect(lane,to: multiplexer,fromBus: 0,toBus: AVAudioNodeBus(index),format: format)
            link(node,lane,0)
        }

        func addClip(_ clip: AudioClip,track: Track,bus: Bus,start: Double,end: Double,pitchStart: Double? = nil) throws {
            if cancellation.cancelled { throw CancellationError() }
            guard clip.muted != true, !clip.isImage, let audio = clip.audioFile ?? track.audioFile else { return }
            let begin = max(start,clip.startTime), finish = min(end,clip.startTime+clip.duration)
            guard finish > begin else { return }
            if clip.isProjectionMedia && AVURLAsset(url: mediaDirectory.appendingPathComponent(audio.path)).tracks(withMediaType: .audio).isEmpty { return }
            let file = try AudioFileRead.openMedia(mediaDirectory.appendingPathComponent(audio.path))
            let player = AVAudioPlayerNode(), gain = AVAudioUnitEQ(numberOfBands: 0)
            engine.attach(player); engine.attach(gain)
            player.pan = Float(clip.pan ?? 0)
            let sourceFormat = file.processingFormat
            var source: AVAudioNode = player
            let semitones = (clip.pitchSemitones ?? 0) + (clip.frozenMIDI == true || clip.renderedTiming == true ? 0 : Double(song.pitch(for: track.id, region: song.pitchRegion(at: pitchStart ?? clip.startTime))))
            if abs(clip.audioRate - 1) > 0.0000001 || semitones != 0 {
                let stretch = AVAudioUnitTimePitch(); stretch.rate = Float(clip.audioRate); stretch.pitch = Float(semitones * 100); stretch.overlap = 8
                engine.attach(stretch); engine.connect(player,to: stretch,format: sourceFormat); source = stretch
            }
            gain.globalGain = Float(max(-96,min(24,20*log10(max(0.00000001,clip.gain ?? 1)))))
            if (clip.gain ?? 1) <= 0 { player.volume = 0 }
            let fx = clip.fxBypassed == true ? NativeFXSettings() : (clip.fx ?? NativeFXSettings())
            if clip.phaseInverted == true || (clip.fadeIn ?? 0) > 0 || (clip.fadeOut ?? 0) > 0 || (clip.channelMode ?? 0) != 0 || (clip.normalizationGain ?? 1) != 1 || fx.eqEnabled || fx.compressorEnabled || fx.delayEnabled || fx.reverbEnabled || fx.pitchEnabled == true || fx.limiterEnabled == true || fx.isEnabled(NativeFXSettings.stemSeparator) {
                let effects = NativeEffectsChain()
                effectChains.append(effects)
                effects.attach(to: engine,input: source,format: sourceFormat,destinations: [AVAudioConnectionPoint(node: gain,bus: 0)])
                effects.apply(fx); effects.setSourcePolarity(clip.phaseInverted == true); effects.setSourceGain(clip.normalizationGain ?? 1); effects.setSourceChannelMode(clip.channelMode ?? 0)
                effects.configureItemFade(clip, position: begin, sampleTime: (begin - start + Double(preroll) / format.sampleRate) * sourceFormat.sampleRate)
                itemFades.append((effects, clip, begin, start, sourceFormat.sampleRate))
            } else { engine.connect(source,to: gain,format: sourceFormat) }
            // Frozen MIDI already contains the ordered track FX; item FX and
            // the track fader/pan still operate on this editable audio item.
            let destination = clip.frozenMIDI == true ? bus.processedMix : bus.mix
            engine.connect(gain,to: destination,fromBus: 0,toBus: destination.nextAvailableInputBus,format: sourceFormat)
            let voice = Voice(player: player,file: file,clip: clip,start: begin,end: finish,origin: start)
            voice.schedule(until: clip.loopLength == nil ? finish : begin+0.25)
            let delay = begin-start + Double(preroll)/format.sampleRate
            // Player sample time is upstream of TimePitch: its waiting frames
            // are consumed at the item's rate along with the audio frames.
            starts.append((player,AVAudioTime(sampleTime: AVAudioFramePosition((delay*sourceFormat.sampleRate*clip.audioRate).rounded()),atRate: sourceFormat.sampleRate),clip.audioRate))
            voices.append(voice)
        }
        func addMIDI(_ clips: [AudioClip], track: Track, bus: Bus, start: Double) throws {
            guard !clips.isEmpty, let fx = track.fx, let effects = bus.effects else { return }
            let instruments = midiInstrumentsByTrack[track.id] ?? midiInstruments ?? [:]
            // One sequence per track preserves all clips for VST3, and one
            // sampler per slot keeps overlapping notes on the same instrument.
            var playbackNotes: [MIDIPlaybackNote] = clips.flatMap { song.midiPlaybackNotes(in: $0) }
            playbackNotes.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.channel != $1.channel { return $0.channel < $1.channel }
                return $0.pitch < $1.pitch
            }
            let notes: [[String: Double]] = playbackNotes.map {
                ["start": $0.start, "end": $0.end, "pitch": Double($0.pitch), "velocity": Double($0.velocity), "channel": Double($0.channel)]
            }
            let position = start - Double(preroll) / format.sampleRate
            #if os(macOS)
            effects.setMIDISequence(notes)
            effects.setMIDISequenceClock(head: 0, position: position, clock: 0, running: true, loopStart: 0, loopEnd: 0)
            for node in effects.externalNodes.values {
                sourceClocks.append((node, { delay in
                    JarasVST3.sequenceClock(node, head: 0, position: position - delay, clock: 0, running: true, loopStart: 0, loopEnd: 0)
                }))
            }
            #endif
            for key in fx.instrumentKeys where fx.isEnabled(key) {
                if cancellation.cancelled { throw CancellationError() }
                guard let source = instruments[key], let destination = effects.instrumentInput(for: key) else {
                    throw ProjectError.invalid(JarasLocalization.string("Download the instrument before converting this MIDI item."))
                }
                let sampler = try JarasSoundFont(url: source.url, sampleRate: format.sampleRate)
                let settings = source.parameters, controllers = settings.controllers ?? InstrumentControllerParameters()
                let volume = controllers.volume ?? 0
                sampler.setGain(volume <= -96 ? -96 : settings.gain + volume, pan: 0)
                sampler.setEnvelopeAttack(settings.attack, hold: settings.hold, decay: settings.decay, sustain: settings.sustain, release: settings.release)
                sampler.setControllersModulation(controllers.modulation, pitchBend: controllers.pitchBend)
                let velocity = settings.velocity ?? InstrumentVelocityParameters(), cutoff = settings.cutoff ?? InstrumentCutoffParameters()
                sampler.setPerformanceMonophonic(controllers.monophonic ?? source.monophonic, drums: source.drums, velocityCurve: Int32(velocity.curve.index))
                sampler.setFilterCutoff(cutoff.frequency, velocityMinimum: velocity.cutoffMinimum, attack: cutoff.attack, hold: cutoff.hold, decay: cutoff.decay, sustain: cutoff.sustain, release: cutoff.release, depth: cutoff.depth)
                engine.attach(sampler.node)
                engine.connect(sampler.node, to: destination, fromBus: 0, toBus: destination.nextAvailableInputBus, format: format)
                sampler.setSequenceNotes(notes)
                sampler.sequenceHead(0, position: position, clock: 0, running: true, loopStart: 0, loopEnd: 0)
                sourceClocks.append((sampler.node, { delay in
                    sampler.sequenceHead(0, position: position - delay, clock: 0, running: true, loopStart: 0, loopEnd: 0)
                }))
                midiSamplers.append(sampler)
            }
        }
        func addClick(track: Track, clips: [AudioClip], bus: Bus, start: Double, end: Double) throws {
            var source = track; source.clips = clips
            let sections = ClickTrackProgram.sections(song: song, track: source).compactMap { section -> [String: Double]? in
                let first = max(start, section.start), last = min(end, section.end)
                guard first < last else { return nil }
                return ["start": first, "end": last, "origin": section.origin, "bpm": section.bpm,
                    "beats": Double(section.beats), "unit": Double(section.unit)]
            }
            guard !sections.isEmpty else { return }
            let url = track.clickSound.map { mediaDirectory.appendingPathComponent($0.path) }
            // Match live playback: missing custom media stays silent.
            if let url, !FileManager.default.fileExists(atPath: url.path) { return }
            let sound = try ClickAudioSample.load(sampleRate: format.sampleRate, url: url)
            let generator = JarasMetronomeGenerator(format: format)
            generator.setClickSections(sections, sound: sound)
            generator.configurePosition(start - Double(preroll) / format.sampleRate, hostTime: mach_absolute_time(),
                running: true, loopStart: 0, loopEnd: 0, sampleTime: 0)
            engine.attach(generator.node)
            engine.connect(generator.node, to: bus.mix, fromBus: 0, toBus: bus.mix.nextAvailableInputBus, format: format)
            sourceClocks.append((generator.node, { delay in
                generator.configurePosition(start - Double(preroll) / format.sampleRate - delay, hostTime: mach_absolute_time(),
                    running: true, loopStart: 0, loopEnd: 0, sampleTime: 0)
            }))
            clickGenerators.append(generator)
        }
        let stems = writers.first?.job.clip != nil
        // Legacy item freeze/glue keep track polarity live. The hardware mix
        // explicitly prints the audible track polarity into its final Master.
        if stems {
            for (index,writer) in writers.enumerated() {
                guard let track = song.tracks.first(where: { $0.id == writer.job.track }), let clip = track.clips.first(where: { $0.id == writer.job.clip }) else { throw AudioExportFailure.incomplete }
                if let bus = buses[clip.id] { capture(bus.output,index: index) }
                else {
                    let bus = try makeBus(fx: track.fx,volume: track.volume,pan: track.pan,muted: song.isSilenced(track),phaseInverted: includeHardwareOutputs && track.phaseInverted == true)
                    buses[clip.id] = bus; capture(bus.output,index: index)
                    if clip.midi != nil { try addMIDI([clip],track: track,bus: bus,start: writer.job.start) }
                    else { for fragment in song.tempoAudioSegments(clip) {
                        try addClip(fragment,track: track,bus: bus,start: writer.job.start,end: writer.job.end,pitchStart: clip.startTime)
                    } }
                }
            }
        } else {
            let root = hasMaster ? try makeBus(fx: project.masterFX,volume: project.masterVolume ?? 1,pan: 0,muted: project.masterMute ?? false, mono: project.masterMono ?? false) : nil
            let tracks = song.tracks.filter { ($0.kind == .standard || $0.kind == .click || $0.clips.contains(where: \.isProjectionMedia)) && needed.contains($0.id) }
            for track in tracks {
                buses[track.id] = try makeBus(fx: track.fx,volume: track.volume,pan: track.pan,muted: song.isSilenced(track),phaseInverted: includeHardwareOutputs && track.phaseInverted == true)
            }
            for track in tracks {
                // Drawer songs share their parent's generated click item;
                // the onset cutoff applies to stems, not that musical program.
                let clips = track.clips.filter { writers[0].job.includes($0) || (track.kind == .click && $0.audioFile == nil) }
                try addMIDI(clips.filter { $0.midi != nil }, track: track, bus: buses[track.id]!, start: writers[0].job.start)
                if track.kind == .click { try addClick(track: track, clips: clips, bus: buses[track.id]!, start: writers[0].job.start, end: writers[0].job.end) }
                for clip in clips where clip.midi == nil && (track.kind == .standard || clip.isProjectionMedia || (track.kind == .click && clip.audioFile != nil)) {
                    for fragment in song.tempoAudioSegments(clip) {
                        try addClip(fragment,track: track,bus: buses[track.id]!,start: writers[0].job.start,end: writers[0].job.end,pitchStart: clip.startTime)
                    }
                }
            }
            for track in tracks {
                let bus = buses[track.id]!
                let outputs = Set(track.outputPatches)
                if let root, feedsMaster(track) { link(bus.output,root.mix,root.mix.nextAvailableInputBus + AVAudioNodeBus(links.values.flatMap { $0 }.filter { $0.node === root.mix }.count)) }
                if outputs.contains(.masterGroup), let parent = track.parentTrackID, let target = buses[parent] {
                    link(bus.output,target.mix,target.mix.nextAvailableInputBus + AVAudioNodeBus(links.values.flatMap { $0 }.filter { $0.node === target.mix }.count))
                }
            }
            for edge in song.trackConnections {
                if let source = buses[edge.source], let target = buses[edge.destination] {
                    link(source.output, target.mix, target.mix.nextAvailableInputBus + AVAudioNodeBus(links.values.flatMap { $0 }.filter { $0.node === target.mix }.count))
                }
            }
            for (index,writer) in writers.enumerated() {
                guard let output = writer.job.track.flatMap({ buses[$0]?.output }) ?? root?.output else { throw AudioExportFailure.incomplete }
                capture(output,index: index)
            }
        }
        for (id,destinations) in links { engine.connect(nodes[id]!,to: destinations,fromBus: 0,format: format) }
        let buffer = AVAudioPCMBuffer(pcmFormat: packed,frameCapacity: 4096)!
        engine.prepare(); try engine.start()
        #if os(macOS)
        // This graph is owned by the export worker. A loading or failed model
        // must finish/fail here, before any output is published as processed.
        for effects in effectChains { try effects.waitForStemSeparator(cancellation: { cancellation.cancelled }) }
        let compensatesLatency = effectChains.contains { $0.stemSeparatorLatency > 0 }
        #else
        let compensatesLatency = false
        #endif
        func checkProcessors() throws {
            #if os(macOS)
            for effects in effectChains {
                if let status = effects.stemSeparatorStatus, status["state"] as? String == "fault" {
                    throw ProjectError.invalid(status["error"] as? String ?? "CatStem processing failed")
                }
            }
            #endif
        }
        let playerLatencies = starts.map { compensatesLatency ? max(0, $0.0.outputPresentationLatency) : 0 }
        let clockLatencies = sourceClocks.map { compensatesLatency ? max(0, $0.0.latency + $0.0.outputPresentationLatency) : 0 }
        let maximumLatency = (playerLatencies + clockLatencies).max() ?? 0
        var captureStarts = [Int64](repeating: Int64(preroll), count: laneKeys.count)
        if compensatesLatency {
            for (lane, node) in capturedNodes {
                // A track captured directly may also feed a delayed Master.
                // Its local beginning precedes the Master beginning; trim each
                // captured lane at its own origin instead of losing that PCM.
                captureStarts[lane] += Int64((max(0, maximumLatency - node.outputPresentationLatency) * format.sampleRate).rounded())
            }
            for (index, binding) in sourceClocks.enumerated() { binding.1(max(0, maximumLatency - clockLatencies[index])) }
            for (effects, clip, begin, origin, sourceRate) in itemFades {
                let delay = max(0, maximumLatency - effects.equalizer.outputPresentationLatency)
                effects.configureItemFade(clip, position: begin,
                    sampleTime: (begin - origin + Double(preroll) / format.sampleRate + delay) * sourceRate)
            }
        }
        for (index, entry) in starts.enumerated() {
            let (player, time, rate) = entry
            let additional = max(0, maximumLatency - playerLatencies[index])
            let compensated = AVAudioTime(sampleTime: time.sampleTime + AVAudioFramePosition((additional * time.sampleRate * rate).rounded()), atRate: time.sampleRate)
            player.play(at: compensatesLatency ? compensated : time)
        }
        let loopVoices = voices.filter { $0.clip.loopLength != nil }
        func scheduleLoops(at frame: Int64) {
            let time = max(0, Double(frame - Int64(preroll)) / format.sampleRate)
            for voice in loopVoices { voice.schedule(until: voice.origin + time + 0.25) }
        }
        let warmupFrames = captureStarts.min() ?? Int64(preroll)
        var warm = warmupFrames, retry = 0
        while warm > 0 {
            if cancellation.cancelled { throw CancellationError() }
            if compensatesLatency { scheduleLoops(at: warmupFrames - warm) }
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096, warm)),to: buffer)
            try checkProcessors()
            if status == .success {
                guard buffer.frameLength > 0 else { throw AudioExportFailure.render }
                warm -= Int64(buffer.frameLength); retry = 0
            }
            else { retry += 1; if retry > 100 { throw AudioExportFailure.render } }
        }
        let renderEnd = writers.enumerated().map { captureStarts[writerLanes[$0.offset]] + $0.element.frames }.max() ?? warmupFrames
        var rendered = warmupFrames, lastUpdate = 0.0
        while rendered < renderEnd {
            try AudioLicenseAccess.shared.requireAccess()
            if cancellation.cancelled { throw CancellationError() }
            scheduleLoops(at: rendered)
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096,renderEnd-rendered)),to: buffer)
            try checkProcessors()
            guard status == .success else { retry += 1; if retry > 100 { throw AudioExportFailure.render }; continue }
            guard buffer.frameLength > 0 else { throw AudioExportFailure.render }
            retry = 0
            for (index,writer) in writers.enumerated() {
                let lane = writerLanes[index]
                let skip = Int(max(0, captureStarts[lane] - rendered))
                if skip < Int(buffer.frameLength) { try writer.write(buffer,channels: lane*2,startingAt: skip) }
            }
            rendered += Int64(buffer.frameLength)
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastUpdate >= 0.08 || rendered == renderEnd {
                lastUpdate = now
                let done = writers.filter { $0.written == $0.frames }.count
                let current = writers.first { $0.written < $0.frames } ?? writers.last!
                progress(AudioExportProgress(completed: completed+done,total: total,fileName: current.job.fileName,
                    fraction: Double(current.written)/Double(max(1,current.frames)),waveform: current.waveform,clipped: current.clipped,peak: current.peak))
            }
        }
    }
}
enum AudioExportFailure: LocalizedError {
    case empty, incomplete, render, invalidPCM, invalidFormat, exists(String)
    var errorDescription: String? {
        switch self {
        case .empty: return JarasLocalization.string("Select files to render.")
        case .incomplete: return JarasLocalization.string("The render did not finish.")
        case .render: return JarasLocalization.string("The audio engine could not render this project.")
        case .invalidPCM: return JarasLocalization.string("The render produced invalid audio samples.")
        case .invalidFormat: return JarasLocalization.string("Choose 44.1 kHz or 48 kHz.")
        case .exists(let name): return JarasLocalization.string("A file already exists:") + " " + name
        }
    }
}
