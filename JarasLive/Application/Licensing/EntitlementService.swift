import Foundation
public struct EntitlementService: Sendable {
    public let backend: any BackendClient
    public init(backend: any BackendClient) { self.backend = backend }
    public func validate(_ session: AuthSession, feature: String) async throws -> Entitlement {
        let result = try await backend.entitlement(session)
        guard result.permits(feature) else { throw BackendFailure.expired }; return result
    }
    public func permitsOffline(_ cache: SessionCache, installationId: UUID, feature: String, date: Date = Date()) -> Bool {
        cache.login.device.installationId == installationId && cache.login.device.status == .active && cache.login.entitlement.permits(feature, at: date) && cache.login.entitlement.offlineValidUntil > date && date >= cache.validatedAt.addingTimeInterval(-300)
    }
}
