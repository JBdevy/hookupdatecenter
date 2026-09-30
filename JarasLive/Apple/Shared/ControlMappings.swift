import SwiftUI
import Combine
import CoreMIDI
#if os(macOS)
import AppKit
#endif

struct MappedControl: Codable, Identifiable {
    var id = UUID()
    var project: UUID
    var track: UUID?
    var command: String
    var input: ControlInput
    var fxParameter: FXParameterMapping? = nil
}
struct MappingEdit: Identifiable {
    let id = UUID()
    let track: UUID?
    let command: String
    var action: DAWAction? = nil
    var fxParameter: FXParameterMapping? = nil
    var chooseInputKind = false
    var replacesTrackTarget = false
    var trackNumber: Int? = nil
}
struct MappingTransferRequest: Identifiable {
    let id = UUID()
    let editID: UUID
    let input: ControlInput
    let kind: String
    let message: String
}
@MainActor final class ControlMappings: ObservableObject {
    static let shared = ControlMappings()
    @Published private(set) var mappings: [MappedControl] = []
    @Published private(set) var actions = DAWActionBindings()
    @Published var editing: MappingEdit? {
        didSet { if transferRequest?.editID != editing?.id { transferRequest = nil } }
    }
    @Published private(set) var transferRequest: MappingTransferRequest?
    @Published var mode = "keyboard"
    @Published var candidate: ControlInput?
    @Published var error = ""
    private weak var show: ShowController?
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var sources: [MIDIEndpointRef: (id: Int32, name: String)] = [:]
    private var pressedMIDI: Set<String> = []
    private struct PendingControl { let project: UUID; let track: UUID?; let command: ShowCommand; let value: Double }
    private var pendingVolumes: [String: PendingControl] = [:]
    private var volumeFlushScheduled = false
    private var midiSelection: AnyCancellable?
    private var projectSelection: AnyCancellable?
    #if os(macOS)
    private var keyMonitor: Any?
    #endif
    private init() {
        if let data = UserDefaults.standard.data(forKey: "jaras.controlMappings"), let stored = try? JSONDecoder().decode([MappedControl].self, from: data) { mappings = stored }
        if let data = UserDefaults.standard.data(forKey: "jaras.actions"), let stored = try? JSONDecoder().decode([DAWActionBinding].self, from: data) { actions = DAWActionBindings(stored: stored) }
    }
    var current: [MappedControl] { mappings.filter { $0.project == show?.snapshot.project.id } }
    func bind(_ show: ShowController) {
        self.show = show
        migrateActionMappings()
        projectSelection = show.$snapshot.map { $0.project.id }.removeDuplicates().dropFirst().sink { [weak self] _ in
            // The published snapshot is assigned after its subscribers run.
            Task { @MainActor [weak self] in self?.migrateActionMappings() }
        }
        #if os(macOS)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) == true ? nil : event
            }
        }
        #endif
        if client == 0 {
            let result = MIDIClientCreateWithBlock("Jaras Live Controls" as CFString, &client) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSources() }
            }
            guard result == noErr else { error = "MIDI initialization failed (\(result))"; return }
            let resultPort = MIDIInputPortCreateWithProtocol(client, "Jaras Live Input" as CFString, ._1_0, &port) { [weak self] list, context in
                let endpoint = MIDIEndpointRef(UInt(bitPattern: context))
                var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
                var messages: [(UInt8, UInt8, UInt8)] = []
                for _ in 0..<list.pointee.numPackets {
                    let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                    var index = 0
                    while index < Int(packet.pointee.wordCount) {
                        let word = words[index], type = word >> 28
                        if type == 2 {
                            let status = UInt8((word >> 16) & 0xff), kind = status & 0xf0
                            if kind >= 0x80 && kind <= 0xe0 { messages.append((status, UInt8((word >> 8) & 0x7f), UInt8(word & 0x7f))) }
                        }
                        index += type == 3 || type == 4 ? 2 : type == 5 || type == 0xd || type == 0xf ? 4 : 1
                    }
                    packet = UnsafePointer(MIDIEventPacketNext(packet))
                }
                if !messages.isEmpty { Task { @MainActor [weak self] in for message in messages { self?.receive(endpoint: endpoint, status: message.0, number: message.1, value: message.2) } } }
            }
            if resultPort != noErr { error = "MIDI input failed (\(resultPort))" }
        }
        if midiSelection == nil {
            midiSelection = AudioDeviceSettings.shared.$midiSlots.dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in StemAudioPlayback.shared.releaseMIDINotes(); self?.pressedMIDI.removeAll(); self?.refreshSources() }
            }
        }
        refreshSources()
    }
    func refreshSources() {
        guard port != 0 else { return }
        let selected = Set(AudioDeviceSettings.shared.midiSlots.filter { $0 != 0 })
        let available = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { endpoint in
            var id: Int32 = 0, offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            return offline == 0 && selected.contains(id)
        })
        let disconnected = sources.keys.filter { !available.contains($0) }
        if !disconnected.isEmpty { StemAudioPlayback.shared.releaseMIDINotes(); pressedMIDI.removeAll() }
        for source in disconnected { MIDIPortDisconnectSource(port, source); sources.removeValue(forKey: source) }
        for source in available where sources[source] == nil {
            var id: Int32 = 0; var name: Unmanaged<CFString>?
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            let result = MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: Int(source)))
            if result == noErr { sources[source] = (id, name?.takeRetainedValue() as String? ?? "MIDI") }
        }
    }
    func title(track: UUID?, command: String) -> String {
        if command == "tempoUp" { return "BPM +" }
        if command == "tempoDown" { return "BPM −" }
        let name = track.flatMap { id in show?.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == id })?.name } ?? JarasLocalization.string(track == nil ? "Master" : "Track unavailable")
        return name + " · " + JarasLocalization.string(command == "volume" ? "Volume" : command == "mute" ? "Mute" : "Solo")
    }
    func beginFX(track: UUID?, parameter: FXParameterMapping) {
        mode = "midi"; error = ""
        candidate = current.first { $0.track == track && $0.fxParameter?.sameControl(as: parameter) == true }?.input
        editing = MappingEdit(track: track, command: "fxParameter", fxParameter: parameter)
    }
    func beginAction(_ action: DAWAction, kind: String) {
        guard kind != "midi" || action.supportsMIDI else { return }
        guard kind != "keyboard" || (!action.fixedKeyboard && !action.continuous) else { return }
        mode = kind; error = ""
        let binding = actions.binding(action)
        candidate = kind == "keyboard" ? binding.keyboard : binding.midi
        editing = MappingEdit(track: nil, command: action.rawValue, action: action)
    }
    func setActionTrack(_ action: DAWAction, number: Int?) {
        actions.setTrack(number, action: action); persistActions()
    }
    func removeActionInput(_ action: DAWAction, kind: String) {
        actions.setInput(nil, action: action, kind: kind); persistActions()
    }
    func resetAction(_ action: DAWAction, kind: String? = nil) {
        if kind != "midi", let input = action.defaultKeyboard, let conflict = actions.conflict(input, excluding: action) {
            error = JarasLocalization.string(conflict.title) + " — " + JarasLocalization.string("This control is already mapped."); return
        }
        actions.reset(action, kind: kind); error = ""; persistActions()
    }
    private func persistActions() {
        if let data = try? JSONEncoder().encode(actions.entries) { UserDefaults.standard.set(data, forKey: "jaras.actions") }
    }
    var learningContinuous: Bool { editing?.fxParameter != nil || editing?.action?.continuous == true || editing?.command == "volume" }
    func editTitle(_ edit: MappingEdit) -> String {
        if let fx = edit.fxParameter { return fx.parameter.effect + " · " + JarasLocalization.string(fx.parameter.name) }
        guard let action = edit.action else { return title(track: edit.track, command: edit.command) }
        let title = JarasLocalization.string(action.title)
        if edit.replacesTrackTarget, let number = edit.trackNumber, let track = show?.actionTrack(number: number) {
            return title + " · " + track.name
        }
        return title
    }
    func shortcutHelp(_ action: DAWAction) -> String {
        let label = actions.binding(action).keyboard?.label
        return JarasLocalization.string(action.title) + (label.map { " (" + $0 + ")" } ?? "")
    }
    func begin(track: UUID?, command: String) {
        if let action = DAWAction.quickMapping(command: command, master: track == nil) {
            guard let show else { return }
            migrateActionMappings()
            let number = track.flatMap { id in show.current?.tracks.firstIndex(where: { $0.id == id }).map { $0 + 1 } }
            guard !action.needsTrack || number != nil else { return }
            if action.continuous { mode = "midi" }
            error = ""
            let binding = actions.binding(action)
            candidate = mode == "keyboard" ? binding.keyboard : binding.midi
            editing = MappingEdit(track: track, command: command, action: action, chooseInputKind: !action.continuous, replacesTrackTarget: action.needsTrack, trackNumber: number)
            return
        }
        error = ""; candidate = nil
        if command == "volume" { mode = "midi" }
        if let existing = current.first(where: { $0.track == track && $0.command == command }) { candidate = existing.input; mode = existing.input.kind }
        editing = MappingEdit(track: track, command: command)
    }
    func save(replacingConflicts: Bool = false) {
        guard let editing, let candidate, let show, candidate.kind == mode else { return }
        if learningContinuous && (candidate.kind != "midi" || candidate.status != 0xb0) { return }
        let actionConflicts = actions.entries.filter { $0.action != editing.action && $0.matches(candidate) }
        let controlConflicts = current.filter { entry in
            entry.input.matches(candidate) && (editing.action != nil || entry.track != editing.track || entry.command != editing.command ||
                (entry.fxParameter?.sameControl(as: editing.fxParameter) ?? (editing.fxParameter == nil)) == false)
        }
        if mode == "keyboard", actionConflicts.contains(where: { $0.action.fixedKeyboard }) {
            error = JarasLocalization.string("The arrow keys are fixed to setlist navigation."); return
        }
        if !replacingConflicts && (!actionConflicts.isEmpty || !controlConflicts.isEmpty) {
            let titles = actionConflicts.map { JarasLocalization.string($0.action.title) } + controlConflicts.map {
                $0.fxParameter.map { $0.parameter.effect + " · " + JarasLocalization.string($0.parameter.name) } ?? title(track: $0.track, command: $0.command)
            }
            error = titles.joined(separator: ", ") + " — " + JarasLocalization.string("This control is already mapped.")
            transferRequest = MappingTransferRequest(editID: editing.id, input: candidate, kind: mode,
                message: String(format: JarasLocalization.string("%@ is already mapped to %@. Remove it from that function and use it for %@?"), candidate.label, titles.joined(separator: ", "), editTitle(editing)))
            return
        }
        var nextActions = actions
        if let action = editing.action {
            let accepted = replacingConflicts ? nextActions.transferInput(candidate, action: action, kind: mode) : nextActions.setInput(candidate, action: action, kind: mode)
            guard accepted else { return }
            if editing.replacesTrackTarget { nextActions.setTrack(editing.trackNumber, action: action) }
        } else {
            for conflict in actionConflicts { nextActions.setInput(nil, action: conflict.action, kind: mode) }
        }
        let conflictingIDs = Set(controlConflicts.map(\.id))
        var nextControls = mappings.filter { !conflictingIDs.contains($0.id) }
        if editing.action == nil {
            nextControls.removeAll { $0.project == show.snapshot.project.id && $0.track == editing.track && $0.command == editing.command && ($0.fxParameter?.sameControl(as: editing.fxParameter) ?? (editing.fxParameter == nil)) }
            nextControls.append(MappedControl(project: show.snapshot.project.id, track: editing.track, command: editing.command, input: candidate, fxParameter: editing.fxParameter))
        }
        actions = nextActions; mappings = nextControls
        persistActions(); persist(); error = ""; transferRequest = nil; self.editing = nil
    }
    func confirmTransfer(_ selectedRequest: MappingTransferRequest? = nil) {
        guard let request = selectedRequest ?? transferRequest, request.editID == editing?.id,
              request.kind == mode, candidate?.matches(request.input) == true else { transferRequest = nil; return }
        transferRequest = nil
        save(replacingConflicts: true)
    }
    func cancelTransfer() { transferRequest = nil }
    func remove(_ id: UUID) { mappings.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(mappings) { UserDefaults.standard.set(data, forKey: "jaras.controlMappings") } }
    private func migrateActionMappings() {
        guard let show else { return }
        var converted = Set<UUID>()
        for entry in mappings.reversed() where entry.fxParameter == nil {
            guard let action = DAWAction.quickMapping(command: entry.command, master: entry.track == nil) else { continue }
            let number = entry.track.flatMap { id in show.current?.tracks.firstIndex(where: { $0.id == id }).map { $0 + 1 } }
            guard !action.needsTrack || (entry.project == show.snapshot.project.id && number != nil) else { continue }
            let binding = actions.binding(action)
            let existing = entry.input.kind == "keyboard" ? binding.keyboard : binding.midi
            if existing == nil || existing == action.defaultKeyboard {
                guard (!action.continuous || (entry.input.kind == "midi" && entry.input.status == 0xb0)),
                      actions.conflict(entry.input, excluding: action) == nil else { continue }
                actions.setInput(entry.input, action: action, kind: entry.input.kind)
                if action.needsTrack { actions.setTrack(number, action: action) }
            }
            converted.insert(entry.id)
        }
        if !converted.isEmpty {
            mappings.removeAll { converted.contains($0.id) }
            persistActions(); persist()
        }
    }
    private func execute(_ input: ControlInput) {
        guard let show else { return }
        if let entry = current.first(where: { $0.input.matches(input) }) {
            if entry.command == "tempoUp" || entry.command == "tempoDown" { show.adjustTempo(entry.command == "tempoUp" ? 1 : -1); return }
            if let action = ShowCommand(rawValue: entry.command), [.mute, .solo].contains(action) { show.send(action, target: entry.track) }
            return
        }
        if let action = actions.matching(input) {
            show.performAction(action, trackNumber: actions.binding(action).trackNumber)
        }
    }
    private func continuous(track: UUID?, command: ShowCommand, value: Double, id: String) {
        guard let show else { return }
        if command == .volume { show.previewTrackVolume(track, gain: value) }
        else if let track { show.previewTrackPan(track, pan: value) }
        pendingVolumes[id] = PendingControl(project: show.snapshot.project.id, track: track, command: command, value: value)
        guard !volumeFlushScheduled else { return }
        volumeFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self else { return }
            let updates = self.pendingVolumes
            self.pendingVolumes.removeAll(keepingCapacity: true); self.volumeFlushScheduled = false
            for update in updates.values where update.project == self.show?.snapshot.project.id {
                self.show?.send(update.command, target: update.track, value: update.value)
            }
        }
    }
    private var pendingFX: [UUID: (MappedControl, UInt8)] = [:]
    private var fxFlushScheduled = false
    private var fxCommitGeneration: UInt64 = 0
    private func receiveFX(_ entry: MappedControl, value: UInt8) {
        pendingFX[entry.id] = (entry, value)
        guard !fxFlushScheduled else { return }
        fxFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            guard let self, let show = self.show else { return }
            let updates = self.pendingFX.values; self.pendingFX.removeAll(keepingCapacity: true); self.fxFlushScheduled = false
            for (entry, value) in updates where entry.project == show.snapshot.project.id {
                guard let fx = entry.fxParameter else { continue }
                if let clip = fx.clip {
                    guard FXModelLookup.clip(clip, in: show.snapshot.project) != nil else { continue }
                    var settings = show.clipFXSettings(clip)
                    if fx.parameter.apply(value, to: &settings) { show.previewClipFX(clip, settings: settings) }
                } else {
                    guard entry.track == nil || entry.track.map({ FXModelLookup.track($0, in: show.snapshot.project) != nil }) == true else { continue }
                    var settings = show.fxSettings(entry.track)
                    if settings.instrumentID != nil && settings.instrumentParameters == nil { settings.instrumentParameters = InstrumentLibrary.parameters(settings.instrumentID) }
                    if fx.parameter.apply(value, to: &settings) { show.previewFX(entry.track, settings: settings) }
                }
            }
            self.fxCommitGeneration &+= 1
            let generation = self.fxCommitGeneration, project = show.snapshot.project.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.fxCommitGeneration == generation, self.show?.snapshot.project.id == project else { return }
                self.show?.commitFX()
            }
        }
    }
    private func receive(endpoint: MIDIEndpointRef, status: UInt8, number: UInt8, value: UInt8) {
        guard transferRequest == nil, let source = sources[endpoint] else { return }
        KeyboardMIDIMonitor.shared.receive(source: source.id, status: status, number: number, value: value)
        let kind: UInt8 = status & 0xf0 == 0xb0 ? 0xb0 : 0x90
        let channel = status & 0x0f
        let input = ControlInput(kind: "midi", label: "\(source.name) · CH \(channel + 1) · \(kind == 0xb0 ? "CC" : "Note") \(number)", device: source.id, channel: channel, status: kind, number: number)
        // Continuous controls include zero and repeated nonzero values. They must
        // not pass through the press/release latch used for Mute and Solo.
        if learningContinuous {
            if status & 0xf0 == 0xb0 { candidate = input; error = "" }
            return
        }
        if editing == nil, status & 0xf0 == 0xb0,
           let entry = current.first(where: { $0.fxParameter != nil && $0.input.matches(input) }) {
            receiveFX(entry, value: value); return
        }
        if editing == nil, status & 0xf0 == 0xb0,
           let entry = current.first(where: { $0.command == "volume" && $0.input.matches(input) }) {
            continuous(track: entry.track, command: .volume, value: MIDIFaderValue.gain(value), id: entry.id.uuidString)
            return
        }
        if editing == nil, status & 0xf0 == 0xb0,
           let action = actions.matching(input), action.continuous {
            let track = action == .volumeMaster ? nil : show?.actionTrack(number: actions.binding(action).trackNumber)?.id
            guard action == .volumeMaster || track != nil else { return }
            continuous(track: track, command: action == .panTrack ? .pan : .volume,
                       value: action == .panTrack ? DAWActionValue.pan(value) : MIDIFaderValue.gain(value), id: action.rawValue)
            return
        }
        if editing == nil { StemAudioPlayback.shared.receiveMIDI(device: source.id,status: status,number: number,value: value) }
        guard [0xb0,0x90,0x80].contains(status & 0xf0) else { return }
        let key = "\(source.id):\(kind):\(channel):\(number)"
        let down = status & 0xf0 != 0x80 && value > 0
        if !down { pressedMIDI.remove(key); return }
        guard pressedMIDI.insert(key).inserted else { return }
        if editing != nil { if mode == "midi" { candidate = input; error = "" }; return }
        execute(input)
    }
    #if os(macOS)
    func handleKey(_ event: NSEvent) -> Bool {
        guard NSApp.isActive, transferRequest == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if editing != nil {
            if event.keyCode == 53 { editing = nil; return true }
            // Enter confirms both keyboard and MIDI learning.
            if [36, 76].contains(event.keyCode) { if candidate != nil { save() }; return true }
            guard mode == "keyboard" else { return true }
            // Keep application shortcuts available.
            if flags.contains(.command) && [12, 13, 1].contains(event.keyCode) { return true }
            if !event.isARepeat {
                let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                let special: [UInt16: String] = [49:"Space", 48:"Tab", 123:"←", 124:"→", 125:"↓", 126:"↑", 51:"Delete", 122:"F1", 120:"F2"]
                candidate = ControlInput(kind: "keyboard", label: prefix + (special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"), key: event.keyCode, modifiers: flags.rawValue)
                error = ""
            }
            return true
        }
        // Sheet key events belong to the sheet itself, whose attachedSheet is
        // nil. Let its default/cancel buttons receive Enter/Escape instead of
        // dispatching transport shortcuts (Enter normally starts Sub Play).
        guard NSApp.modalWindow == nil, event.window?.sheetParent == nil,
              event.window?.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(event.window),
              !(event.window?.firstResponder is NSTextView), !(event.window?.firstResponder is NSTextField) else { return false }
        if [125, 126].contains(event.keyCode), flags.isEmpty { return false }
        let input = ControlInput(kind: "keyboard", label: "", key: event.keyCode, modifiers: flags.rawValue)
        let mappedAction = actions.matching(input)
        guard current.contains(where: { $0.input.matches(input) }) || mappedAction != nil else { return false }
        if !event.isARepeat || mappedAction?.repeats == true { execute(input) }
        return true
    }
    #endif
}

struct ControlMappingEditor: View {
    @ObservedObject var mappings = ControlMappings.shared
    var body: some View {
        if let edit = mappings.editing {
            VStack(alignment: .leading, spacing: 16) {
                Text("Map control").font(.headline)
                Text(mappings.editTitle(edit))
                if !mappings.learningContinuous && (edit.action == nil || edit.chooseInputKind) {
                Picker("Input", selection: $mappings.mode) { Text("Keyboard").tag("keyboard"); Text("MIDI").tag("midi") }.pickerStyle(.segmented)
                    .onChange(of: mappings.mode) { kind in
                        if let action = edit.action {
                            let binding = mappings.actions.binding(action)
                            mappings.candidate = kind == "keyboard" ? binding.keyboard : binding.midi
                        } else { mappings.candidate = nil }
                        mappings.error = ""
                    }
                }
                Text(LocalizedStringKey(mappings.learningContinuous ? "Move a MIDI fader or knob." : mappings.mode == "keyboard" ? "Press a key or key combination." : "Press a MIDI note or controller button.")).font(.caption).foregroundStyle(JarasTheme.secondary)
                Text(mappings.candidate?.label ?? "—").font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, minHeight: 36).background(JarasTheme.display).cornerRadius(6)
                if mappings.mode == "keyboard" {
                    Button("Use Enter") { mappings.candidate = ControlInput(kind: "keyboard", label: "Enter", key: 36, modifiers: 0) }
                }
                if !mappings.error.isEmpty { Text(LocalizedStringKey(mappings.error)).foregroundStyle(.red).font(.caption) }
                HStack { Button("Cancel") { mappings.editing = nil }; Spacer(); Button("Save") { mappings.save() }.disabled(mappings.candidate == nil) }
            }.padding(22).frame(width: 360).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 10)).shadow(radius: 16)
                .alert("This control is already mapped.", isPresented: Binding(get: { mappings.transferRequest != nil }, set: { if !$0 { mappings.cancelTransfer() } }), presenting: mappings.transferRequest) { request in
                    Button("Cancel", role: .cancel) { mappings.cancelTransfer() }
                    Button("Transfer mapping") { mappings.confirmTransfer(request) }.keyboardShortcut(.defaultAction)
                } message: { request in
                    Text(verbatim: request.message)
                }
        }
    }
}
struct ControlMappingsList: View {
    @ObservedObject private var mappings = ControlMappings.shared
    var body: some View {
        if mappings.current.isEmpty { Text("No mappings yet.").foregroundStyle(JarasTheme.secondary) }
        ForEach(mappings.current) { item in
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.fxParameter.map { $0.parameter.effect + " · " + JarasLocalization.string($0.parameter.name) } ?? mappings.title(track: item.track, command: item.command)).font(.headline)
                    Text(item.input.label).font(.caption).foregroundStyle(JarasTheme.secondary)
                }
                Spacer()
                Button("Edit") { if let parameter = item.fxParameter { mappings.beginFX(track: item.track, parameter: parameter) } else { mappings.begin(track: item.track, command: item.command) } }
                Button { mappings.remove(item.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove mapping")
            }.padding(10).background(JarasTheme.panel).cornerRadius(6)
        }
    }
}
struct MappingRightClick: ViewModifier {
    let track: UUID?
    let command: String
    var hitHeight: CGFloat? = nil
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(MappingClickAnchor(hitHeight: hitHeight) { ControlMappings.shared.begin(track: track, command: command) })
        #else
        content.contextMenu { Button("Map control") { ControlMappings.shared.begin(track: track, command: command) } }
        #endif
    }
}
#if os(macOS)
private struct MappingClickAnchor: NSViewRepresentable {
    var hitHeight: CGFloat? = nil
    let action: () -> Void
    func makeNSView(context: Context) -> MappingClickView { MappingClickView() }
    func updateNSView(_ view: MappingClickView, context: Context) { view.action = action; view.hitHeight = hitHeight }
}
private final class MappingClickView: RightClickTargetView {
    var hitHeight: CGFloat?
    override var clickBounds: NSRect {
        guard let hitHeight else { return bounds }
        let height = min(bounds.height, hitHeight)
        return NSRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }
    override var priority: Int { 100 }
}

#endif

private struct ImmediateRightClick: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(MappingClickAnchor(action: action))
        #else
        content.onLongPressGesture(perform: action)
        #endif
    }
}
extension View {
    func immediateRightClick(_ action: @escaping () -> Void) -> some View { modifier(ImmediateRightClick(action: action)) }
}
