import Foundation

enum ProjectError: Error { case invalid(String) }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
struct InputDevice { var hardwareID: UInt32 }
typealias AudioUnit = Int
let noErr: Int32 = 0
let kAudioOutputUnitProperty_CurrentDevice: UInt32 = 1
let kAudioUnitScope_Global: UInt32 = 0
@MainActor var deviceSetResult: Int32 = 0
@MainActor var deviceSetCalls = 0
@MainActor var actualDevice: UInt32 = 3
@MainActor var deviceReadResult: Int32 = 0
@MainActor var acceptsDeviceChanges = true
@MainActor func AudioUnitSetProperty(_ unit: Int, _ property: UInt32, _ scope: UInt32, _ element: UInt32, _ selected: inout UInt32, _ size: UInt32) -> Int32 {
    deviceSetCalls += 1
    if deviceSetResult == noErr && acceptsDeviceChanges { actualDevice = selected }
    return deviceSetResult
}
@MainActor func AudioUnitGetProperty(_ unit: Int, _ property: UInt32, _ scope: UInt32, _ element: UInt32, _ selected: inout UInt32, _ size: inout UInt32) -> Int32 {
    selected = actualDevice
    return deviceReadResult
}
@MainActor final class AudioDeviceSettings {
    static let shared = AudioDeviceSettings()
    var inputDevice: InputDevice?
    var inputUID = ""

}
@MainActor final class InputNode { var audioUnit: Int? = 1 }
@MainActor final class CaptureEngine {
    let node = InputNode()
    var inputNodeReads = 0
    var inputNode: InputNode { inputNodeReads += 1; return node }
    var isRunning = false
    var starts = 0
    var stops = 0
    var startFailure = false
    func prepare() {}
    func start() throws {
        if startFailure { throw ProjectError.invalid("Start failed") }
        isRunning = true; starts += 1
    }
    func stop() { isRunning = false; stops += 1 }
}
@MainActor final class RecordingInputHarness {
    let captureEngine = CaptureEngine()
    var recording = false
    var busy = false
    var writer: Int?
    var configuredInput: UInt32 = 0
    func releaseInput() { captureEngine.stop() }
    // The script inserts the production configuration/validation/start methods.
    /* RECORDING_INPUT_METHODS */
}

@MainActor func rejected(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Unsafe input request was accepted") }
    catch {}
}
@MainActor func resetInput() {
    let audio = AudioDeviceSettings.shared
    audio.inputDevice = InputDevice(hardwareID: 10); audio.inputUID = "input-A"
    deviceSetResult = 0; deviceSetCalls = 0
    actualDevice = 3; deviceReadResult = 0; acceptsDeviceChanges = true
}
@MainActor func runRecordingInputTests() throws {
    let audio = AudioDeviceSettings.shared
    resetInput()
    let missing = RecordingInputHarness()
    audio.inputDevice = nil
    rejected { try missing.configureInput() }
    precondition(missing.captureEngine.inputNodeReads == 0, "None must not instantiate the default input")

    resetInput()
    let failed = RecordingInputHarness()
    failed.configuredInput = 3; failed.captureEngine.isRunning = true
    deviceSetResult = -50
    rejected { try failed.configureInput() }
    precondition(!failed.captureEngine.isRunning && failed.configuredInput == 0)
    rejected { try failed.startInputEngine() }
    precondition(failed.captureEngine.starts == 0, "A rejected CurrentDevice must never start the previous input")

    resetInput()
    let input = RecordingInputHarness()
    try input.configureInput()
    try input.startInputEngine()
    precondition(input.configuredInput == 10 && input.captureEngine.starts == 1)
    try input.configureInput()
    precondition(deviceSetCalls == 1, "An already-bound input must not be rebound")
    try input.requireConfiguredInput(expectedUID: "input-A", expectedDevice: 10)
    audio.inputUID = "input-B"
    rejected { try input.requireConfiguredInput(expectedUID: "input-A", expectedDevice: 10) }
    audio.inputUID = "input-A"; audio.inputDevice = InputDevice(hardwareID: 11)
    rejected { try input.requireConfiguredInput(expectedUID: "input-A", expectedDevice: 10) }
    input.captureEngine.stop()
    rejected { try input.startInputEngine() }
    precondition(input.captureEngine.starts == 1, "A device changed while writer preparation yielded must not restart the old binding")

    resetInput()
    let unavailable = RecordingInputHarness()
    unavailable.captureEngine.node.audioUnit = nil
    rejected { try unavailable.configureInput() }
    precondition(unavailable.configuredInput == 0 && deviceSetCalls == 0)

    resetInput()
    let busy = RecordingInputHarness()
    busy.busy = true
    rejected { try busy.configureInput() }
    precondition(busy.captureEngine.inputNodeReads == 0)
    try busy.configureInput(allowCaptureSetup: true)
    busy.recording = true
    try busy.configureInput()
    precondition(deviceSetCalls == 1, "An active take can keep using its existing selected binding")

    resetInput()
    let drifted = RecordingInputHarness()
    try drifted.configureInput()
    actualDevice = 48
    rejected { try drifted.startInputEngine() }
    precondition(drifted.captureEngine.starts == 0, "Matching cached IDs must not allow a different actual AU device to start")
    try drifted.configureInput()
    precondition(deviceSetCalls == 2 && actualDevice == 10, "Configuration must rebind after HAL changes the actual device behind a matching cache")
    try drifted.startInputEngine()
    precondition(drifted.captureEngine.starts == 1)
    drifted.captureEngine.stop()
    actualDevice = 48; drifted.recording = true
    rejected { try drifted.configureInput() }
    precondition(deviceSetCalls == 2, "A live take must reject drift rather than silently switch hardware")
    drifted.recording = false; acceptsDeviceChanges = false
    rejected { try drifted.configureInput() }
    precondition(drifted.configuredInput == 0, "A setter success without matching hardware readback cannot publish a successful binding")
    rejected { try drifted.startInputEngine() }
    acceptsDeviceChanges = true; deviceReadResult = -50
    rejected { try drifted.configureInput() }
    precondition(drifted.captureEngine.starts == 1, "Unreadable CurrentDevice must fail closed")
    print("RECORDING_INPUT_SELECTION_FAILURE_AND_ASYNC_REVALIDATION_OK")
}

@main struct RecordingInputTests {
    @MainActor static func main() throws { try runRecordingInputTests() }
}
