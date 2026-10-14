import Foundation
enum MobileAudioSessionEvent { case interrupted, interruptionEnded, routeChanged(outputRemoved: Bool), mediaServicesReset }
enum JarasLocalization { static func string(_ text: String) -> String { text } }
enum Command { case stopAll }
@MainActor enum Events { static var values: [String] = [] }
@MainActor final class AudioDeviceSettings {
    static let shared = AudioDeviceSettings()
    var localSessionInterrupted = false, localSessionReconfiguring = false
    var inputDeviceChanged: (() -> Void)?
    var failActivation = false
    func beginLocalRouteChange() { localSessionReconfiguring = true; Events.values.append("gate") }
    func finishLocalRouteChange() { localSessionReconfiguring = false; Events.values.append("ungate") }
    func activateLocalSession() throws {
        Events.values.append("activate")
        if failActivation { throw NSError(domain: "Disconnected", code: 1) }
    }
    func deactivateLocalSession() throws { finishLocalRouteChange() }
}
@MainActor final class StemAudioPlayback {
    static let shared = StemAudioPlayback()
    var workerBusy = false
    var starts = 0
    func suspendDeviceSession() { Events.values.append("suspend") }
    func waitForSuspendedProcessors() async throws {
        while workerBusy { try await Task.sleep(nanoseconds: 5_000_000) }
    }
    func startDeviceSession() throws {
        precondition(!AudioDeviceSettings.shared.localSessionReconfiguring)
        precondition(!TrackRecording.shared.busy && !workerBusy)
        starts += 1; Events.values.append("start")
    }
}
@MainActor final class TrackRecording {
    static let shared = TrackRecording()
    var busy = false, available = true
    func setLocalAudioAvailable(_ value: Bool) {
        available = value; Events.values.append(value ? "record-on" : "record-off")
    }
    func finish() { }
    // PRODUCTION_FINISH_AND_WAIT
}
@MainActor final class ShowProbe {
    var playing = true, message = ""
    func send(_ command: Command) {
        precondition(AudioDeviceSettings.shared.localSessionReconfiguring, "Gate graph updates before Stop")
        playing = false; Events.values.append("stop")
    }
    func preparePlayback() { precondition(!playing, "Reconnect must not resume removed-device playback"); Events.values.append("prepare") }
}
@MainActor final class RecoveryProbe {
    var localPlaybackEnabled = true
    var localPlaybackTransition: UInt64 = 0, mobileRouteRevision: UInt64 = 0
    var mobileRouteRecovery: Task<Void, Never>?
    let show = ShowProbe()
    struct Documents { var ready = true }
    let documents = Documents()
    func event(_ event: MobileAudioSessionEvent) { handleMobileAudioEvent(event) }
    // PRODUCTION_RECOVERY_METHODS
}
@MainActor func verifyRecovery() async throws {
    let probe = RecoveryProbe(), audio = StemAudioPlayback.shared, recorder = TrackRecording.shared, settings = AudioDeviceSettings.shared
    settings.inputDeviceChanged = { Events.values.append("refresh-input") }
    recorder.busy = true; audio.workerBusy = true
    probe.event(.routeChanged(outputRemoved: true))
    precondition(Array(Events.values.prefix(4)) == ["gate", "suspend", "record-off", "stop"])
    precondition(!recorder.available && !probe.show.playing)
    // Recording finalization and CatStem must finish without blocking the actor.
    for _ in 0..<40 { try await Task.sleep(nanoseconds: 5_000_000) }
    precondition(audio.starts == 0)
    // Cancel recovery while it is waiting for a busy writer. Cancellation must
    // yield, rather than spinning forever on an immediately throwing sleep.
    for _ in 0..<6 { probe.event(.routeChanged(outputRemoved: false)) }
    try await Task.sleep(nanoseconds: 180_000_000)
    precondition(audio.starts == 0)
    recorder.busy = false
    try await Task.sleep(nanoseconds: 20_000_000)
    precondition(audio.starts == 0)
    audio.workerBusy = false
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 1 && recorder.available && !settings.localSessionReconfiguring)
    precondition(Array(Events.values.suffix(6)) == ["activate", "ungate", "start", "prepare", "refresh-input", "record-on"])
    for _ in 0..<12 { probe.event(.routeChanged(outputRemoved: false)) }
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 2, "Coalesce repeated USB notifications into one reconnection")
    probe.event(.routeChanged(outputRemoved: true))
    probe.localPlaybackTransition += 1; probe.localPlaybackEnabled = false
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 2 && !recorder.available, "Leaving Native cancels stale recovery")
    probe.localPlaybackEnabled = true
    settings.localSessionInterrupted = true
    probe.event(.interrupted)
    probe.event(.routeChanged(outputRemoved: false))
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 2, "Do not reopen interrupted hardware")
    settings.localSessionInterrupted = false
    probe.event(.interruptionEnded)
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 3 && recorder.available)
    settings.failActivation = true
    probe.event(.routeChanged(outputRemoved: true))
    await probe.mobileRouteRecovery?.value
    precondition(audio.starts == 3 && !recorder.available && !settings.localSessionReconfiguring && !probe.show.message.isEmpty)
    print("IPAD_USB_ROUTE_STOP_ORDER_ASYNC_RECORDING_WORKERS_COALESCING_INTERRUPTION_EXIT_AND_ERROR_OK")
}
Task { @MainActor in
    do { try await verifyRecovery(); exit(0) }
    catch { fatalError("\(error)") }
}
dispatchMain()
