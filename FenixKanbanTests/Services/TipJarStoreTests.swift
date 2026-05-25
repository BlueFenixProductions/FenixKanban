import Testing
@testable import FenixKanban

@Suite("TipJar Store")
@MainActor
struct TipJarStoreTests {
    @Test func initialStateIsEmpty() {
        let store = TipJarStore()
        #expect(store.tips.isEmpty)
        #expect(store.purchaseMessage == nil)
        #expect(store.isLoading == false)
    }

    @Test func loadProductsResetsLoadingFlag() async {
        let store = TipJarStore()
        await store.loadProducts()
        // Regardless of whether StoreKit succeeded (depends on whether the
        // test plan has a .storekit configuration attached), isLoading must
        // be false once the call returns.
        #expect(store.isLoading == false)
    }

    @Test func loadProductsIsIdempotent() async {
        let store = TipJarStore()
        await store.loadProducts()
        let firstCount = store.tips.count
        await store.loadProducts()
        // A second load shouldn't accumulate duplicates — the assignment
        // replaces the tips array rather than appending.
        #expect(store.tips.count == firstCount)
        #expect(store.isLoading == false)
    }
}
