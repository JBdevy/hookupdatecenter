import Foundation

// This fixture executes extracted production methods against a deterministic
// HAL/engine. It must never open a physical device or change system settings.
enum ProjectError: Error { case invalid(String) }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
typealias AudioDeviceID = UInt32
typealias AudioObjectID = UInt32
typealias AudioUnit = Int
typealias OSStatus = Int32
let noErr: OSStatus = 0
let kAudioObjectUnknown: UInt32 = 0
let kAudioObjectSystemObject: UInt32 = 1
let kAudioHardwarePropertyDefaultInputDevice: UInt32 = 4
let kAudioHardwarePropertyDefaultOutputDevice: UInt32 = 5
@MainActor var defaultInput: UInt32 = 30
@MainActor var defaultOutput: UInt32 = 10
@MainActor func AudioObjectGetPropertyData(_ object: UInt32, _ address: inout AudioObjectPropertyAddress, _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ bytes: inout UInt32, _ value: inout UInt32) -> OSStatus {
    value = address.mSelector == kAudioHardwarePropertyDefaultInputDevice ? defaultInput : defaultOutput
    return noErr
}
let kAudioOutputUnitProperty_CurrentDevice: UInt32 = 1
let kAudioUnitScope_Global: UInt32 = 0
let kAudioObjectPropertyScopeGlobal: UInt32 = 0
let kAudioObjectPropertyElementMain: UInt32 = 0
let kAudioDevicePropertyNominalSampleRate: UInt32 = 2
let kAudioDevicePropertyBufferFrameSize: UInt32 = 3
struct AudioObjectPropertyAddress {
    var mSelector: UInt32
    var mScope: UInt32
    var mElement: UInt32
}
struct OutputDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var channels: Int
    var hardwareID: UInt32
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes = 0
    func set(_ value: Any?, forKey key: String) { writes += 1; values[key] = value }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
}
@MainActor var actualDevice: AudioDeviceID = 10
@MainActor var deviceSetResult: OSStatus = 0
@MainActor var deviceReadResult: OSStatus = 0
@MainActor var deviceReadSize = UInt32(MemoryLayout<AudioDeviceID>.size)
@MainActor var acceptsDeviceChanges = true
@MainActor var deviceSetCalls = 0
@MainActor var hardwareSetCalls = 0
@MainActor func AudioUnitSetProperty(_ unit: Int, _ property: UInt32, _ scope: UInt32, _ element: UInt32, _ selected: inout UInt32, _ size: UInt32) -> OSStatus {
    deviceSetCalls += 1
    if deviceSetResult == noErr && acceptsDeviceChanges { actualDevice = selected }
    return deviceSetResult
}
@MainActor func AudioUnitGetProperty(_ unit: Int, _ property: UInt32, _ scope: UInt32, _ element: UInt32, _ selected: inout UInt32, _ size: inout UInt32) -> OSStatus {
    selected = actualDevice; size = deviceReadSize
    return deviceReadResult
}
@MainActor func AudioObjectSetPropertyData<T>(_ device: UInt32, _ address: inout AudioObjectPropertyAddress, _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?, _ bytes: UInt32, _ value: inout T) -> OSStatus {
    hardwareSetCalls += 1
    return noErr
}
@MainActor final class OutputNode { var audioUnit: AudioUnit? = 1 }
@MainActor final class MixerNode { var outputVolume: Float = 1 }
@MainActor final class OutputEngine {
    var outputNode = OutputNode()
    var mainMixerNode = MixerNode()
    var isRunning = true
    var stops = 0
    var starts = 0
    var prepares = 0
    var deviceAfterPrepare: AudioDeviceID?
    var deviceAfterStart: AudioDeviceID?
    var volumeWhenStarted: Float?
    var startFailure = false
    func stop() { isRunning = false; stops += 1 }
    func prepare() {
        prepares += 1
        if let deviceAfterPrepare { actualDevice = deviceAfterPrepare }
    }
    func start() throws {
        starts += 1; volumeWhenStarted = mainMixerNode.outputVolume
        if let deviceAfterStart { actualDevice = deviceAfterStart }
        if startFailure { throw ProjectError.invalid("Engine start failed") }
        isRunning = true
    }
}
@MainActor final class AudioOutputBindingHarness {
    static var shared = AudioOutputBindingHarness()
    static let systemDefaultUID = "catlive.system-default"
    var followsSystemInput = false, followsSystemOutput = false
    var defaultRefreshPending = false
    var usesSystemLoopback = false
    var loopback: AnyObject?
    func refresh() { refreshSystemDefaults() }
    let engine = OutputEngine()
    var devices = [OutputDevice(id: "speakers", name: "Speakers", channels: 2, hardwareID: 10),
                   OutputDevice(id: "interface", name: "Interface", channels: 4, hardwareID: 20)]
    var inputDevices = [OutputDevice(id: "microphone", name: "Microphone", channels: 1, hardwareID: 30)]
    var selectedUID = "speakers"
    var inputUID = ""
    var inputDevice: OutputDevice? { inputDevices.first { $0.id == inputUID } }
    var configuredUID: String? = "speakers"
    var configuredHardwareID: UInt32? = 10
    var configuredInputHardwareID: UInt32?
    var channels = 2
    var error = ""
    var sampleRate = 48000.0
    var sampleRateChoices = [44100.0, 48000.0]
    var bufferFrames = 512
    var bufferChoices = [256, 512]
    var canChangeConfiguration: () -> Bool = { true }
    var deviceChanged: (() -> Void)?
    var inputDeviceChanged: (() -> Void)?
    /* OUTPUT_BINDING_PROPERTY */
    var observerFailure = false
    func observeOutputDevice(_ unit: AudioUnit) throws {
        if observerFailure { throw ProjectError.invalid("Unable to observe output route") }
    }
    func refreshSampleRate() {}
    func refreshBuffer() {}
    // The runner inserts the actual output selection/recovery implementation.
    /* OUTPUT_BINDING_METHODS */
}
typealias AudioDeviceSettings = AudioOutputBindingHarness
@MainActor final class OutputStartupHarness {
    let engine = AudioDeviceSettings.shared.engine
    var usesSelectedHardware = true
    var auxiliarySelectedHardware = false
    var mobileOutput: OutputEngine?
    var outputAllowed = true
    var licenseAllowed = true
    /* OUTPUT_STARTUP_METHODS */
}

@MainActor func resetHAL() {
    defaultInput = 30; defaultOutput = 10
    actualDevice = 10; deviceSetResult = 0; deviceReadResult = 0
    deviceReadSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    acceptsDeviceChanges = true; deviceSetCalls = 0; hardwareSetCalls = 0
    UserDefaults.standard.values = [:]; UserDefaults.standard.writes = 0
}
@MainActor func rejected(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("An invalid output binding was accepted") }
    catch {}
}
@MainActor func runAudioOutputBindingTests() throws {
    resetHAL()
    let followed = AudioOutputBindingHarness()
    followed.select(AudioOutputBindingHarness.systemDefaultUID)
    followed.selectInput(AudioOutputBindingHarness.systemDefaultUID)
    precondition(followed.followsSystemInput && followed.followsSystemOutput && followed.inputUID == "microphone")
    defaultOutput = 20; followed.refresh()
    precondition(followed.selectedUID == "interface" && actualDevice == 20 && followed.channels == 4)
    let changes = deviceSetCalls; followed.refresh()
    precondition(deviceSetCalls == changes, "Unchanged default must not restart audio")
    followed.select("speakers"); defaultOutput = 20; followed.refresh()
    precondition(!followed.followsSystemOutput && followed.selectedUID == "speakers" && actualDevice == 10)
    followed.select(AudioOutputBindingHarness.systemDefaultUID); followed.canChangeConfiguration = { false }
    defaultOutput = 10; followed.refresh()
    precondition(followed.selectedUID == "interface", "Recording route changed before it was allowed")
    followed.canChangeConfiguration = { true }; followed.refresh()
    precondition(followed.selectedUID == "speakers")
    followed.selectInput(""); defaultInput = 30; followed.refresh()
    precondition(!followed.followsSystemInput && followed.inputUID.isEmpty)
    precondition(UserDefaults.standard.values["catlive.followSystemOutput"] as? Bool == true)
    print("SYSTEM_DEFAULTS_FOLLOW_HAL_AND_PRESERVE_EXPLICIT_SELECTION_RECORDING_AND_PERSISTENCE_OK")
    resetHAL()
    let locked = AudioOutputBindingHarness()
    locked.canChangeConfiguration = { false }
    var callbacks = 0
    locked.deviceChanged = { callbacks += 1 }
    locked.inputDeviceChanged = { callbacks += 1 }
    locked.select("interface")
    locked.select("none")
    locked.selectInput("microphone")
    locked.setSampleRate(44100)
    locked.setBuffer(256)
    precondition(locked.selectedUID == "speakers" && locked.inputUID.isEmpty)
    precondition(locked.engine.isRunning && locked.engine.stops == 0)
    precondition(deviceSetCalls == 0 && hardwareSetCalls == 0 && callbacks == 0)
    precondition(UserDefaults.standard.writes == 0)
    precondition(!locked.error.isEmpty, "Transport lock must explain why the request was refused")
    print("TRANSPORT_LOCK_REJECTS_OUTPUT_NONE_INPUT_RATE_BUFFER_WITHOUT_SIDE_EFFECTS_OK")

    // A system default change is NOT a user request. Recover the saved physical
    // output even while the transport prevents the user choosing another one.
    actualDevice = 20
    try locked.requireSelectedOutput()
    precondition(actualDevice == 10 && locked.selectedUID == "speakers")
    precondition(deviceSetCalls == 1, "Recovery must bypass only the UI configuration lock")
    print("LOCKED_TRANSPORT_RECOVERS_SELECTED_UID_AFTER_LATE_ROUTE_DRIFT_OK")

    resetHAL()
    let notified = AudioOutputBindingHarness()
    var recoveries = 0
    notified.deviceChanged = { recoveries += 1 }
    notified.outputDeviceDidChange()
    precondition(recoveries == 0 && notified.engine.isRunning, "An unchanged route must not restart audio")
    actualDevice = 20
    notified.outputDeviceDidChange()
    precondition(!notified.engine.isRunning && notified.engine.mainMixerNode.outputVolume == 0)
    precondition(recoveries == 1 && notified.selectedUID == "speakers", "Late AU route notification must stop unselected output and request recovery")
    rejected { try notified.validateOutputBinding() }
    try notified.requireSelectedOutput()
    try notified.validateOutputBinding()
    print("LATE_ROUTE_NOTIFICATION_SILENCES_UNSELECTED_OUTPUT_BEFORE_RECOVERY_OK")

    resetHAL()
    let same = AudioOutputBindingHarness()
    same.select("speakers")
    precondition(same.engine.stops == 0 && deviceSetCalls == 0, "Reselecting the verified hardware must preserve playback")

    resetHAL()
    let output = AudioOutputBindingHarness()
    output.select("interface")
    precondition(output.selectedUID == "interface" && actualDevice == 20 && output.channels == 4)
    precondition(output.configuredHardwareID == 20 && UserDefaults.standard.values["jaras.audioOutputUID"] as? String == "interface")
    print("EXPLICIT_STOPPED_SELECTION_PUBLISHES_CONFIRMED_PHYSICAL_OUTPUT_OK")

    resetHAL()
    let ignored = AudioOutputBindingHarness()
    acceptsDeviceChanges = false
    ignored.select("interface")
    precondition(ignored.selectedUID == "speakers", "SetProperty success without a matching readback must not publish the target")
    precondition(!ignored.engine.isRunning && !ignored.error.isEmpty)
    precondition(UserDefaults.standard.values["jaras.audioOutputUID"] == nil)

    resetHAL()
    let unobserved = AudioOutputBindingHarness()
    unobserved.observerFailure = true
    unobserved.select("interface")
    precondition(!unobserved.engine.isRunning && unobserved.engine.mainMixerNode.outputVolume == 0)
    precondition(unobserved.selectedUID == "speakers")
    precondition(deviceSetCalls == 0, "A failed route observer must prevent changing the output")

    resetHAL()
    let denied = AudioOutputBindingHarness()
    actualDevice = 20; deviceSetResult = -50
    rejected { try denied.requireSelectedOutput() }
    precondition(!denied.engine.isRunning && denied.engine.mainMixerNode.outputVolume == 0)
    precondition(denied.selectedUID == "speakers", "A failed recovery must preserve the user's selected UID")

    resetHAL()
    let drifted = AudioOutputBindingHarness()
    actualDevice = 20; acceptsDeviceChanges = false
    rejected { try drifted.requireSelectedOutput() }
    precondition(!drifted.engine.isRunning && drifted.engine.mainMixerNode.outputVolume == 0)

    resetHAL()
    let unreadable = AudioOutputBindingHarness()
    deviceReadResult = -50
    rejected { try unreadable.requireSelectedOutput() }
    precondition(!unreadable.engine.isRunning && unreadable.engine.mainMixerNode.outputVolume == 0)

    resetHAL()
    let truncated = AudioOutputBindingHarness()
    deviceReadSize = 0
    rejected { try truncated.requireSelectedOutput() }
    precondition(!truncated.engine.isRunning && truncated.engine.mainMixerNode.outputVolume == 0)
    print("OUTPUT_SET_READBACK_AND_MALFORMED_ROUTE_FAILURES_STAY_SILENT_OK")

    resetHAL()
    let missing = AudioOutputBindingHarness()
    missing.devices.removeAll { $0.id == "speakers" }; actualDevice = 20
    rejected { try missing.requireSelectedOutput() }
    precondition(missing.selectedUID == "speakers" && !missing.engine.isRunning)
    precondition(missing.engine.mainMixerNode.outputVolume == 0 && deviceSetCalls == 0)

    resetHAL()
    let none = AudioOutputBindingHarness()
    none.select("none")
    try none.requireSelectedOutput()
    precondition(none.selectedUID == "none" && none.channels == 0 && !none.engine.isRunning)
    precondition(none.engine.mainMixerNode.outputVolume == 0 && deviceSetCalls == 0)
    print("DISCONNECTED_SELECTION_AND_NONE_NEVER_FALL_BACK_TO_SYSTEM_DEFAULT_OK")

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let started = OutputStartupHarness()
    started.engine.isRunning = false
    try started.startEngineIfNeeded()
    precondition(started.engine.isRunning && started.engine.volumeWhenStarted == 0 && started.engine.mainMixerNode.outputVolume == 1)

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let runningDrift = OutputStartupHarness()
    actualDevice = 20
    try runningDrift.startEngineIfNeeded()
    precondition(actualDevice == 10, "A running engine must restore its selected output")

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let prepareDrift = OutputStartupHarness()
    prepareDrift.engine.isRunning = false; prepareDrift.engine.deviceAfterPrepare = 20
    try prepareDrift.startEngineIfNeeded()
    precondition(actualDevice == 10 && prepareDrift.engine.starts == 1 && prepareDrift.engine.isRunning)

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let startDrift = OutputStartupHarness()
    startDrift.engine.isRunning = false; startDrift.engine.deviceAfterStart = 20
    try startDrift.startEngineIfNeeded()
    precondition(startDrift.engine.starts == 1 && startDrift.engine.volumeWhenStarted == 0)
    precondition(actualDevice == 10, "Start must recover the selected hardware before unmuting")

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let startFailed = OutputStartupHarness()
    startFailed.engine.isRunning = false; startFailed.engine.startFailure = true
    rejected { try startFailed.startEngineIfNeeded() }
    precondition(!startFailed.engine.isRunning && startFailed.engine.mainMixerNode.outputVolume == 0)

    resetHAL()
    AudioDeviceSettings.shared = AudioOutputBindingHarness()
    let unauthorized = OutputStartupHarness()
    unauthorized.engine.isRunning = false; unauthorized.licenseAllowed = false
    try unauthorized.startEngineIfNeeded()
    precondition(unauthorized.engine.isRunning && unauthorized.engine.mainMixerNode.outputVolume == 0)
    actualDevice = 20
    unauthorized.setLicenseAllowed(true)
    precondition(unauthorized.engine.mainMixerNode.outputVolume == 0, "License updates must not unmute an unselected device")
    actualDevice = 10
    unauthorized.setLicenseAllowed(true)
    precondition(unauthorized.engine.mainMixerNode.outputVolume == 1)
    print("ENGINE_PREPARE_AND_START_VALIDATE_HARDWARE_BEFORE_UNMUTING_OK")
}
@main struct AudioOutputBindingTests {
    @MainActor static func main() throws { try runAudioOutputBindingTests() }
}
