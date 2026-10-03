import Foundation
/// Shared with offline workers; the live hardware gate is applied to the final
/// engine mixer, independently of every user-controlled track/master gain.
public final class AudioLicenseAccess: @unchecked Sendable {
    public static let shared = AudioLicenseAccess()
    private let lock = NSLock()
    private var permitted = true
    public var allowed: Bool { lock.lock(); defer { lock.unlock() }; return permitted }
    public func setAllowed(_ value: Bool) { lock.lock(); permitted = value; lock.unlock() }
    public func requireAccess() throws {
        guard allowed else { throw BackendFailure.expired }
    }
}
