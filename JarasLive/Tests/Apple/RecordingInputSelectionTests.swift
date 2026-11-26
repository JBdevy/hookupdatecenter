import Foundation

enum ProjectError: Error { case invalid(String) }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
struct InputDevice { var hardwareID: UInt32 }
@MainActor final class AudioDeviceSettings {
    static let shared = AudioDeviceSettings()
    var inputDevice: InputDevice?
    var inputUID = ""
    var bufferFrames = 128
    var usesSystemLoopback = false
    var loopback: AnyObject?
    func resolveInputDevice() throws -> InputDevice? { inputDevice }
}
@MainActor final class MacSystemLoopback {
    var device: UInt32 = 0
    func start() throws {}
}
@MainActor final class InputHardware {
    var actualDevice: UInt32 = 0
    var readable = true, acceptsDeviceChanges = true, prepareFails = false
    var requestedFrames: UInt32 = 0
    var device: UInt32 { readable ? actualDevice : 0 }
    var running = false
    var starts = 0, stops = 0, preparations = 0
    func prepare(withDevice device: UInt32, bufferFrames: UInt32) throws {
        preparations += 1; requestedFrames = bufferFrames
        if prepareFails { throw ProjectError.invalid("Input unavailable") }
        if acceptsDeviceChanges { actualDevice = device }
    }
    func start() throws { starts += 1; running = true }
    func stop() { stops += 1; running = false; actualDevice = 0 }
}
@MainActor final class RecordingInputHarness {
    let desktopInput = InputHardware()
    var systemCapture: AnyObject?
    var recording = false, busy = false
    var writer: Int?
    var configuredInput: UInt32 = 0
    func releaseInput() { desktopInput.stop() }
    /* RECORDING_INPUT_METHODS */
}
@MainActor func rejected(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Unsafe input request was accepted") }
    catch {}
}
@main struct RecordingInputTests {
    @MainActor static func main() throws {
        let audio = AudioDeviceSettings.shared
        let missing = RecordingInputHarness()
        rejected { try missing.configureInput() }
        precondition(missing.desktopInput.preparations == 0, "None cannot open the system default mic")
        audio.inputDevice = InputDevice(hardwareID: 10); audio.inputUID = "input-A"
        let input = RecordingInputHarness()
        try input.configureInput(); try input.startInputEngine()
        precondition(input.configuredInput == 10 && input.desktopInput.starts == 1)
        precondition(input.desktopInput.requestedFrames == 128, "Capture must use the selected output buffer instead of a batched tap")
        try input.configureInput()
        precondition(input.desktopInput.preparations == 1, "Reconciliation cannot restart an unchanged input")
        try input.requireConfiguredInput(expectedUID: "input-A", expectedDevice: 10)
        audio.inputUID = "input-B"
        rejected { try input.requireConfiguredInput(expectedUID: "input-A", expectedDevice: 10) }
        audio.inputUID = "input-A"; audio.inputDevice = InputDevice(hardwareID: 11)
        rejected { try input.startInputEngine() }
        precondition(input.desktopInput.starts == 1, "Async preparation cannot start an outdated device")
        audio.inputDevice = InputDevice(hardwareID: 10)
        input.desktopInput.actualDevice = 48
        rejected { try input.startInputEngine() }
        try input.configureInput(); try input.startInputEngine()
        precondition(input.desktopInput.preparations == 2 && input.desktopInput.device == 10)
        input.recording = true; input.desktopInput.actualDevice = 48
        rejected { try input.configureInput() }
        precondition(input.desktopInput.preparations == 2, "A live take must reject route drift")
        let busy = RecordingInputHarness(); busy.busy = true
        rejected { try busy.configureInput() }
        try busy.configureInput(allowCaptureSetup: true)
        busy.recording = true
        try busy.configureInput()
        precondition(busy.desktopInput.preparations == 1)
        for failure in 0..<3 {
            let broken = RecordingInputHarness()
            if failure == 0 { broken.desktopInput.prepareFails = true }
            if failure == 1 { broken.desktopInput.acceptsDeviceChanges = false }
            if failure == 2 { broken.desktopInput.readable = false }
            rejected { try broken.configureInput() }
            precondition(broken.configuredInput == 0)
            rejected { try broken.startInputEngine() }
            precondition(broken.desktopInput.starts == 0, "An unavailable or unverified input cannot start")
        }
        print("RECORDING_INPUT_BUFFER_SELECTION_FAILURE_AND_ASYNC_REVALIDATION_OK")
    }
}
