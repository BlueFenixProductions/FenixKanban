import StoreKit
import SwiftUI

struct TipJarView: View {
    @State private var store = TipJarStore()
    @State private var showAlert = false
    @State private var purchasingID: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FenixKanban is made with love by an independent developer.")
                        .font(.subheadline)
                    Text("If you're enjoying the app, a tip goes a long way toward keeping it alive and improving it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Choose a Tip") {
                if store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if store.tips.isEmpty {
                    Text("Tip options unavailable right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.tips) { product in
                        TipRow(
                            product: product,
                            isPurchasing: purchasingID == product.id
                        ) {
                            purchasingID = product.id
                            await store.purchase(product)
                            purchasingID = nil
                        }
                    }
                }
            }
        }
        .navigationTitle("Tip Jar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadProducts() }
        .onChange(of: store.purchaseMessage) { _, message in
            showAlert = message != nil
        }
        .alert("Tip Jar", isPresented: $showAlert) {
            Button("OK") { store.purchaseMessage = nil }
        } message: {
            Text(store.purchaseMessage ?? "")
        }
    }
}

private struct TipRow: View {
    let product: Product
    let isPurchasing: Bool
    let onTap: () async -> Void

    var body: some View {
        Button {
            Task { await onTap() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .foregroundStyle(.primary)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isPurchasing)
    }
}
