#if os(iOS)
import SwiftUI
import StoreKit

@MainActor final class NativeStoreKitClient: NativePurchaseClient {
    let updates: AsyncStream<Void>
    private var listener: Task<Void, Never>?
    private var storeProduct: StoreKit.Product?
    private var freeTrialProduct: StoreKit.Product?

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        updates = AsyncStream { continuation = $0 }
        listener = Task {
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { break }
                guard case .verified(let transaction) = result,
                      [NativePurchaseStore.productID, NativePurchaseStore.trialProductID].contains(transaction.productID) else { continue }
                // Includes revocations/refunds and purchases approved on another device.
                continuation.yield(())
                await transaction.finish()
            }
            continuation.finish()
        }
    }
    deinit { listener?.cancel() }
    func hasEntitlement() async -> Bool {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == NativePurchaseStore.productID,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil, !transaction.isUpgraded { return true }
        }
        return false
    }
    func trialEntitlement() async -> NativeTrialEntitlement? {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == NativePurchaseStore.trialProductID,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil, !transaction.isUpgraded {
                return NativeTrialEntitlement(originalPurchaseDate: transaction.originalPurchaseDate, signedDate: transaction.signedDate)
            }
        }
        return nil
    }
    func trialProduct() async throws -> NativePurchaseProduct {
        guard let product = try await StoreKit.Product.products(for: [NativePurchaseStore.trialProductID]).first,
              product.type == .nonConsumable, product.price == 0 else { throw NativePurchaseFailure.productsUnavailable }
        freeTrialProduct = product
        return NativePurchaseProduct(displayPrice: product.displayPrice)
    }
    func beginTrial() async throws -> NativePurchaseResult {
        guard let freeTrialProduct, freeTrialProduct.price == 0 else { throw PurchaseError.unavailable }
        return try await buy(freeTrialProduct, expectedID: NativePurchaseStore.trialProductID)
    }
    func product() async throws -> NativePurchaseProduct {
        guard let product = try await StoreKit.Product.products(for: [NativePurchaseStore.productID]).first,
              product.type == .nonConsumable else { throw NativePurchaseFailure.productsUnavailable }
        storeProduct = product
        return NativePurchaseProduct(displayPrice: product.displayPrice)
    }
    func purchase() async throws -> NativePurchaseResult {
        guard let storeProduct else { throw PurchaseError.unavailable }
        return try await buy(storeProduct, expectedID: NativePurchaseStore.productID)
    }
    private func buy(_ product: StoreKit.Product, expectedID: String) async throws -> NativePurchaseResult {
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result,
                  transaction.productID == expectedID,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { throw PurchaseError.unverified }
            await transaction.finish()
            return .purchased
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PurchaseError.unavailable
        }
    }
    func restore() async throws { try await AppStore.sync() }
    private enum PurchaseError: Error { case unavailable, unverified }
}

extension NativePurchaseStore {
    static let shared = NativePurchaseStore(client: NativeStoreKitClient(), secureStore: KeychainStore(service: "com.hookdeveloper.jaraslive.native-trial"))
}

@MainActor struct IpadNativePurchaseView: View {
    @ObservedObject var store: NativePurchaseStore
    let close: () -> Void
    let openNative: () -> Void
    private let green = Color(red: 0.32, green: 0.93, blue: 0.54)
    var body: some View {
        GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        HStack(spacing: 9) {
                            Image(systemName: "waveform").foregroundStyle(green)
                            Text(verbatim: "CatLive").font(.jarasTitle2.bold())
                        }
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark").font(.jarasSystem(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44).background(.white.opacity(0.07), in: Circle())
                                .contentShape(Circle())
                        }.buttonStyle(.plain).accessibilityLabel("Close").disabled(store.busy)
                    }
                    Group {
                        if geometry.size.width >= 650 {
                            HStack(alignment: .center, spacing: 24) {
                                features.frame(maxWidth: .infinity)
                                purchaseCard.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Create and play your projects directly on iPad, without a computer.")
                                    .font(.jarasSubheadline).foregroundStyle(.white.opacity(0.7))
                                purchaseCard
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 14) {
                        Label("Remote mode stays free on iPad and iPhone.", systemImage: "network")
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 0)
                        Link("Privacy", destination: URL(string: "https://www.privacidade.vshook.app/catlive/")!)
                        Link("Support", destination: URL(string: "https://www.privacidade.vshook.app/catlive/suporte/")!)
                    }.font(.jarasFootnote).tint(green)
                }
                .padding(20).frame(maxWidth: 950)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RemoteSurface.background.ignoresSafeArea())
        }.foregroundStyle(.white).preferredColorScheme(.dark)
            .task { await store.load() }
            .interactiveDismissDisabled(store.busy)
    }
    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NATIVE ON IPAD").font(.jarasSystem(size: 12, weight: .bold, design: .rounded)).tracking(2)
                .foregroundStyle(green).padding(.horizontal, 12).padding(.vertical, 8)
                .background(green.opacity(0.1), in: Capsule())
            Text("Your show.\nOn your iPad.").font(.jarasSystem(size: 30, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            Text("Create and play your projects directly on iPad, without a computer.")
                .font(.jarasSystem(size: 14)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("waveform", "Multitrack playback and audio recording")
                feature("slider.horizontal.3", "Mixer, routing and native effects")
                feature("list.bullet.rectangle", "Setlists, loops and teleprompters")
                feature("arrow.left.arrow.right", "Exchange .ziplive projects with your Mac")
            }.padding(.top, 6)
        }
    }
    private func feature(_ icon: String, _ title: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.jarasSystem(size: 17)).foregroundStyle(green).frame(width: 24)
            Text(title).font(.jarasSystem(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var purchaseCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "ipad.landscape").font(.jarasSystem(size: 24, weight: .light)).foregroundStyle(green)
                Text("CatLive Native iPad").font(.jarasSystem(size: 19, weight: .bold))
            }
            Text("One-time purchase. No subscription.").font(.jarasSystem(size: 13)).foregroundStyle(.white.opacity(0.65))
            Group {
                if store.unlocked {
                    Label("Purchased", systemImage: "checkmark.seal.fill").foregroundStyle(green)
                } else if let product = store.product {
                    Text(verbatim: product.displayPrice).font(.jarasSystem(size: 32, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("native-purchase-price")
                } else if store.loading { ProgressView().tint(green) }
                else { Text("Price unavailable").foregroundStyle(.white.opacity(0.65)) }
            }.frame(minHeight: 40)
            Button {
                Task { if await store.activateNative() { openNative() } }
            } label: {
                HStack {
                    Spacer()
                    if store.busy { ProgressView().tint(.black) }
                    Text(LocalizedStringKey(primaryActionTitle)).font(.jarasSystem(size: 16, weight: .bold))
                    Spacer()
                }.frame(height: 44).foregroundStyle(.black)
                    .background(LinearGradient(colors: [green, Color(red: 0.22, green: 0.77, blue: 0.42)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(!store.primaryActionAvailable)
                .opacity(store.primaryActionAvailable ? 1 : 0.45)
                .accessibilityIdentifier("native-purchase-primary")
            if !store.unlocked {
                if store.trialDaysRemaining > 0 {
                    Text("Free trial: \(store.trialDaysRemaining) day(s) remaining")
                        .font(.jarasSubheadline.bold()).foregroundStyle(green)
                } else if store.trialExpiresAt != nil {
                    Text("Your 7-day free trial has ended.").font(.jarasSubheadline).foregroundStyle(.orange)
                } else {
                    if !store.loading && store.trialProduct == nil {
                        Text("The free trial is unavailable right now. Try again shortly.").font(.jarasCaption).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Text("The 7-day trial is free. After it ends, lifetime access is a separate one-time purchase at the price shown above. There is no subscription or automatic charge. Your projects are kept. Remote stays free.")
                    .font(.jarasCaption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button { Task { await store.restore() } } label: {
                    Text("Restore purchases").frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(green).disabled(store.busy)
                    .accessibilityIdentifier("native-purchase-restore")
                if (store.product == nil || (store.trialProduct == nil && store.trialExpiresAt == nil)) && !store.loading && !store.unlocked {
                    Button { Task { await store.load() } } label: {
                        Text("Try again").frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(green).disabled(store.busy)
                }
            }.font(.jarasSystem(size: 13, weight: .semibold))
            if !store.notice.isEmpty {
                Text(LocalizedStringKey(store.notice)).font(.jarasFootnote).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text("Payment is handled by the App Store. Restore your purchase using the same Apple Account.")
                .font(.jarasSystem(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity)
            .background { RemoteSurface.panel.clipShape(RoundedRectangle(cornerRadius: 22)) }
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(green.opacity(0.3)))
    }
    private var primaryActionTitle: String {
        switch store.primaryAction {
        case .openPurchased: return "Open Native mode"
        case .continueTrial: return "Continue free trial"
        case .startTrial: return "Start 7-day free trial"
        case .purchase: return "Buy lifetime access"
        }
    }
}
#endif
