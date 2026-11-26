import XCTest
@testable import JarasApplication

@MainActor private final class PurchaseClient: NativePurchaseClient {
    let updates: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    var entitled = false
    var result = NativePurchaseResult.cancelled
    var failure = false, restored = false
    var missingProduct = false
    var buys = 0, restores = 0
    var trial: NativeTrialEntitlement?
    var trialResult = NativePurchaseResult.cancelled
    var trialBegins = 0
    func trialEntitlement() async -> NativeTrialEntitlement? { trial }
    func trialProduct() async throws -> NativePurchaseProduct { try await product() }
    func beginTrial() async throws -> NativePurchaseResult { trialBegins += 1; return trialResult }
    init() {
        var output: AsyncStream<Void>.Continuation!
        updates = AsyncStream { output = $0 }; continuation = output
    }
    func hasEntitlement() async -> Bool { entitled }
    func product() async throws -> NativePurchaseProduct {
        if missingProduct { throw NativePurchaseFailure.productsUnavailable }
        if failure { throw URLError(.notConnectedToInternet) }
        return NativePurchaseProduct(displayPrice: "R$ 79,90")
    }
    func purchase() async throws -> NativePurchaseResult {
        buys += 1
        if failure { throw URLError(.cannotParseResponse) }
        return result
    }
    func restore() async throws {
        restores += 1
        if failure { throw URLError(.notConnectedToInternet) }
        entitled = restored
    }
}

@MainActor final class NativePurchaseStoreTests: XCTestCase {
    func testSinglePrimaryActionNeverConvertsTheTrialIntoAPaidPurchase() async {
        let client=PurchaseClient(), start=Date(timeIntervalSince1970:1_700_000_000)
        var date=start
        let store=NativePurchaseStore(client:client,now:{date},uptime:{0},boot:{"test"})
        XCTAssertFalse(store.primaryActionAvailable)
        await store.load()
        XCTAssertEqual(store.primaryAction,.startTrial)
        XCTAssertTrue(store.primaryActionAvailable)
        let cancelled=await store.activateNative()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(client.trialBegins,1)
        XCTAssertEqual(client.buys,0)
        client.trial=NativeTrialEntitlement(originalPurchaseDate:start,signedDate:start)
        await store.refresh()
        XCTAssertEqual(store.primaryAction,.continueTrial)
        let active=await store.activateNative()
        XCTAssertTrue(active)
        XCTAssertEqual(client.trialBegins,1)
        XCTAssertEqual(client.buys,0)
        date=start.addingTimeInterval(7*86400)
        await store.refresh()
        XCTAssertEqual(store.primaryAction,.purchase)
        XCTAssertEqual(client.buys,0,"Expiration must not charge automatically")
        client.result = .purchased
        let purchased=await store.activateNative()
        XCTAssertTrue(purchased)
        XCTAssertEqual(client.buys,1)
        XCTAssertEqual(store.primaryAction,.openPurchased)
        let reopened=await store.activateNative()
        XCTAssertTrue(reopened)
        XCTAssertEqual(client.buys,1)
    }
    func testCatalogUnavailableIsNotReportedAsNetworkFailure() async {
        let client = PurchaseClient(), store: NativePurchaseStore
        store = NativePurchaseStore(client: client)
        client.missingProduct = true
        await store.load()
        XCTAssertNil(store.product)
        XCTAssertEqual(store.notice, "The App Store has not made this purchase available yet. Try again shortly.")
        await store.startTrial()
        XCTAssertEqual(client.trialBegins, 0)
        client.missingProduct = false; client.failure = true
        await store.load()
        XCTAssertEqual(store.notice, "Unable to reach the App Store. Check your connection and try again.")
        client.failure = false
        await store.load()
        XCTAssertNotNil(store.product)
        XCTAssertTrue(store.notice.isEmpty)
    }
    func testNoPurchaseOrPriceCannotUnlock() async {
        let client = PurchaseClient(), store = NativePurchaseStore(client: PurchaseClient())
        await store.buy()
        XCTAssertFalse(store.unlocked)
        let missing = NativePurchaseStore(client: client)
        client.failure = true
        await missing.load(); await missing.buy()
        XCTAssertNil(missing.product); XCTAssertFalse(missing.unlocked)
        XCTAssertEqual(client.buys, 0)
        XCTAssertFalse(missing.notice.isEmpty)
    }
    func testVerifiedPurchaseUnlocksWithoutAnotherNetworkRequest() async {
        let client = PurchaseClient(); client.result = .purchased
        let store = NativePurchaseStore(client: client)
        await store.load(); await store.buy()
        XCTAssertTrue(store.unlocked); XCTAssertTrue(store.checked)
        XCTAssertFalse(store.busy); XCTAssertEqual(client.buys, 1)
        await store.buy(); XCTAssertEqual(client.buys, 1)
    }
    func testCancelledPendingAndFailedPurchasesNeverUnlock() async {
        let client = PurchaseClient(), store: NativePurchaseStore
        store = NativePurchaseStore(client: client)
        await store.load(); await store.buy()
        XCTAssertFalse(store.unlocked); XCTAssertEqual(store.notice, "")
        client.result = .pending
        await store.buy(); XCTAssertFalse(store.unlocked); XCTAssertTrue(store.notice.contains("approval"))
        client.failure = true
        await store.buy(); XCTAssertFalse(store.unlocked); XCTAssertFalse(store.busy)
    }
    func testExistingVerifiedEntitlementSurvivesProductFetchOffline() async {
        let client = PurchaseClient(); client.entitled = true; client.failure = true
        let store = NativePurchaseStore(client: client)
        await store.load()
        XCTAssertTrue(store.unlocked); XCTAssertNil(store.product)
        XCTAssertEqual(client.restores, 0, "Opening never prompts App Store authentication")
    }
    func testRestorationRequiresAnEntitlementAndHandlesRevocation() async {
        let client = PurchaseClient(), store: NativePurchaseStore
        store = NativePurchaseStore(client: client)
        await store.restore(); XCTAssertFalse(store.unlocked)
        client.restored = true
        await store.restore(); XCTAssertTrue(store.unlocked)
        client.entitled = false
        await store.refresh(); XCTAssertFalse(store.unlocked)
    }
    func testUpdateListenerUnlocksAnApprovedPendingPurchase() async {
        let client = PurchaseClient(), store: NativePurchaseStore
        store = NativePurchaseStore(client: client)
        await store.load()
        client.entitled = true; client.continuation.yield(())
        for _ in 0..<100 where !store.unlocked { await Task.yield() }
        XCTAssertTrue(store.unlocked)
        client.entitled = false; client.continuation.yield(())
        for _ in 0..<100 where store.unlocked { await Task.yield() }
        XCTAssertFalse(store.unlocked)
    }

    func testTrialIsExactlySevenDaysFromOriginalAppleTransactionAndRestoreNeverRestartsIt() async {
        let client = PurchaseClient(), start = Date(timeIntervalSince1970: 1_700_000_000)
        var date = start
        client.trial = NativeTrialEntitlement(originalPurchaseDate: start, signedDate: start)
        let store = NativePurchaseStore(client: client, now: { date }, uptime: { 0 }, boot: { "test" })
        await store.refresh()
        XCTAssertTrue(store.canAccessNative); XCTAssertFalse(store.unlocked)
        XCTAssertEqual(store.trialDaysRemaining, 7)
        date = start.addingTimeInterval(7 * 86400 - 1)
        await store.refresh(); XCTAssertTrue(store.canAccessNative); XCTAssertEqual(store.trialDaysRemaining, 1)
        date = start.addingTimeInterval(7 * 86400)
        await store.restore(); XCTAssertFalse(store.canAccessNative); XCTAssertEqual(store.trialDaysRemaining, 0)
        XCTAssertEqual(store.trialExpiresAt, date)
        await store.load(); await store.startTrial(); XCTAssertEqual(client.trialBegins, 0)
    }
    func testExpiredTrialDoesNotDisablePermanentPurchase() async {
        let client = PurchaseClient(), start = Date(timeIntervalSince1970: 1_700_000_000)
        client.trial = NativeTrialEntitlement(originalPurchaseDate: start, signedDate: start)
        client.entitled = true; client.failure = true
        let store = NativePurchaseStore(client: client, now: { start.addingTimeInterval(30 * 86400) })
        await store.load(); XCTAssertTrue(store.canAccessNative); XCTAssertTrue(store.unlocked)
    }
    func testRestoringTrialOnAnotherInstallationUsesOriginalStartDate() async {
        let client = PurchaseClient(), start = Date(timeIntervalSince1970: 1_700_000_000)
        let date = start.addingTimeInterval(6 * 86400)
        client.trial = NativeTrialEntitlement(originalPurchaseDate: start, signedDate: date)
        let store = NativePurchaseStore(client: client, now: { date })
        await store.restore(); XCTAssertTrue(store.canAccessNative); XCTAssertEqual(store.trialDaysRemaining, 1)
    }
    func testClockRollbackCannotRenewTrialAcrossLaunches() async {
        let client = PurchaseClient(), start = Date(timeIntervalSince1970: 1_700_000_000), keychain = MemorySecureStore()
        var date = start.addingTimeInterval(6 * 86400)
        client.trial = NativeTrialEntitlement(originalPurchaseDate: start, signedDate: start)
        let first = NativePurchaseStore(client: client, secureStore: keychain, now: { date }, uptime: { 0 }, boot: { "boot" })
        await first.refresh(); XCTAssertTrue(first.canAccessNative)
        date = start.addingTimeInterval(2 * 86400)
        let reopened = NativePurchaseStore(client: client, secureStore: keychain, now: { date }, uptime: { 100 }, boot: { "boot" })
        await reopened.refresh(); XCTAssertFalse(reopened.canAccessNative)
        XCTAssertTrue(reopened.notice.contains("date and time"))
    }
    func testTrialRequiresVerifiedReceiptAndExplicitStart() async {
        let client = PurchaseClient(), store: NativePurchaseStore
        store = NativePurchaseStore(client: client)
        await store.load(); XCTAssertFalse(store.canAccessNative); XCTAssertEqual(client.trialBegins, 0)
        await store.startTrial(); XCTAssertFalse(store.canAccessNative)
        client.trialResult = .pending
        await store.startTrial(); XCTAssertFalse(store.canAccessNative)
        client.trialResult = .purchased
        await store.startTrial(); XCTAssertFalse(store.canAccessNative, "A completion alone cannot invent the Apple trial date")
    }
}
