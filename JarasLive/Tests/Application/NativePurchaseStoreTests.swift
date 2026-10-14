import XCTest
@testable import JarasApplication

@MainActor private final class PurchaseClient: NativePurchaseClient {
    let updates: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    var entitled = false
    var result = NativePurchaseResult.cancelled
    var failure = false, restored = false
    var buys = 0, restores = 0
    init() {
        var output: AsyncStream<Void>.Continuation!
        updates = AsyncStream { output = $0 }; continuation = output
    }
    func hasEntitlement() async -> Bool { entitled }
    func product() async throws -> NativePurchaseProduct {
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
}
