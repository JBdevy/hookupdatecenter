import Foundation
import Combine
import CoreMIDI

/// One selected SMK endpoint, paired with its own return endpoint. All device
/// traffic and feedback run on the control thread, outside audio rendering.
@MainActor final class SMK37Link: ObservableObject {
    static let shared = SMK37Link()
    @Published private(set) var connected = false
    private var client: MIDIClientRef = 0
    private var input: MIDIPortRef = 0
    private var output: MIDIPortRef = 0
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private var sourceID: Int32 = 0
    private var session = SMK37Session()
    private var stream = SMK37Stream()
    private var timer: Timer?
    private var lastHello = -Double.infinity
    private var pending: [String: [UInt8]] = [:]
    private var sent: [String: [UInt8]] = [:]
    private var observations = Set<AnyCancellable>()
    private weak var show: ShowController?
    private var remoteEvent: ((SMK37Session.Event) -> Void)?
    private var remotePoll: (() -> Void)?
    private var remoteSources: Set<Int32>?
    private var serial: UInt8 = 0
    private var lastPad: Int?
    private var lastPadPreset: Int?
    private var lastLibrary: VinhetasLibrary?
    private var firmwareMaintenance = false
    func setFirmwareMaintenance(_ active: Bool) {
        firmwareMaintenance = active
        if active { disconnect() } else { refresh() }
    }
    var selectedSMKAvailable: Bool {
        let audio = AudioDeviceSettings.shared
        return audio.midiDevices.contains { audio.midiSlots.contains($0.id) && SMK37Protocol.isDeviceName($0.name) }
    }
    private init() {}
    func bind(_ show: ShowController) {
        if self.show !== show || remoteEvent != nil { disconnect() }
        self.show = show; remoteEvent = nil; remotePoll = nil; remoteSources = nil
        show.smkListFeedback = { [weak self] kind, rows in self?.navigation(kind: kind, rows: rows) }
        show.smkFeedback = { [weak self] label, color in self?.feedback(label, color: color) }
        show.smkPreviewPage = { step in
            TeleprompterWindow.shared.selectPreviewPage(TeleprompterWindow.shared.previewPage + step)
        }
        show.smkRecord = { [weak show] in if let show { TrackRecording.shared.toggle(show: show) } }
        start()
    }
    func bindRemote(sources: Set<Int32>, event: @escaping (SMK37Session.Event) -> Void, poll: @escaping () -> Void) {
        if show != nil || remoteEvent == nil { disconnect() }
        show = nil; remoteSources = sources; remoteEvent = event; remotePoll = poll; start()
    }
    func updateRemote(event: @escaping (SMK37Session.Event) -> Void, poll: @escaping () -> Void) {
        guard remoteEvent != nil else { return }; remoteEvent = event; remotePoll = poll
    }
    func remoteInputs(_ ids: Set<Int32>) {
        guard remoteEvent != nil, remoteSources != ids else { return }; remoteSources = ids; refresh()
    }
    func remoteLibrary(_ pads: DAWRemoteVinhetas) {
        guard pads.valid else { return }
        session.selectHostPreset(pads.selectedPreset)
        if lastPadPreset != pads.selectedPreset { lastPad = nil }
        for (index, preset) in pads.presets.enumerated() {
            queue("preset:\(index)", SMK37Protocol.preset(index, name: preset.name, rgb: preset.color))
            if index == pads.selectedPreset {
                for (pad, value) in preset.pads.enumerated() {
                    queue("pad:\(index):\(pad)", SMK37Protocol.pad(pad, preset: index, name: value.name, rgb: value.color))
                }
            }
        }
        let active = pads.presets[pads.selectedPreset].pads.enumerated().reduce(UInt16(0)) { $1.element.active ? $0 | (1 << $1.offset) : $0 }
        queue("selection", SMK37Protocol.selection(preset: pads.selectedPreset, pad: lastPad, serial: serial, active: active))
    }
    func unbindRemote() { if remoteEvent != nil { disconnect(); remoteEvent = nil; remotePoll = nil; remoteSources = nil } }
    func unbind(_ show: ShowController) { if self.show === show { disconnect(); self.show = nil } }
    func claims(device: Int32, status: UInt8, number: UInt8) -> Bool {
        device == sourceID && session.claims(status: status, number: number)
    }
    private func start() {
        if client == 0 {
            guard MIDIClientCreateWithBlock("CatLive SMK37" as CFString, &client, { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }) == noErr else { return }
            guard MIDIOutputPortCreate(client, "SMK37 Feedback" as CFString, &output) == noErr else { return }
            guard MIDIInputPortCreateWithBlock(client, "SMK37 Input" as CFString, &input, { [weak self] list, context in
                let endpoint = MIDIEndpointRef(UInt(bitPattern: context))
                var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
                var bytes: [UInt8] = []
                for _ in 0..<list.pointee.numPackets {
                    let payload = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
                    bytes.append(contentsOf: UnsafeBufferPointer(start: payload, count: Int(packet.pointee.length)))
                    packet = UnsafePointer(MIDIPacketNext(packet))
                }
                let received = bytes
                Task { @MainActor in self?.receive(received, endpoint: endpoint) }
            }) == noErr else { return }
            AudioDeviceSettings.shared.$midiSlots.sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }.store(in: &observations)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
        refresh()
    }
    private func name(_ object: MIDIObjectRef) -> String {
        var text: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &text)
        return text?.takeRetainedValue() as String? ?? ""
    }
    private func refresh() {
        guard !firmwareMaintenance else { return }
        guard input != 0, show != nil || remoteEvent != nil else { disconnect(); return }
        let selected: Set<Int32> = remoteSources ?? Set<Int32>(AudioDeviceSettings.shared.midiSlots.filter { $0 != 0 })
        var candidate: MIDIEndpointRef = 0, candidateID: Int32 = 0
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index); var id: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
            if selected.contains(id) && SMK37Protocol.isDeviceName(name(endpoint)) { candidate = endpoint; candidateID = id; break }
        }
        var target: MIDIEndpointRef = 0, entity: MIDIEntityRef = 0
        if candidate != 0 {
            MIDIEndpointGetEntity(candidate, &entity)
            let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
            target = destinations.first { endpoint in
                var other: MIDIEntityRef = 0; MIDIEndpointGetEntity(endpoint, &other)
                return entity != 0 && entity == other
            } ?? 0
            if target == 0 {
                let matches = destinations.filter { name($0) == name(candidate) }
                if matches.count == 1 { target = matches[0] }
            }
        }
        guard candidate != 0, target != 0 else { disconnect(); return }
        if source != candidate || destination != target {
            disconnect(); source = candidate; sourceID = candidateID; destination = target
            if MIDIPortConnectSource(input, source, UnsafeMutableRawPointer(bitPattern: Int(source))) != noErr { disconnect() }
        }
    }
    private func disconnect() {
        if destination != 0 { _ = write(SMK37Protocol.encode(2)) }
        dispatch(session.close())
        if source != 0, input != 0 { MIDIPortDisconnectSource(input, source) }
        source = 0; sourceID = 0; destination = 0; stream = SMK37Stream()
        pending.removeAll(); sent.removeAll(); lastLibrary = nil; lastPad = nil; lastHello = -.infinity
        if connected { connected = false }
    }
    private func receive(_ bytes: [UInt8], endpoint: MIDIEndpointRef) {
        guard endpoint == source else { return }
        for message in stream.feed(bytes) {
            switch message {
            case .sysex(let bytes): dispatch(session.receive(bytes, at: ProcessInfo.processInfo.systemUptime))
            case .short(let status, let number, let value): dispatch(session.midi(status: status, number: number, value: value))
            }
        }
        if connected != session.connected { connected = session.connected }
    }
    private func dispatch(_ events: [SMK37Session.Event]) {
        for event in events {
            if case .connected = event { sent.removeAll(); pending.removeAll(); lastLibrary = nil }
            if let remoteEvent { remoteEvent(event); continue }
            guard let show else { continue }
            switch event {
            case .connected: break
            case .preset(let index): VinhetasController.shared.select(index)
            case .padDown(let token, let preset, let pad):
                VinhetasController.shared.controllerDown(token: token, preset: preset, pad: pad)
                padSelected(pad)
            case .padUp(let token): VinhetasController.shared.controllerUp(token: token)
            case .action(let action):
                guard ControlMappings.shared.editing == nil, show.canExecute() else { continue }
                show.performSMKAction(action)
                DispatchQueue.main.async { [weak self, weak show] in
                    guard let self, let show else { return }; self.actionFeedback(action, show: show)
                }
            }
        }
    }
    func feedback(_ title: String, color: UInt32 = 0xeeeeee) {
        guard session.connected else { return }
        pending["navigation"] = nil
        queue("action", SMK37Protocol.action(title, rgb: color), force: true); flush()
    }
    func navigation(kind: Int, rows: [String]) {
        pending["action"] = nil
        queue("navigation", SMK37Protocol.navigation(kind: kind, rows: rows), force: true); flush()
    }
    func playlist(_ name: String) { queue("playlist", SMK37Protocol.playlist(name)) }
    func playback(position: Double, start: Double, end: Double) {
        queue("playback", SMK37Protocol.playback(position: position, start: start, end: end))
    }
    func padSelected(_ pad: Int) {
        guard (0..<16).contains(pad) else { return }
        lastPad = pad; lastPadPreset = show != nil ? VinhetasController.shared.library.selectedPreset : session.preset
        serial = (serial &+ 1) & 127
    }
    func library(_ library: VinhetasLibrary, active: UInt16) {
        session.selectHostPreset(library.selectedPreset)
        if lastLibrary != library {
            for (index, preset) in library.presets.enumerated() {
                queue("preset:\(index)", SMK37Protocol.preset(index, name: preset.name, rgb: preset.color))
                if index == library.selectedPreset {
                    for (pad, value) in preset.pads.enumerated() {
                        queue("pad:\(index):\(pad)", SMK37Protocol.pad(pad, preset: index, name: value.name, rgb: value.color))
                    }
                }
            }
            if lastPadPreset != library.selectedPreset { lastPad = nil; serial = (serial &+ 1) & 127 }
            lastLibrary = library
        }
        queue("selection", SMK37Protocol.selection(preset: library.selectedPreset, pad: lastPad, serial: serial, active: active))
    }
    func transport(paused: Bool, recording: Bool, looping: Bool, auto: Bool, preview: Bool, playing: Bool, queued: Bool, loopName: String, loopColor: UInt32) {
        queue("transport", SMK37Protocol.transport(paused: paused, recording: recording, looping: looping, auto: auto, preview: preview, playing: playing, queued: queued))
        queue("loop", SMK37Protocol.loop(loopName, rgb: loopColor))
    }
    func fadeout(active: Bool, remaining: Double, duration: Double) {
        queue("fadeout", SMK37Protocol.fadeout(active: active, remaining: remaining, duration: duration))
    }
    private func poll() {
        guard !firmwareMaintenance else { return }
        guard source != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        dispatch(session.expire(at: now))
        if connected != session.connected { connected = session.connected }
        if now - lastHello >= 1 { if write(SMK37Protocol.encode(1)) { lastHello = now } }
        guard session.connected else { return }
        if let show {
            playlist(show.selectedRegionPlaylist?.name ?? "All regions")
            let pads = VinhetasController.shared
            let active = pads.voices.values.filter { $0.preset == pads.library.selectedPreset }.reduce(UInt16(0)) { $0 | (1 << $1.pad) }
            library(pads.library, active: active)
            let t = show.snapshot.transport
            let run = show.transportFadeout.run
            fadeout(active: run != nil, remaining: run?.remaining ?? 0, duration: run?.duration ?? 0)
            let region = show.current?.sectionPlaybackRegion(for: t)
            playback(position: t.position, start: region?.startTime ?? 0, end: region?.endTime ?? show.current?.duration ?? 0)
            let loop = Self.loopLabel(show)
            transport(paused: t.paused == true, recording: TrackRecording.shared.recording,
                looping: t.loop.enabled || (t.multiLoop?.gates == true && t.multiLoop?.released != true), auto: show.regionSetlist.autoAdvance,
                preview: TeleprompterWindow.shared.previewActive, playing: t.playing, queued: t.queuedRegionId != nil,
                loopName: loop.name, loopColor: loop.color)
        } else { remotePoll?() }
        flush()
    }
    static func loopLabel(_ show: ShowController) -> (name: String, color: UInt32) {
        let t = show.snapshot.transport, song = show.current
        let region = song?.sectionPlaybackRegion(for: t)
        let start = t.loop.enabled ? t.loop.start : t.multiLoop?.start
        let automatic = t.multiLoop.map { loop in song?.parts.contains { $0.id == loop.id && $0.totalLoop == true } == true } ?? false
        let marker = start.flatMap { position in song?.markers?.filter {
            $0.section == true && $0.position >= (region?.startTime ?? 0) && $0.position <= position + 0.000001
        }.max { $0.position < $1.position } }
        return (automatic ? region?.displayName ?? "" : marker?.name ?? region?.displayName ?? "",
                automatic ? region?.color ?? 0xffb347 : marker?.color ?? region?.color ?? 0xffb347)
    }
    private func actionFeedback(_ action: SMK37Action, show: ShowController) {
        let t = show.snapshot.transport
        switch action {
        case .padBusVolume:
            if let track = show.current?.tracks.first(where: { $0.role.rawValue == "vinhetas" }) {
                feedback(SMK37Protocol.padBusLabel(gain: track.volume))
            }
        case .playStop: feedback(t.playing ? "PLAY" : "STOP", color: t.playing ? 0x2ecc71 : 0xff4040)
        case .pause: if t.paused != true { feedback(t.playing ? "PLAY" : "STOP") }
        case .record: if !TrackRecording.shared.recording { feedback("REC DESATIVADO", color: 0xff4040) }
        case .auto: feedback(show.regionSetlist.autoAdvance ? "AUTO ATIVO" : "AUTO DESATIVADO", color: 0xe67e22)
        case .preview: feedback(TeleprompterWindow.shared.previewActive ? "PREVIEW ATIVADO" : "PREVIEW DESATIVADO", color: 0x55cfff)
        case .previewPage:
            let first = TeleprompterWindow.shared.previewPage * 4 + 1; feedback("BLOCO \(first)-\(first + 3)", color: 0x55cfff)
        case .songs: break // The list navigation publishes the actual visible order.
        case .repeatLoop: if !t.loop.enabled && t.multiLoop == nil { feedback("LOOP DESATIVADO") }
        case .scrollTracks(let direction): feedback(direction < 0 ? "TRACK MIXER ACIMA" : "TRACK MIXER ABAIXO")
        default: break
        }
    }
    private func queue(_ key: String, _ bytes: [UInt8], force: Bool = false) {
        guard session.connected, !bytes.isEmpty else { return }
        if force || sent[key] != bytes { pending[key] = bytes } else { pending[key] = nil }
    }
    private func flush() {
        guard session.connected else { return }
        let priority = ["action", "navigation", "transport", "fadeout", "playback", "loop", "selection"]
        let keys = priority.filter { pending[$0] != nil } + pending.keys.filter { !priority.contains($0) }.sorted()
        for key in keys.prefix(4) {
            guard let bytes = pending[key], write(bytes) else { return }
            sent[key] = bytes; pending[key] = nil
        }
    }
    private func write(_ bytes: [UInt8]) -> Bool {
        guard destination != 0, output != 0, !bytes.isEmpty else { return false }
        let size = MemoryLayout<MIDIPacketList>.size + bytes.count
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        let valid = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, size, packet, 0, bytes.count, $0.baseAddress!) != nil }
        return valid && MIDISend(output, destination, list) == noErr
    }
}
