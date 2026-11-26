import Foundation

/// The extracted production helper uses a controlled monotonic clock while
/// retaining real, cancellable Task.sleep suspension. CI scheduling delays
/// must not change the deadline arithmetic being tested.
enum AppStartupTestClock {
    private static let lock = NSLock()
    private static var instant: TimeInterval = 100
    private static var requests: [UInt64] = []
    static var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return instant }
        set { lock.lock(); defer { lock.unlock() }; instant = newValue }
    }
    static var sleeps: [UInt64] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }; requests.removeAll()
    }
    private static func record(_ nanoseconds: UInt64) {
        lock.lock(); defer { lock.unlock() }; requests.append(nanoseconds)
    }
    static func sleep(nanoseconds: UInt64) async throws {
        record(nanoseconds)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
    @MainActor static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(condition(), message)
    }
}
