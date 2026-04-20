import Foundation
import StoreKit

@Observable
final class TipJarStore {
    var tips: [Product] = []
    var purchaseMessage: String?
    var isLoading = false

    private let productIDs = [
        "com.bluefenixproductions.fenixkanban.tip.small",
        "com.bluefenixproductions.fenixkanban.tip.medium",
        "com.bluefenixproductions.fenixkanban.tip.large",
        "com.bluefenixproductions.fenixkanban.tip.huge"
    ]

    @MainActor
    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: productIDs)
            tips = products.sorted { $0.price < $1.price }
        } catch {
            purchaseMessage = "Couldn't load tip options. Please try again later."
        }
    }

    @MainActor
    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                purchaseMessage = "Thank you so much for your support!"
            case .userCancelled:
                break
            case .pending:
                purchaseMessage = "Your purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseMessage = "Purchase failed. Please try again."
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

private enum StoreError: Error {
    case failedVerification
}
