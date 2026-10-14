import Foundation

@MainActor func verifyHardwareStop() async throws {
    var heartbeats = 0
    let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
            heartbeats += 1
            do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
        }
    }
    defer { heartbeat.cancel() }
    let blocked = DispatchSemaphore(value: 0)
    let pending = MobileAudioHardwareStop(settlingTime: 0) { blocked.wait() }
    var timedOut = false
    do { try await pending.wait(timeout: 0.15) }
    catch MobileAudioHardwareStop.Failure.timedOut { timedOut = true }
    precondition(timedOut && heartbeats > 10, "A hung HAL stop must leave the main actor responsive and report a bounded failure")
    blocked.signal()
    try await pending.wait(timeout: 1)

    let suspended = DispatchSemaphore(value: 0)
    let operation = MobileAudioHardwareStop(settlingTime: 0) { suspended.wait() }
    let cancelled = Task { try await operation.wait() }
    try await Task.sleep(nanoseconds: 30_000_000)
    cancelled.cancel()
    do { try await cancelled.value; preconditionFailure("A superseded route waiter must cancel") }
    catch is CancellationError { }
    suspended.signal()
    try await operation.wait()
    // Multiple route notifications share a single stop instead of touching
    // the same AVAudioEngine concurrently or stopping a rebuilt graph.
    let shared = MobileAudioHardwareStop(settlingTime: 0.03) { }
    for _ in 0..<12 { try await shared.wait() }
    print("IPAD_HAL_STOP_TIMEOUT_MAIN_ACTOR_HEARTBEATS_CANCELLATION_AND_SHARED_COMPLETION_OK")
}
Task { @MainActor in
    do { try await verifyHardwareStop(); exit(0) }
    catch { fatalError("\(error)") }
}
dispatchMain()
