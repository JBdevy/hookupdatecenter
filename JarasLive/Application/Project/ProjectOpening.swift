import Foundation

/// Cancellation crosses detached audio readers and dispatch-based peak workers.
public final class ProjectOpeningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
public enum ProjectOpeningWork {
    public static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}
public enum RecentProjectEntry {
    public static func isMissing(_ url: URL) -> Bool {
        do { _ = try url.resourceValues(forKeys: [.isRegularFileKey]); return false }
        catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
    }
    public static func matches(_ url: URL, query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return terms.allSatisfy { url.path.localizedStandardContains($0) }
    }
}
