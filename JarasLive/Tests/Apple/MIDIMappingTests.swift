import SwiftUI
import CoreMIDI
let mappingTestApplicationActive = true
@MainActor enum RegionShortcutView {
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
        parent.orderOut(nil)
        print("DIALOG_ENTER_ESCAPE_PRIORITY_AND_TRANSPORT_RESTORATION_OK")
    }
}
