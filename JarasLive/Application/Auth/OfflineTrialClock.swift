import Foundation
import Darwin

/// A Keychain checkpoint retains elapsed trial time across launches and reboots.
/// The server-signed expiry remains authoritative; this never extends a lease.
struct OfflineTrialClock: Codable {
    let account: UUID
    let installation: UUID
    let expiresAt: Date
    let trustedDate: Date
    let wallDate: Date
    let uptime: TimeInterval
    let boot: String
    static var bootID: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    func resume(account: UUID, installation: UUID, expiresAt: Date, wall: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, boot: String = Self.bootID) throws -> Date {
        guard self.account == account, self.installation == installation, abs(self.expiresAt.timeIntervalSince(expiresAt)) < 0.01 else { throw BackendFailure.invalidSession }
        guard wall >= wallDate.addingTimeInterval(-300) else { throw BackendFailure.clockChanged }
        let continuous = !boot.isEmpty && boot == self.boot ? max(0, uptime - self.uptime) : 0
        return trustedDate.addingTimeInterval(max(0, wall.timeIntervalSince(wallDate), continuous))
    }
}
