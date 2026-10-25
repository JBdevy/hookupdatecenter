import SwiftUI
import CoreMIDI
let mappingTestApplicationActive = true
@MainActor enum RegionShortcutView {
    static var editingEnvelope = false
    static func envelopeOwnsEditingKey(_ event: NSEvent) -> Bool { editingEnvelope && [51, 117, 53].contains(event.keyCode) }
    static func handleSelectedObjectsDelete(_ event: NSEvent) -> Bool { false }
}

// Only the external devices and project are replaced. The test compiles the
// production MIDI learner, conflict detection, latch and continuous routing.
enum ShowCommand: String { case mute, solo, volume, pan }
enum Project { static let maximumTrackCount = 1000 }
struct MappingTestTrack { let id: UUID; let name: String }
struct MappingTestSong { var tracks: [MappingTestTrack] = [] }
struct MappingTestProject { var id = UUID(); var songs: [MappingTestSong] = [] }
struct MappingTestSnapshot { var project = MappingTestProject() }
@MainActor final class ShowController: ObservableObject {
    @Published var snapshot = MappingTestSnapshot()
    var commands: [(ShowCommand, UUID?, Double)] = []
    var previews: [(UUID?, Double)] = []
    var nativeFX = NativeFXSettings()
    func fxSettings(_ track: UUID?) -> NativeFXSettings { nativeFX }
    func clipFXSettings(_ clip: UUID) -> NativeFXSettings { nativeFX }
    func previewFX(_ track: UUID?, settings: NativeFXSettings) { nativeFX = settings }
    func previewClipFX(_ clip: UUID, settings: NativeFXSettings) { nativeFX = settings }
    func commitFX() {}
    var bpm = 120.0
    var actionsReceived: [DAWAction] = []
    var focusedBlocks: [Int] = []
    func focusSetlistBlock(number: Int) -> Bool { focusedBlocks.append(number); return true }
    var current: MappingTestSong? { snapshot.project.songs.first }
    func actionTrack(number: Int?) -> MappingTestTrack? {
        guard let tracks = current?.tracks else { return nil }
        guard let number else { return tracks.first }
        return tracks.indices.contains(number - 1) ? tracks[number - 1] : nil
    }
    func performAction(_ action: DAWAction, trackNumber: Int?) {
        actionsReceived.append(action)
        switch action {
        case .muteTrack: if let track = actionTrack(number: trackNumber) { send(.mute, target: track.id) }
        case .soloTrack: if let track = actionTrack(number: trackNumber) { send(.solo, target: track.id) }
        case .muteMaster: send(.mute, target: nil)
        case .tempoUp: adjustTempo(1)
        case .tempoDown: adjustTempo(-1)
        default: break
        }
    }
    func previewTrackPan(_ track: UUID, pan: Double) { previews.append((track, pan)) }
    func adjustTempo(_ delta: Double) { bpm += delta }
    func send(_ command: ShowCommand, target: UUID?, value: Double = 0) { commands.append((command, target, value)) }
    func previewTrackVolume(_ track: UUID?, gain: Double) { previews.append((track, gain)) }
}
@MainActor final class AudioDeviceSettings: ObservableObject {
    static let shared = AudioDeviceSettings()
    @Published var midiSlots: [Int32] = []
}
@MainActor final class StemAudioPlayback {
    static let shared = StemAudioPlayback()
    var forwarded = 0
    func releaseMIDINotes() {}
    func receiveMIDI(device: Int32, status: UInt8, number: UInt8, value: UInt8) { forwarded += 1 }
}
@MainActor final class VinhetasController {
    static let shared = VinhetasController()
    var claimedNumber: UInt8?
    var received: [(ControlInput, UInt8)] = []
    var library = VinhetasLibrary()
    var persistedLibrary: Data?
    func update(_ edit: (inout VinhetasLibrary) -> Void) {
        edit(&library); try! library.validate(); persistedLibrary = try! JSONEncoder().encode(library)
    }
    // INSERT_VINHETAS_BLOCK_CONFLICTS
    func receive(input: ControlInput, value: UInt8) -> Bool {
        received.append((input, value))
        return (claimedNumber != nil && input.number == claimedNumber) || library.handles(input)
    }
}
@MainActor final class KeyboardMIDIMonitor {
    static let shared = KeyboardMIDIMonitor()
    func receive(source: Int32, status: UInt8, number: UInt8, value: UInt8) {}
}

struct FXParameterMapping: Codable, Equatable {
    var clip: UUID?; var parameter: NativeFXParameter
    func sameControl(as other: FXParameterMapping?) -> Bool {
        guard let other else { return false }
        return clip == other.clip && parameter.effect == other.parameter.effect && parameter.key == other.parameter.key && parameter.band == other.parameter.band
    }
}
enum ProjectError: Error { case invalid(String) }
@MainActor enum FXModelLookup {
    static func track(_ id: UUID, in project: MappingTestProject) -> MappingTestTrack? { project.songs.flatMap(\.tracks).first { $0.id == id } }
    static func clip(_ id: UUID, in project: MappingTestProject) -> UUID? { id }
}
@MainActor enum InstrumentLibrary { static func parameters(_ id: String?) -> InstrumentParameters { InstrumentParameters() } }
@main struct MIDIMappingTests {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jaras.controlMappings")
        defaults.removeObject(forKey: "jaras.actions")
        defer { defaults.removeObject(forKey: "jaras.controlMappings"); defaults.removeObject(forKey: "jaras.actions") }
        let show = ShowController()
        let track = UUID()
        let legacy = [MappedControl(project: show.snapshot.project.id, track: track, command: "mute", input: ControlInput(kind: "midi", label: "CC 91", device: 123, channel: 0, status: 0xb0, number: 91)),
                      MappedControl(project: UUID(), track: nil, command: "mute", input: ControlInput(kind: "midi", label: "CC 90", device: 123, channel: 0, status: 0xb0, number: 90))]
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "jaras.controlMappings")
        var oldSubPlay = DAWActionBinding(action: .subPlayStop)
        oldSubPlay.keyboard = ControlInput(kind: "keyboard", label: "Enter", key: 36, modifiers: 0)
        defaults.set(try! JSONEncoder().encode([oldSubPlay]), forKey: "jaras.actions")
        let mappings = ControlMappings.shared
        precondition(mappings.actions.binding(.subPlayStop).keyboard == DAWAction.subPlayStop.defaultKeyboard, "stored Enter defaults migrate to Shift+Space at startup")
        show.snapshot.project.songs = [MappingTestSong(tracks: [MappingTestTrack(id: track, name: "Piano")])]
        mappings.show = show
        mappings.migrateActionMappings()
        precondition(mappings.mappings.isEmpty && mappings.actions.binding(.muteTrack).trackNumber == 1)
        precondition(mappings.actions.binding(.muteMaster).midi?.number == 90, "legacy master mappings migrate without a project dependency")
        mappings.sources[100] = (123, "Test MIDI")
        var recorded: [(Int32, UInt8, UInt8, UInt8, Double)] = []
        mappings.onMIDIReceived = { recorded.append(($0, $1, $2, $3, $4)) }
        mappings.receive(endpoint: 100, status: 0x95, number: 60, value: 100, timestamp: 10.125)
        mappings.receive(endpoint: 100, status: 0x85, number: 60, value: 0, timestamp: 10.875)
        precondition(recorded.count == 2 && recorded.allSatisfy { $0.0 == 123 })
        precondition(recorded.map { $0.1 } == [0x95, 0x85] && recorded.map { $0.4 } == [10.125, 10.875], "capture preserves source, channel, note-off and original CoreMIDI time")
        StemAudioPlayback.shared.forwarded = 0
        func cc(_ number: UInt8, _ value: UInt8, channel: UInt8 = 0) {
            mappings.receive(endpoint: 100, status: 0xb0 | channel, number: number, value: value)
        }
        mappings.begin(track: track, command: "volume")
        precondition(mappings.mode == "midi")
        mappings.receive(endpoint: 100, status: 0x90, number: 60, value: 100)
        precondition(mappings.candidate == nil, "A note cannot be learned as a fader")
        precondition(recorded.count == 2, "learning a mapping does not record MIDI notes")
        cc(7, 0)
        precondition(mappings.candidate?.number == 7, "CC zero can teach the fader")
        mappings.save()
        precondition(mappings.title(track: track, command: "volume") == "Piano · Volume")
        for value: UInt8 in [32, 64, 127, 0] { cc(7, value) }
        precondition(show.previews.count == 4 && show.previews.last?.1 == 0)
        precondition(abs(show.previews[2].1 - pow(10, 12.0 / 20)) < 0.000001)
        precondition(StemAudioPlayback.shared.forwarded == 0, "Mapped CC must not also alter the instrument")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.commands.count == 1 && show.commands[0].0 == .volume && show.commands[0].1 == track && show.commands[0].2 == 0, "UI coalesces to the last CC")
        cc(7, 100, channel: 1)
        precondition(show.previews.count == 4, "Different channels do not match")

        mappings.begin(track: nil, command: "volume")
        cc(7, 100); mappings.save()
        precondition(mappings.editing != nil && mappings.transferRequest != nil, "A shared CC requires confirmation")
        precondition(mappings.actions.binding(.volumeTrack).midi?.number == 7, "the old mapping remains until confirmation")
        mappings.cancelTransfer()
        cc(11, 10); mappings.save()
        cc(11, 127)
        precondition(show.previews.last?.0 == nil, "Master fader has no track target")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.commands.last?.1 == nil && show.commands.last?.0 == .volume)

        mappings.begin(track: track, command: "mute")
        mappings.mode = "midi"; cc(20, 127); mappings.save()
        cc(20, 0); cc(20, 127); cc(20, 80); cc(20, 0); cc(20, 127)
        precondition(show.commands.filter { $0.0 == .mute }.count == 2, "Mute still triggers only once per press")
        mappings.begin(track: nil, command: "tempoUp")
        mappings.mode = "midi"; cc(21, 127); mappings.save()
        cc(21, 0); cc(21, 127); cc(21, 70)
        precondition(show.bpm == 121, "BPM plus triggers once per press")
        mappings.begin(track: nil, command: "tempoDown")
        mappings.mode = "midi"; cc(22, 127); mappings.save()
        cc(22, 0); cc(22, 127)
        precondition(show.bpm == 120, "BPM minus is mapped independently")
        let stored = defaults.data(forKey: "jaras.controlMappings")!
        let decoded = try! JSONDecoder().decode([MappedControl].self, from: stored)
        precondition(decoded.filter { $0.command == "volume" }.isEmpty, "quick mappings have no duplicate per-project store")
        precondition(mappings.actions.binding(.volumeTrack).midi?.number == 7 && mappings.actions.binding(.volumeTrack).trackNumber == 1)
        precondition(mappings.actions.binding(.volumeMaster).midi?.number == 11)
        mappings.beginAction(.panTrack, kind: "midi")
        mappings.receive(endpoint: 100, status: 0x90, number: 61, value: 100)
        precondition(mappings.candidate == nil)
        cc(10, 0); mappings.save()
        cc(10, 0); cc(10, 64); cc(10, 127)
        precondition(show.previews.suffix(3).map { $0.1 } == [-1, 0, 1])
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.commands.last?.0 == .pan && show.commands.last?.2 == 1)
        for (action, controller) in [(DAWAction.toggleAuto, UInt8(30)), (.setlistUp, 31), (.setlistDown, 32), (.toggleTracks, 75), (.toggleSetlist, 76)] {
            mappings.beginAction(action, kind: "midi"); cc(controller, 127); mappings.save()
            cc(controller, 0); cc(controller, 127); cc(controller, 80)
            precondition(show.actionsReceived.last == action)
        }
        precondition(Array(show.actionsReceived.suffix(5)) == [.toggleAuto, .setlistUp, .setlistDown, .toggleTracks, .toggleSetlist])
        let other = ShowController(), otherTrack = UUID()
        other.snapshot.project.songs = [MappingTestSong(tracks: [MappingTestTrack(id: otherTrack, name: "Other piano")])]
        mappings.show = other
        cc(7, 64)
        precondition(other.previews.last?.0 == otherTrack, "the same global fader action resolves the track in a different project")
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(other.commands.last?.1 == otherTrack)
        cc(20, 0); cc(20, 127)
        precondition(other.commands.last?.0 == .mute && other.commands.last?.1 == otherTrack)
        mappings.begin(track: otherTrack, command: "mute")
        precondition(mappings.editing?.action == .muteTrack && mappings.editing?.chooseInputKind == true)
        mappings.mode = "keyboard"
        let shortcut = ControlInput(kind: "keyboard", label: "F", key: 3, modifiers: 0)
        mappings.candidate = shortcut; mappings.save()
        precondition(mappings.actions.binding(.muteTrack).keyboard == shortcut && mappings.actions.binding(.muteTrack).midi?.number == 20)
        mappings.beginAction(.muteTrack, kind: "keyboard")
        precondition(mappings.candidate == shortcut, "Actions reads the shortcut saved through the quick editor")
        mappings.editing = nil
        mappings.execute(shortcut)
        precondition(other.commands.last?.0 == .mute && other.commands.last?.1 == otherTrack)
        mappings.begin(track: otherTrack, command: "volume")
        precondition(mappings.candidate?.number == 7 && mappings.editing?.action == .volumeTrack)
        mappings.editing = nil
        mappings.beginAction(.volumeTrack, kind: "midi")
        cc(12, 0); mappings.save()
        mappings.begin(track: otherTrack, command: "volume")
        precondition(mappings.candidate?.number == 12, "the quick editor reads the same action after remapping in Actions")
        mappings.editing = nil
        let extraTrack = UUID(), beforeCancel = mappings.actions
        other.snapshot.project.songs[0].tracks.append(MappingTestTrack(id: extraTrack, name: "Second piano"))
        mappings.begin(track: extraTrack, command: "volume")
        precondition(mappings.editing?.trackNumber == 2 && mappings.actions == beforeCancel, "opening quick mapping cannot change the global track target")
        mappings.editing = nil
        precondition(mappings.actions == beforeCancel, "cancelling the quick editor preserves the entire global binding")
        cc(90, 0); cc(90, 127)
        precondition(other.commands.last?.0 == .mute && other.commands.last?.1 == nil)
        cc(11, 64)
        precondition(other.previews.last?.0 == nil, "Master volume remains a separate global MIDI action")
        try? await Task.sleep(nanoseconds: 40_000_000)
        mappings.show = show
        print("QUICK_AND_ACTIONS_SHARE_GLOBAL_KEYBOARD_MIDI_TRACK_MASTER_AND_LEGACY_MIGRATION_OK")
        let actions = try! JSONDecoder().decode([DAWActionBinding].self, from: defaults.data(forKey: "jaras.actions")!)
        precondition(actions.first { $0.action == .setlistUp }?.keyboard == DAWAction.setlistUp.defaultKeyboard)
        show.nativeFX.inserted = ["Compressor"]
        let parameter = FXParameterMapping(parameter: NativeFXParameter(effect: "Compressor", key: .threshold, name: "Threshold", range: -60...0))
        mappings.beginFX(track: track, parameter: parameter)
        precondition(mappings.learningContinuous && mappings.mode == "midi")
        cc(40, 0); mappings.save()
        cc(40, 10); cc(40, 100); cc(40, 127)
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.nativeFX.threshold == 0, "native parameter coalesces continuous CC and accepts its upper endpoint")
        cc(40, 0)
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.nativeFX.threshold == -60, "CC zero reaches the native parameter's lower endpoint")
        let savedControls = try! JSONDecoder().decode([MappedControl].self, from: defaults.data(forKey: "jaras.controlMappings")!)
        precondition(savedControls.first { $0.command == "fxParameter" }?.fxParameter == parameter)
        print("NATIVE_FX_MIDI_PARAMETER_CC_ZERO_COALESCING_TARGET_AND_PERSISTENCE_OK")
        print("MIDI_FADER_TRACK_MASTER_ZERO_CONTINUOUS_CONFLICT_PERSISTENCE_OK")
        print("MIDI_ACTIONS_AUTO_SETLIST_NAVIGATION_PAN_ZERO_CENTER_FULL_RANGE_OK")
        let oldBindings = mappings.actions
        mappings.beginAction(.previousRegion, kind: "keyboard")
        mappings.candidate = DAWAction.nextRegion.defaultKeyboard
        mappings.save()
        precondition(mappings.transferRequest != nil && mappings.actions == oldBindings)
        mappings.cancelTransfer()
        precondition(mappings.actions == oldBindings, "cancelling keeps both directions intact")
        mappings.save(); mappings.confirmTransfer()
        precondition(mappings.actions.binding(.nextRegion).keyboard == nil)
        precondition(mappings.actions.binding(.previousRegion).keyboard == DAWAction.nextRegion.defaultKeyboard)
        precondition(mappings.actions.matching(DAWAction.nextRegion.defaultKeyboard!) == .previousRegion)
        let cc30 = mappings.actions.binding(.toggleAuto).midi!
        mappings.beginAction(.nextTimelinePoint, kind: "midi")
        mappings.candidate = cc30; mappings.save()
        precondition(mappings.actions.binding(.toggleAuto).midi == cc30 && mappings.transferRequest != nil)
        let request = mappings.transferRequest!
        mappings.cancelTransfer() // SwiftUI may dismiss the alert before invoking its button.
        mappings.confirmTransfer(request)
        precondition(mappings.actions.binding(.toggleAuto).midi == nil)
        precondition(mappings.actions.binding(.nextTimelinePoint).midi == cc30)
        let transferred = try! JSONDecoder().decode([DAWActionBinding].self, from: defaults.data(forKey: "jaras.actions")!)
        precondition(transferred.first { $0.action == .toggleAuto }?.midi == nil)
        precondition(transferred.first { $0.action == .nextTimelinePoint }?.midi == cc30)
        mappings.beginAction(.projectStart, kind: "keyboard")
        mappings.candidate = DAWAction.setlistUp.defaultKeyboard; mappings.save()
        precondition(mappings.transferRequest == nil && mappings.actions.binding(.setlistUp).keyboard == DAWAction.setlistUp.defaultKeyboard)
        mappings.editing = nil
        print("KEYBOARD_MIDI_CONFLICT_CANCEL_CONFIRMED_TRANSFER_FIXED_ARROWS_AND_GLOBAL_PERSISTENCE_OK")
        if ProcessInfo.processInfo.environment["CATLIVE_MAPPING_TEST_NO_UI"] != "1" {
        _ = NSApplication.shared
        // Exercise the real event handler, including remapped navigation. A held
        // key must execute every repeat; transport toggles must execute only once.
        for (index, action) in [DAWAction.nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint, .playStop, .toggleVideo, .toggleTeleprompter, .toggleTracks, .toggleSetlist].enumerated() {
            let key = UInt16(90 + index)
            mappings.beginAction(action, kind: "keyboard")
            mappings.candidate = ControlInput(kind: "keyboard", label: "Test \(index)", key: key, modifiers: 0)
            mappings.save()
            precondition(mappings.editing == nil)
            let before = show.actionsReceived.count
            let began = ProcessInfo.processInfo.systemUptime
            for repeatIndex in 0..<12 {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatIndex > 0, keyCode: key)!
                precondition(mappings.handleKey(event))
            }
            precondition(show.actionsReceived.count - before == (action.repeats ? 12 : 1), "holding a remapped navigation key repeats without toggling playback or projection windows repeatedly")
            print("HELD_KEY_DISPATCH_MS=\(String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - began) * 1000)) ACTION=\(action.rawValue)")
        }
        print("NATIVE_HELD_NAVIGATION_DEFAULT_POLICY_REMAPPED_KEYS_AND_SINGLE_TRANSPORT_TOGGLE_OK")
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let alert = NSAlert()
        alert.messageText = "Save project?"
        alert.addButton(withTitle: "Save").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        parent.orderFront(nil)
        alert.beginSheetModal(for: parent) { _ in }
        precondition(alert.window.sheetParent === parent && alert.window.attachedSheet == nil)
        let beforeDialog = show.actionsReceived.count
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow, isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : code == 49 ? " " : "\r", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: code)!
        }
        for code: UInt16 in [36, 76, 53] {
            precondition(!mappings.handleKey(key(code, in: alert.window)), "a sheet must receive its Enter/Escape keys before any DAW shortcut")
            precondition(!mappings.handleKey(key(code, in: parent)), "the parent must not dispatch shortcuts while its sheet is open")
        }
        precondition(!mappings.handleKey(key(49, modifiers: .shift, in: alert.window)), "the sheet owns Shift+Space while it is open")
        precondition(!mappings.handleKey(key(49, modifiers: .shift, in: parent)), "the parent cannot start Sub Play while its sheet is open")
        precondition(show.actionsReceived.count == beforeDialog, "confirming a dialog must never start Sub Play")
        mappings.beginAction(.projectEnd, kind: "keyboard")
        mappings.candidate = ControlInput(kind: "keyboard", label: "Test dialog key", key: 119, modifiers: 0)
        precondition(mappings.handleKey(key(36, in: alert.window)) && mappings.editing == nil, "Enter still confirms the shortcut learner inside Settings")
        mappings.beginAction(.projectEnd, kind: "keyboard")
        precondition(mappings.handleKey(key(53, in: alert.window)) && mappings.editing == nil, "Escape cancels only the active learner inside Settings")
        precondition(parent.attachedSheet === alert.window && !mappings.handleKey(key(36, in: alert.window)))
        parent.endSheet(alert.window)
        alert.window.orderOut(nil)
        NativeTimelineInputGate.shared.setBlocked(true, for: parent)
        precondition(!mappings.handleKey(key(49, modifiers: .shift, in: parent)), "an in-window editor owns Shift+Space instead of Sub Play")
        mappings.beginAction(.projectEnd, kind: "keyboard")
        precondition(mappings.handleKey(key(53, in: parent)) && mappings.editing == nil, "Escape still cancels the active shortcut learner")
        NativeTimelineInputGate.shared.setBlocked(false, for: parent)
        for code: UInt16 in [36, 76] {
            precondition(!mappings.handleKey(key(code, in: parent)), "Enter and keypad Enter no longer start Sub Play")
        }
        precondition(mappings.handleKey(key(49, modifiers: .shift, in: parent)), "Shift+Space starts Sub Play after the dialog closes")
        precondition(show.actionsReceived.last == .subPlayStop)
        let afterSubPlay = show.actionsReceived.count
        precondition(mappings.handleKey(key(49, modifiers: .shift, in: parent, isRepeat: true)))
        precondition(show.actionsReceived.count == afterSubPlay, "holding Shift+Space must not toggle Sub Play repeatedly")
        for code: UInt16 in [51, 117, 53] {
            mappings.beginAction(.projectEnd, kind: "keyboard")
            mappings.candidate = ControlInput(kind: "keyboard", label: "Envelope key", key: code, modifiers: 0)
            mappings.save()
            precondition(mappings.editing == nil)
            let before = show.actionsReceived.count
            RegionShortcutView.editingEnvelope = true
            precondition(!mappings.handleKey(key(code, in: parent)), "even remapped Delete and Escape belong to the active envelope")
            precondition(show.actionsReceived.count == before)
            RegionShortcutView.editingEnvelope = false
            precondition(mappings.handleKey(key(code, in: parent)), "the mapping resumes after leaving the envelope editor")
        }
        RegionShortcutView.editingEnvelope = true
        mappings.beginAction(.projectEnd, kind: "keyboard")
        precondition(mappings.handleKey(key(53, in: parent)) && mappings.editing == nil, "the shortcut learner retains its explicit Escape priority")
        RegionShortcutView.editingEnvelope = false
        print("ENVELOPE_DELETE_ESCAPE_KEYS_BEFORE_GLOBAL_MAPPINGS_OK")
        parent.orderOut(nil)
        print("DIALOG_ENTER_ESCAPE_PRIORITY_AND_TRANSPORT_RESTORATION_OK")
        }
        // Exercise the real CoreMIDI receive thread, not only the injected
        // learner calls above. Actor race checks stay enabled in this harness.
        var virtualClient: MIDIClientRef = 0, virtualSource: MIDIEndpointRef = 0
        precondition(MIDIClientCreateWithBlock("CatLive mapping test source" as CFString, &virtualClient, nil) == noErr)
        precondition(MIDISourceCreateWithProtocol(virtualClient, "CatLive virtual controller" as CFString, ._1_0, &virtualSource) == noErr)
        defer { MIDIEndpointDispose(virtualSource); MIDIClientDispose(virtualClient) }
        var sourceID: Int32 = 0
        precondition(MIDIObjectGetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, &sourceID) == noErr)
        AudioDeviceSettings.shared.midiSlots = [sourceID]
        mappings.bind(show)
        mappings.beginAction(.play, kind: "midi")
        func transmit(_ words: UInt32...) {
            var list = MIDIEventList()
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIEventListInit(pointer, ._1_0)
                words.withUnsafeBufferPointer { buffer in
                    _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, buffer.count, buffer.baseAddress!)
                }
                precondition(MIDIReceivedEventList(virtualSource, pointer) == noErr)
            }
        }
        transmit(0x20936364) // Group 0, channel 4, note 99, velocity 100.
        var deadline = ProcessInfo.processInfo.systemUptime + 3
        while mappings.candidate == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(mappings.candidate?.device == sourceID && mappings.candidate?.channel == 3 && mappings.candidate?.number == 99, "real UMP messages reach the MIDI learner on MainActor")
        mappings.save()
        let beforePlay = show.actionsReceived.count
        transmit(0x20836300, 0x20936364)
        deadline = ProcessInfo.processInfo.systemUptime + 3
        while show.actionsReceived.count == beforePlay && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(show.actionsReceived.count == beforePlay + 1 && show.actionsReceived.last == .play)
        print("REAL_COREMIDI_UMP_PORT_LEARNING_AND_MAPPED_PLAY_ON_MAIN_ACTOR_OK")
        mappings.sources[100] = (123, "Test MIDI")
        let instrumentBefore = StemAudioPlayback.shared.forwarded
        VinhetasController.shared.claimedNumber = 61
        mappings.receive(endpoint: 100, status: 0x95, number: 61, value: 100)
        mappings.receive(endpoint: 100, status: 0x85, number: 61, value: 0)
        let padMessages = VinhetasController.shared.received.suffix(2)
        precondition(padMessages.map { $0.0.status } == [0x90, 0x80] && padMessages.allSatisfy { $0.0.channel == 5 })
        precondition(StemAudioPlayback.shared.forwarded == instrumentBefore, "Pad notes must not also play an armed instrument")
        VinhetasController.shared.claimedNumber = nil
        print("VINHETAS_MIDI_NOTE_OFF_CHANNEL_AND_EXCLUSIVE_ROUTING_OK")
        mappings.show = show
        mappings.beginSetlistBlock(1)
        precondition(mappings.learningSetlistBlock && mappings.mode == "midi" && mappings.candidate == nil)
        cc(100, 127); mappings.save()
        let firstBlockBinding = mappings.mappings.first { $0.globalSetlistBlockNumber == 1 }!
        precondition(firstBlockBinding.command == "setlistBlock:1" && firstBlockBinding.track == nil)
        let savedBlocks = try! JSONDecoder().decode([MappedControl].self, from: defaults.data(forKey: "jaras.controlMappings")!)
        precondition(savedBlocks.contains { $0.id == firstBlockBinding.id && $0.globalSetlistBlockNumber == 1 }, "Global block bindings survive the existing JSON persistence schema")
        mappings.show = other
        precondition(mappings.current.contains { $0.id == firstBlockBinding.id }, "A block learned in another project remains active")
        let actionsBeforeBlock = other.actionsReceived.count
        cc(100, 0); cc(100, 127); cc(100, 64)
        precondition(other.focusedBlocks == [1] && other.actionsReceived.count == actionsBeforeBlock, "A mapped block only requests focus, without Play and without repeated activation while held")
        cc(100, 0); cc(100, 127, channel: 1)
        precondition(other.focusedBlocks == [1], "The learned MIDI channel remains part of the match")
        cc(100, 127)
        precondition(other.focusedBlocks == [1, 1], "Release allows another press to select the current playlist's block again")
        mappings.beginSetlistBlock(1)
        precondition(mappings.candidate == firstBlockBinding.input && mappings.hasSetlistBlockMapping, "The editor reopens the same global binding in a different project")
        cc(101, 127); mappings.editing = nil
        precondition(mappings.mappings.contains { $0.id == firstBlockBinding.id && $0.input.number == 100 }, "Cancel preserves the original mapping")
        mappings.beginSetlistBlock(1); cc(101, 0); cc(101, 127); mappings.save()
        precondition(mappings.mappings.filter { $0.globalSetlistBlockNumber == 1 }.count == 1, "Saving in another project replaces one global mapping instead of creating a project duplicate")
        mappings.beginSetlistBlock(2); cc(101, 0); cc(101, 127); mappings.save()
        precondition(mappings.transferRequest != nil && mappings.mappings.contains { $0.globalSetlistBlockNumber == 1 }, "Two block IDs cannot silently share the same MIDI input")
        mappings.cancelTransfer(); mappings.editing = nil
        precondition(!mappings.mappings.contains { $0.globalSetlistBlockNumber == 2 }, "Canceling a transfer leaves the second block unmapped")
        mappings.beginSetlistBlock(2); cc(101, 0); cc(101, 127); mappings.save(); mappings.confirmTransfer()
        precondition(!mappings.mappings.contains { $0.globalSetlistBlockNumber == 1 } && mappings.mappings.contains { $0.globalSetlistBlockNumber == 2 }, "Confirmed transfer moves the input between global block IDs")
        mappings.beginSetlistBlock(2); mappings.removeEditingSetlistBlockMapping()
        let afterRemove = try! JSONDecoder().decode([MappedControl].self, from: defaults.data(forKey: "jaras.controlMappings")!)
        precondition(mappings.editing == nil && !afterRemove.contains { $0.globalSetlistBlockNumber == 2 }, "Remove mapping persists and closes the block learner")
        mappings.beginAction(.repeatPlayback, kind: "midi"); cc(104, 127); mappings.save()
        mappings.beginSetlistBlock(129); cc(104, 0); cc(104, 127); mappings.save()
        precondition(mappings.transferRequest != nil && mappings.actions.binding(.repeatPlayback).midi?.number == 104, "Block learn respects existing global action conflicts")
        mappings.confirmTransfer()
        precondition(mappings.actions.binding(.repeatPlayback).midi == nil && mappings.mappings.contains { $0.globalSetlistBlockNumber == 129 }, "Global block ordinals are not limited to a fixed enum")
        mappings.beginSetlistBlock(129)
        mappings.mode = "keyboard"; mappings.candidate = ControlInput(kind: "keyboard", label: "Z", key: 6, modifiers: 0); mappings.save()
        precondition(mappings.editing != nil && mappings.mappings.first { $0.globalSetlistBlockNumber == 129 }?.input.kind == "midi", "A block Learn MIDI cannot accidentally save a keyboard binding")
        mappings.removeEditingSetlistBlockMapping()
        mappings.beginSetlistBlock(0)
        precondition(mappings.editing == nil && SetlistBlockMIDICommand.number("setlistBlock:0") == nil && SetlistBlockMIDICommand.number("setlistBlock:-1") == nil && SetlistBlockMIDICommand.number("setlistBlock:+1") == nil, "Invalid block IDs cannot enter the global namespace")
        // A project-specific FX control in a different project must also be
        // transferred explicitly before making its input globally active.
        mappings.show = other
        mappings.beginFX(track: otherTrack, parameter: parameter); cc(106, 127); mappings.save()
        let foreignFX = mappings.mappings.first { $0.project == other.snapshot.project.id && $0.input.number == 106 }!
        mappings.show = show
        mappings.beginSetlistBlock(3); cc(106, 0); cc(106, 127); mappings.save()
        precondition(mappings.transferRequest != nil && mappings.mappings.contains { $0.id == foreignFX.id }, "Learning a global block detects FX conflicts outside the current project")
        mappings.confirmTransfer()
        precondition(!mappings.mappings.contains { $0.id == foreignFX.id } && mappings.current.contains { $0.globalSetlistBlockNumber == 3 })
        mappings.beginFX(track: track, parameter: parameter); cc(106, 127); mappings.save()
        precondition(mappings.transferRequest != nil, "A project-specific FX mapping cannot silently shadow a global block")
        mappings.confirmTransfer()
        precondition(!mappings.mappings.contains { $0.globalSetlistBlockNumber == 3 }, "Reverse transfer removes the global block mapping")
        mappings.beginSetlistBlock(4)
        mappings.receive(endpoint: 100, status: 0x92, number: 108, value: 90); mappings.save()
        mappings.receive(endpoint: 100, status: 0x82, number: 108, value: 0)
        mappings.receive(endpoint: 100, status: 0x92, number: 108, value: 90)
        precondition(show.focusedBlocks.last == 4, "MIDI notes as well as CC can select a numbered block")
        let beforeZeroVelocity = show.focusedBlocks.count
        mappings.receive(endpoint: 100, status: 0x92, number: 108, value: 0)
        precondition(show.focusedBlocks.count == beforeZeroVelocity, "Note On velocity zero releases the binding without selecting another block")
        mappings.receive(endpoint: 100, status: 0x92, number: 108, value: 90)
        precondition(show.focusedBlocks.count == beforeZeroVelocity + 1, "A fresh note press works after a velocity-zero release")
        print("GLOBAL_SETLIST_BLOCK_ORDINAL_MIDI_PERSISTENCE_FOCUS_LATCH_CHANNEL_CANCEL_REMOVE_AND_CROSS_PROJECT_CONFLICTS_OK")
        // Real Vinhetas channel matching and transfer helpers are compiled into
        // the stub; only its audio/persistence environment is replaced.
        let vinhetas = VinhetasController.shared
        var padInput = ControlInput(kind: "midi", label: "Pad CC", device: 123, channel: 7, status: 0xb0, number: 110)
        var otherPadInput = padInput; otherPadInput.number = 111
        var otherDeviceInput = padInput; otherDeviceInput.device = 777
        vinhetas.update {
            $0.padMappings[0] = padInput; $0.padMappings[1] = otherPadInput
            $0.padMappings[3] = otherDeviceInput; $0.presetMappings[2] = padInput
        }
        let originalVinhetas = vinhetas.library
        let originalPersistedVinhetas = vinhetas.persistedLibrary
        mappings.beginSetlistBlock(10); cc(110, 127); mappings.save()
        precondition(mappings.transferRequest?.message.contains("Vinhetas · Pad 1") == true && mappings.transferRequest?.message.contains("Vinhetas · Preset 3") == true,
                     "Block learn reports both pad and preset consumers, including an empty pad and effective Omni channel")
        precondition(vinhetas.library == originalVinhetas && vinhetas.persistedLibrary == originalPersistedVinhetas)
        mappings.cancelTransfer(); mappings.editing = nil
        precondition(vinhetas.library == originalVinhetas && !mappings.mappings.contains { $0.globalSetlistBlockNumber == 10 },
                     "Cancel must leave both Vinhetas and block bindings unchanged")
        mappings.beginSetlistBlock(10); cc(110, 0); cc(110, 127); mappings.save(); mappings.confirmTransfer()
        var expectedVinhetas = originalVinhetas; expectedVinhetas.padMappings[0] = nil; expectedVinhetas.presetMappings[2] = nil
        precondition(vinhetas.library == expectedVinhetas && (try! JSONDecoder().decode(VinhetasLibrary.self, from: vinhetas.persistedLibrary!)) == expectedVinhetas,
                     "Confirmed transfer removes and persists only matching pad/preset bindings, preserving other devices, pads and all preset content")
        let beforeTransferredBlock = show.focusedBlocks.count
        cc(110, 0); cc(110, 127)
        precondition(show.focusedBlocks.count == beforeTransferredBlock + 1 && show.focusedBlocks.last == 10,
                     "After transfer the receive path reaches the block instead of being swallowed by Vinhetas")
        padInput.status = 0x90; padInput.number = 112
        vinhetas.update { $0.midiChannel = 3; $0.padMappings[2] = padInput }
        mappings.beginSetlistBlock(11)
        mappings.receive(endpoint: 100, status: 0x90, number: 112, value: 100); mappings.save()
        precondition(mappings.editing == nil && vinhetas.library.padMappings[2] == padInput,
                     "A block on another effective channel does not remove a Vinhetas binding")
        mappings.beginSetlistBlock(12)
        mappings.receive(endpoint: 100, status: 0x92, number: 112, value: 100); mappings.save()
        precondition(mappings.transferRequest?.message.contains("Vinhetas · Pad 3") == true,
                     "Vinhetas' selected channel overrides the channel remembered by its learned note")
        let oldRequest = mappings.transferRequest!
        mappings.candidate?.number = 113; mappings.confirmTransfer(oldRequest)
        precondition(vinhetas.library.padMappings[2] == padInput && !mappings.mappings.contains { $0.globalSetlistBlockNumber == 12 },
                     "A stale confirmation cannot remove a Vinhetas binding after the candidate changes")
        mappings.candidate = oldRequest.input; mappings.save(); mappings.confirmTransfer()
        precondition(vinhetas.library.padMappings[2] == nil && mappings.mappings.contains { $0.globalSetlistBlockNumber == 11 })
        mappings.receive(endpoint: 100, status: 0x82, number: 112, value: 0)
        mappings.receive(endpoint: 100, status: 0x92, number: 112, value: 100)
        precondition(show.focusedBlocks.last == 12, "A transferred note selects its block on a fresh press")
        print("SETLIST_BLOCK_VINHETAS_CC_NOTE_OMNI_CHANNEL_CANCEL_TRANSFER_PERSISTENCE_AND_STALE_CONFIRMATION_OK")

    }
}

@MainActor final class DesktopProjectTabs {
    static let shared = DesktopProjectTabs()
    func receiveMIDI(device: Int32, status: UInt8, number: UInt8, value: UInt8) {
        StemAudioPlayback.shared.receiveMIDI(device: device, status: status, number: number, value: value)
    }
}
