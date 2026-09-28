import Foundation

public enum TeleprompterTimerMode: String, Codable, Sendable {
    case progressive, countdown
}

/// Independent stage timer. Elapsed time comes from a monotonic clock, so
/// playback seeks and wall-clock corrections never change the count.
public struct TeleprompterTimer: Equatable, Sendable {
    public static let maximumTargetSeconds = 99 * 3600 + 59 * 60 + 59
    public private(set) var mode: TeleprompterTimerMode
    public private(set) var targetSeconds: Int
    public private(set) var initAutoEnabled: Bool
    public private(set) var running = false
    private var startedAt: Double?
    private var baseSeconds = 0.0
    private var observedPlayback: PlaybackIdentity?

    private struct PlaybackIdentity: Equatable, Sendable {
        var project: UUID
        var region: UUID?
    }

    public init(mode: TeleprompterTimerMode = .progressive, targetSeconds: Int = 0,
                initAutoEnabled: Bool = false) {
        self.mode = mode
        self.targetSeconds = Self.clamp(targetSeconds)
        self.initAutoEnabled = initAutoEnabled
        baseSeconds = mode == .countdown ? Double(self.targetSeconds) : 0
    }

    public func displaySeconds(at monotonic: Double) -> Double {
        guard running, let startedAt, monotonic.isFinite else { return baseSeconds }
        let elapsed = max(0, monotonic - startedAt)
        return mode == .countdown ? baseSeconds - elapsed : baseSeconds + elapsed
    }

    public func isExpired(at monotonic: Double) -> Bool {
        running && mode == .countdown && displaySeconds(at: monotonic) <= 0
    }

    public mutating func start(at monotonic: Double) {
        guard !running, monotonic.isFinite else { return }
        baseSeconds = mode == .countdown ? Double(targetSeconds) : 0
        startedAt = monotonic
        running = true
    }

    public mutating func stopAndReset() {
        running = false
        startedAt = nil
        baseSeconds = 0
    }

    public mutating func setMode(_ mode: TeleprompterTimerMode, at monotonic: Double) {
        guard self.mode != mode, monotonic.isFinite else { return }
        self.mode = mode
        baseSeconds = mode == .countdown ? Double(targetSeconds) : 0
        startedAt = running ? monotonic : nil
    }

    public mutating func setTarget(seconds: Int, at monotonic: Double) {
        guard monotonic.isFinite else { return }
        targetSeconds = Self.clamp(seconds)
        if mode == .countdown {
            baseSeconds = Double(targetSeconds)
            startedAt = running ? monotonic : nil
        }
    }

    public mutating func setInitAutoEnabled(_ enabled: Bool) { initAutoEnabled = enabled }

    /// INIT AUTO reacts to playback edges, not periodic position snapshots.
    /// Pause preserves the edge; a complete stop permits the next performance.
    public mutating func observePlayback(project: UUID, region: UUID?, playing: Bool,
                                         paused: Bool, at monotonic: Double) {
        guard monotonic.isFinite else { return }
        guard playing else {
            if !paused { observedPlayback = nil }
            return
        }
        let identity = PlaybackIdentity(project: project, region: region)
        guard observedPlayback != identity else { return }
        observedPlayback = identity
        if initAutoEnabled && !running { start(at: monotonic) }
    }

    /// HH:MM:SS input uses the same component limits as the VS timer.
    public static func targetSeconds(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) else { return nil }
        return min(99, hours) * 3600 + min(59, minutes) * 60 + min(59, seconds)
    }

    public static func formatted(_ seconds: Int, spaced: Bool = false) -> String {
        let amount = seconds == Int.min ? Int.max : abs(seconds)
        let separator = spaced ? " : " : ":"
        return (seconds < 0 ? "−" : "") + String(format: "%02d%@%02d%@%02d", amount / 3600,
                   separator, amount / 60 % 60, separator, amount % 60)
    }

    private static func clamp(_ seconds: Int) -> Int { min(maximumTargetSeconds, max(0, seconds)) }
}
