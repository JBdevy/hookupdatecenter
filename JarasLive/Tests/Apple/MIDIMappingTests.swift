import SwiftUI
import CoreMIDI

// Only the external devices and project are replaced. The test compiles the
// production MIDI learner, conflict detection, latch and continuous routing.
enum ShowCommand: String { case mute, solo, volume, pan }
struct MappingTestTrack { let id: UUID; let name: String }
struct MappingTestSong { var tracks: [MappingTestTrack] = [] }
struct MappingTestProject { var id = UUID(); var songs: [MappingTestSong] = [] }
struct MappingTestSnapshot { var project = MappingTestProject() }
@MainActor final class ShowController {
    var snapshot = MappingTestSnapshot()
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
    func actionTrack(number: Int?) -> MappingTestTrack? { snapshot.project.songs.first?.tracks.first }
    func performAction(_ action: DAWAction, trackNumber: Int?) { actionsReceived.append(action) }
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
        let show = ShowController(), mappings = ControlMappings.shared
        let track = UUID()
        show.snapshot.project.songs = [MappingTestSong(tracks: [MappingTestTrack(id: track, name: "Piano")])]
        mappings.show = show
        mappings.sources[100] = (123, "Test MIDI")
        func cc(_ number: UInt8, _ value: UInt8, channel: UInt8 = 0) {
            mappings.receive(endpoint: 100, status: 0xb0 | channel, number: number, value: value)
        }
        mappings.begin(track: track, command: "volume")
        precondition(mappings.mode == "midi")
        mappings.receive(endpoint: 100, status: 0x90, number: 60, value: 100)
        precondition(mappings.candidate == nil, "A note cannot be learned as a fader")
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
        precondition(mappings.editing != nil && !mappings.error.isEmpty, "A CC cannot drive two different mapped controls")
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
        precondition(decoded.filter { $0.command == "volume" }.count == 2)
        mappings.beginAction(.panTrack, kind: "midi")
        mappings.receive(endpoint: 100, status: 0x90, number: 61, value: 100)
        precondition(mappings.candidate == nil)
        cc(10, 0); mappings.save()
        cc(10, 0); cc(10, 64); cc(10, 127)
        precondition(show.previews.suffix(3).map { $0.1 } == [-1, 0, 1])
        try? await Task.sleep(nanoseconds: 40_000_000)
        precondition(show.commands.last?.0 == .pan && show.commands.last?.2 == 1)
        for (action, controller) in [(DAWAction.toggleAuto, UInt8(30)), (.setlistUp, 31), (.setlistDown, 32)] {
            mappings.beginAction(action, kind: "midi"); cc(controller, 127); mappings.save()
            cc(controller, 0); cc(controller, 127); cc(controller, 80)
            precondition(show.actionsReceived.last == action)
        }
        precondition(show.actionsReceived == [.toggleAuto, .setlistUp, .setlistDown])
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
    }
}
