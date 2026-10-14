import Foundation
import Combine

public struct NativePurchaseProduct: Equatable, Sendable {
    public let displayPrice: String
    public init(displayPrice: String) { self.displayPrice = displayPrice }
}
public enum NativePurchaseResult: Sendable { case purchased, pending, cancelled }

/// The adapter only returns purchased after verifying Apple's signed transaction.
@MainActor public protocol NativePurchaseClient: AnyObject {
    var updates: AsyncStream<Void> { get }
    func hasEntitlement() async -> Bool
    func product() async throws -> NativePurchaseProduct
    func purchase() async throws -> NativePurchaseResult
    func restore() async throws
}

@MainActor public final class NativePurchaseStore: ObservableObject {
    public static let productID = "com.hookdeveloper.jaraslive.ipad.native"
    @Published public private(set) var unlocked = false
    @Published public private(set) var checked = false
    @Published public private(set) var product: NativePurchaseProduct?
    @Published public private(set) var loading = false
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    private let client: any NativePurchaseClient
    private var listener: Task<Void, Never>?
    private var refreshGeneration = 0

    public init(client: any NativePurchaseClient) {
        self.client = client
        let stream = client.updates
        listener = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    deinit { listener?.cancel() }

    /// StoreKit maintains verified local transactions, so this does not require
    /// an online login or AppStore.sync every time a purchased workspace opens.
    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let entitled = await client.hasEntitlement()
        guard generation == refreshGeneration else { return }
        unlocked = entitled; checked = true
    }
    public func load() async {
        guard !loading else { return }
        loading = true; notice = ""
        defer { loading = false }
        await refresh()
        do { product = try await client.product() }
        catch { product = nil; notice = "The purchase is unavailable right now. Check your connection and try again." }
    }
    public func buy() async {
        guard !busy, product != nil, !unlocked else { return }
        busy = true; notice = ""
        defer { busy = false }
        do {
            switch try await client.purchase() {
            case .purchased:
                refreshGeneration += 1 // Ignore an earlier entitlement enumeration.
                unlocked = true; checked = true
            case .pending: notice = "Purchase awaiting approval. Access will unlock when Apple confirms it."
            case .cancelled: break
            }
        } catch { notice = "The purchase could not be completed. Please try again." }
    }
    public func restore() async {
        guard !busy else { return }
        busy = true; notice = ""
        defer { busy = false }
        do {
            try await client.restore()
            await refresh()
            notice = unlocked ? "Purchase restored." : "No purchase was found for this Apple Account."
        } catch { notice = "Purchases could not be restored. Check your connection and try again." }
    }
}
