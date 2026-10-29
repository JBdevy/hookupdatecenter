import SwiftUI
import AVFoundation
import CoreMIDI
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

struct OutputDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var channels: Int
    var hardwareID: UInt32
}

struct MIDIInputDevice: Identifiable, Equatable {
    let id: Int32
    let name: String
}
#if os(iOS)
/// Serialize hardware teardown away from the main actor. The native iPad
/// driver owns RemoteIO separately from the manually rendered DSP graph.
final class MobileAudioHardwareStop: @unchecked Sendable {
    enum Failure: Error { case timedOut }
    private let lock = NSLock()
    private var finished = false
    private let began = ProcessInfo.processInfo.systemUptime
    init(settlingTime: Double = 0, stop: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + settlingTime) { [self] in
            stop()
            lock.lock(); finished = true; lock.unlock()
        }
    }
    private func hasFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }; return finished
    }
    func wait(timeout: Double = 4) async throws {
        while !hasFinished() {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - began >= timeout { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
    }
}
enum MobileAudioSessionEvent {
    case interrupted
    case interruptionEnded
    case routeChanged(outputRemoved: Bool)
    case mediaServicesReset
}
#endif
#if os(macOS)
private let outputDevicePropertyListener: AudioUnitPropertyListenerProc = { context, _, _, _, _ in
    // AudioDeviceSettings is a process-lifetime singleton. HAL may invoke this
    // callback off the main thread; engine graph changes stay on the main actor.
    let settings = Unmanaged<AudioDeviceSettings>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor [weak settings] in settings?.outputDeviceDidChange() }
}
#endif
@MainActor final class AudioDeviceSettings: ObservableObject {
    static let shared = AudioDeviceSettings()
    static let systemDefaultUID = "catlive.system-default"
    @Published private(set) var followsSystemInput = UserDefaults.standard.bool(forKey: "catlive.followSystemInput")
    @Published private(set) var followsSystemOutput = UserDefaults.standard.bool(forKey: "catlive.followSystemOutput")
    var inputSelection: String { followsSystemInput ? Self.systemDefaultUID : inputUID }
    var outputSelection: String { followsSystemOutput ? Self.systemDefaultUID : (selectedUID.isEmpty ? "none" : selectedUID) }
    @Published private(set) var inputDevices: [OutputDevice] = []
    @Published private(set) var inputUID = UserDefaults.standard.string(forKey: "catlive.audioInputUID") ?? ""
    var inputDeviceChanged: (() -> Void)?
    var usesSystemLoopback: Bool {
        #if os(macOS)
        if #available(macOS 14.2, *) { return inputUID == Self.loopbackUID }
        #endif
        return false
    }
    #if os(macOS)
    static let loopbackUID = "catlive.system-loopback"
    private(set) var loopback: AnyObject?
    private var loopbackHardwareID: AudioDeviceID {
        if #available(macOS 14.2, *) { return (loopback as? MacSystemLoopback)?.device ?? 0 }
        return 0
    }
    func resolveInputDevice() throws -> OutputDevice? {
        if #available(macOS 14.2, *), usesSystemLoopback {
            let capture = (loopback as? MacSystemLoopback) ?? MacSystemLoopback()
            let id = try capture.prepare()
            loopback = capture
            let entry = OutputDevice(id: Self.loopbackUID, name: "Loopback — áudio do Mac", channels: 2, hardwareID: id)
            if let index = inputDevices.firstIndex(where: { $0.id == Self.loopbackUID }), inputDevices[index] != entry {
                // Preparing an armed input can happen while a view is updating.
                // The catalog notification publishes the hardware change later.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loopbackHardwareID == id,
                          let current = self.inputDevices.firstIndex(where: { $0.id == Self.loopbackUID }),
                          self.inputDevices[current] != entry else { return }
                    self.inputDevices[current] = entry
                }
            }
            configuredInputHardwareID = id
            return entry
        }
        return inputDevice
    }
    #endif
    var inputDevice: OutputDevice? {
        var value = inputDevices.first { $0.id == inputUID }
        #if os(macOS)
        if usesSystemLoopback { value?.hardwareID = loopbackHardwareID }
        #endif
        return value
    }
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var selectedUID = UserDefaults.standard.string(forKey: "jaras.audioOutputUID") ?? ""
    @Published private(set) var channels = 0
    @Published var error = ""
    @Published private(set) var sampleRate = 48000.0
    @Published private(set) var sampleRateChoices: [Double] = [44100, 48000]
    @Published private(set) var bufferFrames = 512
    @Published private(set) var bufferChoices: [Int] = [64, 128, 256, 512, 1024]
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var midiDevices: [MIDIInputDevice] = []
    @Published private(set) var midiOutputs: [MIDIInputDevice] = []
    @Published private(set) var midiOutput = (UserDefaults.standard.object(forKey: "jaras.midiOutput") as? NSNumber)?.int32Value ?? 0
    @Published private(set) var midiSlots: [Int32] = {
        let stored = (UserDefaults.standard.array(forKey: "jaras.midiSlots") as? [NSNumber])?.map(\.int32Value) ?? []
        return Array((stored + Array(repeating: 0, count: 6)).prefix(6))
    }()
    @Published private(set) var midiOutputSlots: [Int32] = {
        let stored = (UserDefaults.standard.array(forKey: "jaras.midiOutputSlots") as? [NSNumber])?.map(\.int32Value)
            ?? [(UserDefaults.standard.object(forKey: "jaras.midiOutput") as? NSNumber)?.int32Value ?? 0]
        return Array((stored + Array(repeating: 0, count: 6)).prefix(6))
    }()
    static func midiOutputSlotID(_ slot: Int) -> Int32 { -1_000_001 - Int32(slot) }
    func midiOutputSlotTitle(_ slot: Int) -> String {
        let id = midiOutputSlots[slot]
        let name = id == 0 ? JarasLocalization.string("None") : midiOutputs.first(where: { $0.id == id })?.name ?? ((midiNames[String(id)] ?? "MIDI") + " — " + JarasLocalization.string("Disconnected"))
        return "MIDI \(slot + 1) · " + name
    }
    func selectMIDIOutput(_ id: Int32, slot: Int) {
        guard midiOutputSlots.indices.contains(slot), id == 0 || midiOutputs.contains(where: { $0.id == id }) else { return }
        midiOutputSlots[slot] = id
        UserDefaults.standard.set(midiOutputSlots.map(NSNumber.init(value:)), forKey: "jaras.midiOutputSlots")
        if slot == 0 { midiOutput = id; UserDefaults.standard.set(NSNumber(value:id), forKey:"jaras.midiOutput") }
    }
    private var midiNames = UserDefaults.standard.dictionary(forKey: "jaras.midiNames") as? [String:String] ?? [:]
    let engine = AVAudioEngine()
    var deviceChanged: (() -> Void)?
    var canChangeConfiguration: () -> Bool = { true }
    private var midiClient: MIDIClientRef = 0
    private var configuredUID: String?
    private var configuredHardwareID: UInt32?
    #if os(iOS)
    static let defaultMobileInput = "catlive.mobile.default-input"
    private(set) var localSessionEnabled = false
    private(set) var localSessionInterrupted = false
    @Published private(set) var localSessionReconfiguring = false
    func beginLocalRouteChange() { localSessionReconfiguring = true }
    func finishLocalRouteChange() { localSessionReconfiguring = false }
    var mobileSessionEvent: ((MobileAudioSessionEvent) -> Void)?
    private var mobileObservers: [NSObjectProtocol] = []
    #endif
    #if os(macOS)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listeningAddresses: [AudioObjectPropertyAddress] = []
    private var observedOutputUnit: AudioUnit?
    private var defaultRefreshPending = false
    private func systemDefaultDevice(input: Bool) -> OutputDevice? {
        var id: AudioDeviceID = 0, bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &id) == noErr else { return nil }
        return (input ? inputDevices : devices).first { $0.hardwareID == id }
    }
    private func refreshSystemDefaults() {
        let input = systemDefaultDevice(input: true)?.id ?? ""
        let output = systemDefaultDevice(input: false)?.id ?? "none"
        guard (followsSystemInput && inputUID != input) || (followsSystemOutput && selectedUID != output) else { return }
        // Recording owns its route until the take finishes. Catalog events are
        // coalesced and the latest OS choice is resolved again afterwards.
        guard canChangeConfiguration() else {
            if !defaultRefreshPending {
                defaultRefreshPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.defaultRefreshPending = false; self.refresh()
                }
            }
            return
        }
        if followsSystemInput && inputUID != input { bindInput(input) }
        if followsSystemOutput && selectedUID != output { bindOutput(output) }
    }
    #endif
    var deviceName: String { devices.first { $0.id == selectedUID }?.name ?? JarasLocalization.string("No output device") }
    private init() {
        MIDIClientCreateWithBlock("CatLive Devices" as CFString, &midiClient) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMIDI() }
        }
        refreshMIDI()
        refresh()
        #if os(iOS)
        observeMobileSession()
        #endif
        #if os(macOS)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } }
        deviceListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr { listeningAddresses.append(address) }
        }
        #endif
    }
    func refreshMIDI() {
        let inputs = (0..<MIDIGetNumberOfSources()).compactMap { index -> MIDIInputDevice? in
            let source = MIDIGetSource(index)
            var offline: Int32 = 0, uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &offline)
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            guard offline == 0, uniqueID != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            return MIDIInputDevice(id: uniqueID, name: name?.takeRetainedValue() as String? ?? "MIDI \(index + 1)")
        }
        let names = inputs.map(\.name)
        let outputs = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> MIDIInputDevice? in
            let destination = MIDIGetDestination(index)
            var offline: Int32 = 0, uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyOffline, &offline)
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uniqueID)
            guard offline == 0, uniqueID != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(destination, kMIDIPropertyDisplayName, &name)
            return MIDIInputDevice(id: uniqueID, name: name?.takeRetainedValue() as String? ?? "MIDI \(index + 1)")
        }
        // Device notifications can contain several events for the same ports.
        // Publish only a changed catalog, so open routing menus remain stable.
        if midiDevices != inputs { midiDevices = inputs }
        if midiSources != names { midiSources = names }
        if midiOutputs != outputs { midiOutputs = outputs }
        var remembered = midiNames
        for device in inputs { remembered[String(device.id)] = device.name }
        for device in outputs { remembered[String(device.id)] = device.name }
        if remembered != midiNames {
            midiNames = remembered
            UserDefaults.standard.set(midiNames, forKey: "jaras.midiNames")
        }
        if UserDefaults.standard.object(forKey: "jaras.midiSlots") == nil, let first = midiDevices.first { selectMIDI(first.id, slot: 0) }
        if UserDefaults.standard.object(forKey: "jaras.midiOutput") == nil, let first = midiOutputs.first { selectMIDIOutput(first.id) }
    }
    func selectMIDIOutput(_ id: Int32) {
        guard id == 0 || midiOutputs.contains(where: { $0.id == id }) else { return }
        selectMIDIOutput(id, slot: 0)
    }
    var midiOutputTitle: String {
        midiOutput == 0 ? JarasLocalization.string("None") : midiOutputs.first(where: { $0.id == midiOutput })?.name ?? ((midiNames[String(midiOutput)] ?? "MIDI") + " — " + JarasLocalization.string("Disconnected"))
    }
    func resolvedMIDIDestination(_ requested: Int32) -> Int32 {
        let slot = Int(-1_000_001 - Int64(requested))
        let id = requested == 0 ? midiOutput : midiOutputSlots.indices.contains(slot) ? midiOutputSlots[slot] : requested
        return midiOutputs.contains(where: { $0.id == id }) ? id : 0
    }
    func selectMIDI(_ id: Int32, slot: Int) {
        guard midiSlots.indices.contains(slot), id == 0 || midiDevices.contains(where: { $0.id == id }),
              id == 0 || !midiSlots.enumerated().contains(where: { $0.offset != slot && $0.element == id }) else { return }
        midiSlots[slot] = id
        UserDefaults.standard.set(midiSlots.map(NSNumber.init(value:)), forKey: "jaras.midiSlots")
    }
    func midiSlotTitle(_ slot: Int) -> String {
        guard midiSlots.indices.contains(slot) else { return "MIDI" }
        let id = midiSlots[slot]
        let name = id == 0 ? JarasLocalization.string("None") : midiDevices.first(where: { $0.id == id })?.name ?? ((midiNames[String(id)] ?? "MIDI") + " — " + JarasLocalization.string("Disconnected"))
        return "MIDI \(slot + 1) · " + name
    }
    func refresh() {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { error = "Unable to list audio devices"; return }
        var ids = Array(repeating: AudioDeviceID(0), count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, $0.baseAddress!) }
        guard result == noErr else { error = "Unable to list audio devices"; return }
        devices = ids.compactMap { id in
            let count = outputChannels(id)
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            let name = stringProperty(id, kAudioObjectPropertyName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard count > 0, !name.isEmpty, !uid.isEmpty, isSelectableAudioDevice(id, uid: uid) else { return nil }
            return OutputDevice(id: uid, name: name, channels: count, hardwareID: id)
        }
        inputDevices = ids.compactMap { id in
            let count = outputChannels(id, scope: kAudioDevicePropertyScopeInput)
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            let name = stringProperty(id, kAudioObjectPropertyName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard count > 0, !name.isEmpty, !uid.isEmpty, isSelectableAudioDevice(id, uid: uid) else { return nil }
            return OutputDevice(id: uid, name: name, channels: count, hardwareID: id)
        }
        // Private capture hardware is represented by one stable user selection.
        devices.removeAll { $0.hardwareID == loopbackHardwareID }
        inputDevices.removeAll { $0.hardwareID == loopbackHardwareID }
        if #available(macOS 14.2, *) {
            inputDevices.append(OutputDevice(id: Self.loopbackUID, name: "Loopback — áudio do Mac", channels: 2, hardwareID: loopbackHardwareID))
        }
        refreshSystemDefaults()
        // A catalog notification must not restart an armed recording input.
        let newInputHardwareID = inputDevice?.hardwareID
        if newInputHardwareID != configuredInputHardwareID {
            configuredInputHardwareID = newInputHardwareID
            inputDeviceChanged?()
        }
        if selectedUID == "none" { channels = 0; return }
        if let selected = devices.first(where: { $0.id == selectedUID }) { channels = selected.channels; if configuredUID != selected.id || configuredHardwareID != selected.hardwareID || !outputIsBound(to: selected.hardwareID) { bindOutput(selected.id) } }
        else if selectedUID.isEmpty {
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &defaultID)
            if let device = devices.first(where: { $0.hardwareID == defaultID }) ?? devices.first { bindOutput(device.id) }
            else { selectedUID = ""; channels = 0 }
        } else {
            // Keep the selected device on disconnection; never open a different
            // device behind the user's back while recovering its output session.
            suspendOutput(); configuredUID = nil; configuredHardwareID = nil; channels = 0
            error = JarasLocalization.string("The selected audio output is disconnected.")
            deviceChanged?()
        }
        #else
        let session = AVAudioSession.sharedInstance()
        devices = session.currentRoute.outputs.map { OutputDevice(id: $0.uid, name: $0.portName, channels: session.outputNumberOfChannels, hardwareID: 0) }
        if selectedUID != "none" { selectedUID = devices.first?.id ?? "" }
        channels = selectedUID == "none" ? 0 : devices.first?.channels ?? 0
        // Keep the input catalog available even when the recording input is
        // None. Capture and microphone permission remain owned by recording.
        inputDevices = [OutputDevice(id: Self.defaultMobileInput,
                                     name: JarasLocalization.string("System audio input"),
                                     channels: max(1, session.inputNumberOfChannels), hardwareID: 0)]
        inputDevices += (session.availableInputs ?? []).map {
            OutputDevice(id: $0.uid, name: $0.portName, channels: $0.channels?.count ?? 1, hardwareID: 0)
        }
        #endif
    }
    private var configuredInputHardwareID: UInt32?
    private func permitConfigurationChange() -> Bool {
        #if os(iOS)
        guard !localSessionReconfiguring else { return false }
        #endif
        guard canChangeConfiguration() else {
            error = JarasLocalization.string("Finish recording before changing the audio device.")
            return false
        }
        return true
    }
    func selectInput(_ uid: String) {
        guard permitConfigurationChange() else { return }
        #if os(macOS)
        guard uid.isEmpty || uid == Self.systemDefaultUID || inputDevices.contains(where: { $0.id == uid }) else { return }
        followsSystemInput = uid == Self.systemDefaultUID
        UserDefaults.standard.set(followsSystemInput, forKey: "catlive.followSystemInput")
        bindInput(followsSystemInput ? (systemDefaultDevice(input: true)?.id ?? "") : uid)
        #else
        bindInput(uid)
        #endif
    }
    private func bindInput(_ uid: String) {
        guard uid.isEmpty || inputDevices.contains(where: { $0.id == uid }) else { return }
        #if os(iOS)
        let previous = inputUID
        if localSessionEnabled {
            do { try configureMobileSession(input: uid) }
            catch {
                self.error = error.localizedDescription
                // The new route failed; keep the original selection visible.
                do { try configureMobileSession(input: previous) }
                catch { self.error += "\n" + error.localizedDescription }
                return
            }
        }
        #endif
        inputUID = uid; UserDefaults.standard.set(uid, forKey: "catlive.audioInputUID")
        configuredInputHardwareID = inputDevice?.hardwareID
        error = ""
        #if os(iOS)
        refresh(); refreshSampleRate(); refreshBuffer()
        #endif
        inputDeviceChanged?()
        #if os(macOS)
        if !usesSystemLoopback { loopback = nil }
        #endif
        #if os(iOS)
        if localSessionEnabled { deviceChanged?() }
        #endif
    }
    #if os(iOS)
    /// Only the local iPad workspace owns the audio session. The remote UI
    /// must not change the category or activate audio on the mobile device.
    func activateLocalSession() throws {
        guard !localSessionInterrupted else {
            throw ProjectError.invalid(JarasLocalization.string("Audio is interrupted by another app. Try again when it finishes."))
        }
        try configureMobileSession(input: inputUID)
        localSessionEnabled = true
        refresh(); refreshSampleRate(); refreshBuffer()
    }
    func deactivateLocalSession() throws {
        localSessionEnabled = false
        finishLocalRouteChange()
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func configureMobileSession(input: String) throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .default ||
            session.categoryOptions != [.defaultToSpeaker, .allowBluetooth, .mixWithOthers] {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        }
        try session.setActive(true)
        if input.isEmpty || input == Self.defaultMobileInput {
            if session.preferredInput != nil { try session.setPreferredInput(nil) }
        } else {
            if let port = session.availableInputs?.first(where: { $0.uid == input }) {
                if session.preferredInput?.uid != port.uid {
                    try session.setPreferredInput(port)
                }
            } else {
                // Preserve the missing selection. Playback can recover, while
                // requireLocalInput prevents capture from another microphone.
                error = JarasLocalization.string("The selected audio input is disconnected.")
            }
        }
        try configureMobileOutputChannels(session)
        let inputMaximum = session.maximumInputNumberOfChannels
        if inputMaximum > 0, session.preferredInputNumberOfChannels != inputMaximum {
            try session.setPreferredInputNumberOfChannels(inputMaximum)
        }
    }
    private func configureMobileOutputChannels(_ session: AVAudioSession) throws {
        // USB interfaces may start with only a stereo session. Request their
        // available channels before building the discrete hardware graph.
        let maximum = session.maximumOutputNumberOfChannels
        guard maximum > 0, session.outputNumberOfChannels != maximum,
              session.preferredOutputNumberOfChannels != maximum else { return }
        try session.setPreferredOutputNumberOfChannels(maximum)
    }
    func requireLocalInput(expectedUID: String? = nil) throws {
        guard localSessionEnabled, !localSessionInterrupted, !localSessionReconfiguring, !inputUID.isEmpty,
              expectedUID == nil || expectedUID == inputUID else {
            throw ProjectError.invalid(JarasLocalization.string("Choose an audio input device in Settings."))
        }
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, !session.currentRoute.inputs.isEmpty,
              inputUID == Self.defaultMobileInput || session.currentRoute.inputs.contains(where: { $0.uid == inputUID }) else {
            throw ProjectError.invalid(JarasLocalization.string("The selected audio input is disconnected."))
        }
    }
    private func observeMobileSession() {
        let center = NotificationCenter.default
        mobileObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.localSessionInterrupted = type == .began
                guard self.localSessionEnabled else { return }
                self.mobileSessionEvent?(type == .began ? .interrupted : .interruptionEnded)
            }
        })
        mobileObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                guard let self, self.localSessionEnabled else { return }
                self.beginLocalRouteChange()
                self.mobileSessionEvent?(.routeChanged(outputRemoved: raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue))
                self.refresh(); self.refreshSampleRate(); self.refreshBuffer()
            }
        })
        mobileObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.localSessionEnabled else { return }
                self.mobileSessionEvent?(.mediaServicesReset)
            }
        })
    }
    #endif
    func select(_ uid: String) {
        guard permitConfigurationChange() else { return }
        #if os(macOS)
        guard uid == "none" || uid == Self.systemDefaultUID || devices.contains(where: { $0.id == uid }) else { return }
        followsSystemOutput = uid == Self.systemDefaultUID
        UserDefaults.standard.set(followsSystemOutput, forKey: "catlive.followSystemOutput")
        bindOutput(followsSystemOutput ? (systemDefaultDevice(input: false)?.id ?? "none") : uid)
        #else
        bindOutput(uid)
        #endif
    }
    // Recovery rebinds the existing UID even while the transport is active.
    // It must never use the public, user-initiated device-change path.
    private func bindOutput(_ uid: String) {
        if uid == "none" {
            engine.stop()
            selectedUID = uid; channels = 0; configuredUID = nil; configuredHardwareID = nil
            UserDefaults.standard.set(uid, forKey: "jaras.audioOutputUID")
            engine.mainMixerNode.outputVolume = 0; error = ""; deviceChanged?()
            return
        }
        guard let device = devices.first(where: { $0.id == uid }) else { return }
        #if os(macOS)
        if configuredUID == uid, configuredHardwareID == device.hardwareID, outputIsBound(to: device.hardwareID) {
            error = ""
            if !engine.isRunning { deviceChanged?() }
            return
        }
        guard let unit = engine.outputNode.audioUnit else {
            error = JarasLocalization.string("Audio output is unavailable"); return
        }
        do { try observeOutputDevice(unit) }
        catch {
            suspendOutput()
            self.error = error.localizedDescription; return
        }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        var id = AudioDeviceID(device.hardwareID)
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else {
            error = String(format: JarasLocalization.string("Unable to open audio device (%d)."), result)
            // A rejected selection must not leave the previous output stopped.
            if !outputDeviceIsBound { suspendOutput() }
            if wasRunning { deviceChanged?() }
            return
        }
        guard outputIsBound(to: device.hardwareID) else {
            suspendOutput(); configuredUID = nil; configuredHardwareID = nil
            error = JarasLocalization.string("The selected audio output could not be confirmed.")
            return
        }
        #endif
        configuredUID = uid; configuredHardwareID = device.hardwareID; selectedUID = uid; channels = device.channels; error = ""
        UserDefaults.standard.set(uid, forKey: "jaras.audioOutputUID")
        refreshSampleRate()
        refreshBuffer()
        let savedBuffer = UserDefaults.standard.integer(forKey: "jaras.audioBufferFrames")
        if savedBuffer > 0, bufferChoices.contains(savedBuffer), savedBuffer != bufferFrames { applyBuffer(savedBuffer) }
        deviceChanged?()
    }
    #if os(macOS)
    private func observeOutputDevice(_ unit: AudioUnit) throws {
        guard observedOutputUnit != unit else { return }
        if let observedOutputUnit {
            AudioUnitRemovePropertyListenerWithUserData(observedOutputUnit, kAudioOutputUnitProperty_CurrentDevice,
                outputDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
            self.observedOutputUnit = nil
        }
        let result = AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_CurrentDevice,
            outputDevicePropertyListener, Unmanaged.passUnretained(self).toOpaque())
        guard result == noErr else {
            throw ProjectError.invalid(String(format: JarasLocalization.string("Unable to open audio device (%d)."), result))
        }
        observedOutputUnit = unit
    }
    private func suspendOutput() {
        engine.mainMixerNode.outputVolume = 0
        engine.stop()
    }
    fileprivate func outputDeviceDidChange() {
        guard selectedUID != "none", outputDeviceIsBound else {
            suspendOutput()
            deviceChanged?()
            return
        }
    }
    func validateOutputBinding() throws {
        guard selectedUID != "none", outputDeviceIsBound else {
            suspendOutput()
            throw ProjectError.invalid(JarasLocalization.string("The selected audio output could not be confirmed."))
        }
    }
    private func outputIsBound(to id: AudioDeviceID) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var actual = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        return status == noErr && size == MemoryLayout<AudioDeviceID>.size && actual == id
    }
    var outputDeviceIsBound: Bool {
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return false }
        return outputIsBound(to: device.hardwareID)
    }
    func requireSelectedOutput() throws {
        guard selectedUID != "none" else { return }
        do {
            guard let device = devices.first(where: { $0.id == selectedUID }) else {
                throw ProjectError.invalid(JarasLocalization.string("The selected audio output is disconnected."))
            }
            guard let unit = engine.outputNode.audioUnit else {
                throw ProjectError.invalid(JarasLocalization.string("Audio output is unavailable"))
            }
            try observeOutputDevice(unit)
            if configuredUID != selectedUID || configuredHardwareID != device.hardwareID || !outputIsBound(to: device.hardwareID) { bindOutput(selectedUID) }
            guard configuredUID == selectedUID, configuredHardwareID == device.hardwareID, outputIsBound(to: device.hardwareID) else {
                throw ProjectError.invalid(error.isEmpty ? JarasLocalization.string("Audio output is unavailable") : error)
            }
        } catch { suspendOutput(); self.error = error.localizedDescription; throw error }
    }
    #endif
    func refreshSampleRate() {
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var bytes = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &rate) == noErr else { return }
        sampleRate = rate
        address.mSelector = kAudioDevicePropertyAvailableNominalSampleRates
        guard AudioObjectGetPropertyDataSize(device.hardwareID, &address, 0, nil, &bytes) == noErr else { sampleRateChoices = [rate]; return }
        var ranges = Array(repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: Int(bytes) / MemoryLayout<AudioValueRange>.size)
        let result = ranges.withUnsafeMutableBytes { AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, $0.baseAddress!) }
        if result == noErr { sampleRateChoices = Array(Set([44100.0,48000.0].filter { candidate in ranges.contains { candidate >= $0.mMinimum && candidate <= $0.mMaximum } } + [rate])).sorted() }
        #else
        sampleRate = AVAudioSession.sharedInstance().sampleRate
        sampleRateChoices = Array(Set([44100,48000,sampleRate])).sorted()
        #endif
    }
    func setSampleRate(_ rate: Double) {
        guard permitConfigurationChange() else { return }
        guard sampleRateChoices.contains(rate) else { return }
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        do { try requireSelectedOutput() } catch { self.error = error.localizedDescription; return }
        engine.stop()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var requested = rate
        let result = AudioObjectSetPropertyData(device.hardwareID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &requested)
        if result != noErr { error = "Unable to change sample rate (\(result))"; refreshSampleRate(); deviceChanged?(); return }
        error = ""
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.refreshSampleRate(); self?.refreshBuffer()
            if let self { UserDefaults.standard.set(self.sampleRate, forKey: "jaras.audioSampleRate"); self.deviceChanged?() }
        }
        #else
        do {
            try AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
            refreshSampleRate(); refreshBuffer(); error = ""
        } catch { self.error = error.localizedDescription }
        #endif
    }
    func refreshBuffer() {
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &frames) == noErr else { return }
        bufferFrames = Int(frames)
        address.mSelector = kAudioDevicePropertyBufferFrameSizeRange
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        bytes = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &range) == noErr {
            bufferChoices = Array(Set([32,64,128,256,512,1024,2048,4096].filter { Double($0) >= range.mMinimum && Double($0) <= range.mMaximum } + [bufferFrames])).sorted()
        } else { bufferChoices = [bufferFrames] }
        #else
        let session = AVAudioSession.sharedInstance()
        bufferFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())
        bufferChoices = Array(Set([64,128,256,512,1024,2048,bufferFrames])).sorted()
        #endif
    }
    func setBuffer(_ frames: Int) {
        guard permitConfigurationChange() else { return }
        applyBuffer(frames)
    }
    private func applyBuffer(_ frames: Int) {
        guard bufferChoices.contains(frames) else { return }
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        do { try requireSelectedOutput() } catch { self.error = error.localizedDescription; return }
        let running = engine.isRunning
        if running { engine.stop() }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        let result = AudioObjectSetPropertyData(device.hardwareID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        refreshBuffer()
        if result == noErr {
            UserDefaults.standard.set(bufferFrames, forKey: "jaras.audioBufferFrames"); error = ""
        } else { error = "Unable to change buffer (\(result))" }
        deviceChanged?()
        #else
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(Double(frames) / session.sampleRate)
            refreshBuffer()
            UserDefaults.standard.set(bufferFrames, forKey: "jaras.audioBufferFrames"); error = ""
        } catch { self.error = error.localizedDescription }
        #endif
    }
    #if os(macOS)
    private func isSelectableAudioDevice(_ id: AudioDeviceID, uid: String) -> Bool {
        // AVAudioEngine creates this temporary input/output aggregate itself.
        // It is an implementation detail, never an input or output choice.
        guard !uid.hasPrefix("CADefaultDeviceAggregate-") else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &hidden) == noErr, hidden != 0 { return false }
        address.mSelector = kAudioObjectPropertyClass
        var deviceClass: AudioClassID = 0; bytes = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &deviceClass) == noErr,
              deviceClass == kAudioAggregateDeviceClassID else { return true }
        address.mSelector = kAudioAggregateDevicePropertyComposition
        var composition: Unmanaged<CFDictionary>?
        bytes = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return true }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue != true
    }
    private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var text: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &text) == noErr else { return "Device \(id)" }
        return text as String
    }
    private func outputChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    #endif
}

#if os(macOS)
@available(macOS 14.2, *)
final class MacSystemLoopback {
    private(set) var device: AudioDeviceID = 0
    private var tap: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private(set) var running = false
    private(set) var format: AVAudioFormat?
    private var nativeFormat = AudioStreamBasicDescription()
    func prepare() throws -> AudioDeviceID {
        if device != 0 { return device }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "CatLive System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var created: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &created)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        tap = created
        let specification: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CatLive Loopback",
            kAudioAggregateDeviceUIDKey: "catlive.loopback." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        var aggregate: AudioDeviceID = 0
        let result = AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate)
        guard result == noErr else { close(); throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        device = aggregate
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let read = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &nativeFormat)
        guard read == noErr, nativeFormat.mFormatID == kAudioFormatLinearPCM,
              nativeFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, nativeFormat.mBitsPerChannel == 32,
              nativeFormat.mSampleRate > 0, nativeFormat.mChannelsPerFrame > 0,
              let output = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.mSampleRate, channels: nativeFormat.mChannelsPerFrame) else {
            close(); throw NSError(domain: NSOSStatusErrorDomain, code: Int(read == noErr ? kAudioHardwareUnsupportedOperationError : read))
        }
        format = output
        return aggregate
    }
    func setCapture(_ capture: ((AVAudioPCMBuffer) -> Void)?) throws {
        let resume = running
        stop()
        if let io { AudioDeviceDestroyIOProcID(device, io); self.io = nil }
        guard let capture, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
        let channels = Int(format.channelCount)
        let result = AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, _, _, _ in
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = source.first, first.mNumberChannels > 0, first.mData != nil else { return }
            let count = min(4096, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
            guard count > 0, let output = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            var channel = 0
            for entry in source {
                guard let data = entry.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(entry.mNumberChannels)
                let frames = min(count, Int(entry.mDataByteSize) / max(1, stride * MemoryLayout<Float>.size))
                for c in 0..<stride where channel < channels {
                    for i in 0..<frames { output[channel][i] = data[i * stride + c] }
                    for i in frames..<count { output[channel][i] = 0 }
                    channel += 1
                }
            }
            for c in channel..<channels { output[c].update(repeating: 0, count: count) }
            capture(buffer)
        }
        guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        if resume { try start() }
    }
    func start() throws {
        guard !running else { return }
        guard let io else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioHardwareNotRunningError)) }
        let status = AudioDeviceStart(device, io)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        running = true
    }
    func stop() {
        if running, let io { AudioDeviceStop(device, io) }
        running = false
    }
    func close() {
        stop()
        if let io { AudioDeviceDestroyIOProcID(device, io); self.io = nil }
        format = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { close() }
}

#endif
