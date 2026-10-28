import Foundation
import Combine

public struct NativePurchaseProduct: Equatable, Sendable {
    public let displayPrice: String
    public init(displayPrice: String) { self.displayPrice = displayPrice }
}
public enum NativePurchaseResult: Sendable { case purchased, pending, cancelled }
public enum NativePurchasePrimaryAction: Equatable, Sendable { case openPurchased, continueTrial, startTrial, purchase }
public enum NativePurchaseFailure: Error { case productsUnavailable }
public struct NativeTrialEntitlement: Sendable {
    public let originalPurchaseDate: Date
    public let signedDate: Date
    public init(originalPurchaseDate: Date, signedDate: Date) {
        self.originalPurchaseDate = originalPurchaseDate; self.signedDate = signedDate
    }
}
/// The adapter only returns purchased after verifying Apple's signed transaction.
@MainActor public protocol NativePurchaseClient: AnyObject {
    var updates: AsyncStream<Void> { get }
    func hasEntitlement() async -> Bool
    func trialEntitlement() async -> NativeTrialEntitlement?
    func product() async throws -> NativePurchaseProduct
    func trialProduct() async throws -> NativePurchaseProduct
    func purchase() async throws -> NativePurchaseResult
    func beginTrial() async throws -> NativePurchaseResult
    func restore() async throws
}

@MainActor public final class NativePurchaseStore: ObservableObject {
    public static let productID = "com.hookdeveloper.jaraslive.ipad.native"
    public static let trialProductID = "com.hookdeveloper.jaraslive.ipad.native.trial7days"
    public static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
    @Published public private(set) var unlocked = false
    @Published public private(set) var canAccessNative = false
    @Published public private(set) var checked = false
    @Published public private(set) var product: NativePurchaseProduct?
    @Published public private(set) var trialProduct: NativePurchaseProduct?
    @Published public private(set) var trialExpiresAt: Date?
    @Published public private(set) var trialDaysRemaining = 0
    @Published public private(set) var loading = false
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    public var primaryAction: NativePurchasePrimaryAction {
        if unlocked { return .openPurchased }
        if canAccessNative { return .continueTrial }
        return trialExpiresAt == nil ? .startTrial : .purchase
    }
    public var primaryActionAvailable: Bool {
        guard !busy, checked else { return false }
        switch primaryAction {
        case .openPurchased, .continueTrial: return true
        case .startTrial: return !loading && trialProduct != nil && product != nil
        case .purchase: return !loading && product != nil
        }
    }
    /// A new customer activates only the zero-price trial product. The paid
    /// product is offered after the trial; neither flow auto-converts to it.
    public func activateNative() async -> Bool {
        guard primaryActionAvailable else { return false }
        switch primaryAction {
        case .startTrial: await startTrial()
        case .purchase: await buy()
        case .openPurchased, .continueTrial: break
        }
        return canAccessNative
    }
    private let client: any NativePurchaseClient
    private let secureStore: any SecureStore
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let boot: () -> String
    private var listener: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private static let trialClockID = UUID(uuidString: "664106E3-72DD-4355-A571-AD948D777BB5")!

    public init(client: any NativePurchaseClient, secureStore: any SecureStore = MemorySecureStore(),
                now: @escaping () -> Date = Date.init,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                boot: (() -> String)? = nil) {
        self.client = client; self.secureStore = secureStore; self.now = now; self.uptime = uptime; self.boot = boot ?? { OfflineTrialClock.bootID }
        let stream = client.updates
        listener = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    deinit { listener?.cancel(); expiryTask?.cancel() }

    /// Uses verified StoreKit transactions offline. Restoring cannot restart the trial.
    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let entitled = await client.hasEntitlement()
        let trial = await client.trialEntitlement()
        guard generation == refreshGeneration else { return }
        unlocked = entitled; checked = true
        expiryTask?.cancel(); expiryTask = nil
        trialExpiresAt = trial.map { $0.originalPurchaseDate.addingTimeInterval(Self.trialDuration) }
        trialDaysRemaining = 0
        var remaining = 0.0
        if let trial, let end = trialExpiresAt, !entitled {
            do {
                let wall = now(), uptime = uptime(), boot = boot()
                guard wall >= trial.signedDate.addingTimeInterval(-300) else { throw BackendFailure.clockChanged }
                var trusted = max(wall, trial.signedDate, trial.originalPurchaseDate)
                if let data = try secureStore.read("native-trial-clock") {
                    let clock = try JSONDecoder().decode(OfflineTrialClock.self, from: data)
                    if clock.expiresAt == end {
                        trusted = max(trusted, try clock.resume(account: Self.trialClockID, installation: Self.trialClockID,
                            expiresAt: end, wall: wall, uptime: uptime, boot: boot))
                    }
                }
                let checkpoint = OfflineTrialClock(account: Self.trialClockID, installation: Self.trialClockID,
                    expiresAt: end, trustedDate: trusted, wallDate: wall, uptime: uptime, boot: boot)
                try secureStore.write(JSONEncoder().encode(checkpoint), key: "native-trial-clock")
                remaining = max(0, end.timeIntervalSince(trusted))
                trialDaysRemaining = Int(ceil(remaining / 86400))
            } catch { notice = "The trial could not be verified. Check the iPad date and time, then try again." }
        }
        canAccessNative = entitled || remaining > 0
        if remaining > 0 {
            // Wake exactly when the displayed remaining-day count changes.
            let nextDayBoundary = max(1, remaining - Double(max(0, trialDaysRemaining - 1)) * 86400)
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(remaining, nextDayBoundary) * 1_000_000_000)) }
                catch { return }
                await self?.refresh()
            }
        }
    }
    public func load() async {
        guard !loading else { return }
        loading = true; notice = ""
        defer { loading = false }
        await refresh()
        do { product = try await client.product() }
        catch NativePurchaseFailure.productsUnavailable {
            product = nil; notice = "The App Store has not made this purchase available yet. Try again shortly."
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code) {
            product = nil; notice = "Unable to reach the App Store. Check your connection and try again."
        } catch {
            product = nil; notice = "The App Store could not load this purchase. Please try again."
        }
        do { trialProduct = try await client.trialProduct() }
        catch { trialProduct = nil }
    }
    public func buy() async {
        guard !busy, product != nil, !unlocked else { return }
        busy = true; notice = ""
        defer { busy = false }
        do {
            switch try await client.purchase() {
            case .purchased:
                refreshGeneration += 1
                unlocked = true; canAccessNative = true; checked = true
                expiryTask?.cancel(); expiryTask = nil
            case .pending: notice = "Purchase awaiting approval. Access will unlock when Apple confirms it."
            case .cancelled: break
            }
        } catch { notice = "The purchase could not be completed. Please try again." }
    }
    public func startTrial() async {
        // The paid price must be visible before starting, as required by Apple's trial rules.
        guard !busy, trialProduct != nil, product != nil, !unlocked, trialExpiresAt == nil else { return }
        busy = true; notice = ""
        defer { busy = false }
        do {
            switch try await client.beginTrial() {
            case .purchased: await refresh()
            case .pending: notice = "Trial awaiting approval. Access will unlock when Apple confirms it."
            case .cancelled: break
            }
        } catch { notice = "The free trial could not be started. Please try again." }
    }
    public func restore() async {
        guard !busy else { return }
        busy = true; notice = ""
        defer { busy = false }
        do {
            try await client.restore()
            await refresh()
            notice = unlocked ? "Purchase restored." : trialExpiresAt != nil ? (canAccessNative ? "Free trial restored." : "Your 7-day free trial has ended.") : "No purchase was found for this Apple Account."
        } catch { notice = "Purchases could not be restored. Check your connection and try again." }
    }
}
