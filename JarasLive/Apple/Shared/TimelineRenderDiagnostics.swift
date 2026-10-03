import Foundation

/// Opt-in counters only. Canvas dimensions estimate backing area; Metal records
/// the actual drawable dimensions and GPU/presentation timestamps separately.
enum TimelineRenderDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["CATLIVE_PROFILE_RENDER"] == "1"
    private static let lock = NSLock()
    private struct Measurements {
        var count = 0
        var lastWidth = 0.0, lastHeight = 0.0
        var totalPixels = 0.0, maxPixels = 0.0
        var milliseconds: [Double] = []
        var gaps: [Double] = []
    }
    private static var values: [String: Measurements] = [:]
    private static var previousEvent: [String: Double] = [:]
    private static var reportedAt = ProcessInfo.processInfo.systemUptime
    static func record(_ role: String, width: Double, height: Double, scale: Double = 1,
                       milliseconds: Double, eventTime: Double? = nil) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var value = values[role] ?? Measurements()
        value.count += 1; value.lastWidth = width; value.lastHeight = height
        let pixels = max(0, width) * max(0, height) * scale * scale
        value.totalPixels += pixels; value.maxPixels = max(value.maxPixels, pixels)
        if value.milliseconds.count < 1024, milliseconds.isFinite { value.milliseconds.append(milliseconds) }
        if let eventTime, eventTime > 0 {
            if let previous = previousEvent[role], eventTime > previous, value.gaps.count < 1024 {
                value.gaps.append((eventTime - previous) * 1000)
            }
            previousEvent[role] = max(eventTime, previousEvent[role] ?? 0)
        }
        values[role] = value
        guard now - reportedAt >= 1 else { lock.unlock(); return }
        let elapsed = now - reportedAt, snapshot = values
        reportedAt = now; values.removeAll(keepingCapacity: true)
        lock.unlock()
        for (name, value) in snapshot.sorted(by: { $0.key < $1.key }) {
            let times = value.milliseconds.sorted()
            let mean = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count - 1) * 0.95))]
            let gap = value.gaps.isEmpty ? 0 : value.gaps.reduce(0, +) / Double(value.gaps.count)
            let line = String(format: "[render-profile] role=%@ seconds=%.3f count=%d size=%.0fx%.0f meanMP=%.3f maxMP=%.3f MPperSecond=%.3f meanMs=%.3f p95Ms=%.3f maxMs=%.3f meanGapMs=%.3f maxGapMs=%.3f\n",
                name, elapsed, value.count, value.lastWidth, value.lastHeight,
                value.totalPixels / Double(value.count) / 1_000_000, value.maxPixels / 1_000_000,
                value.totalPixels / elapsed / 1_000_000, mean, p95, times.last ?? 0, gap, value.gaps.max() ?? 0)
            fputs(line, stderr)
        }
    }
}
