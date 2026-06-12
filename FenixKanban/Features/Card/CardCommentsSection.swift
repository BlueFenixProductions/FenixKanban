import SwiftUI

/// Comments section for a fizzy-paired card's detail Form (issue #16).
/// Cache-first: renders cached comments immediately; `refresh()` reconciles
/// on appear. Only shown when the card has a fizzyNumber (paired cards).
///
/// Liquid Glass: no `.background` on any chrome surface — system handles it.
struct CardCommentsSection: View {
    var viewModel: CardCommentsViewModel
    @State private var newCommentText = ""

    var body: some View {
        Section {
            ForEach(viewModel.comments, id: \.objectID) { comment in
                commentRow(comment)
            }

            HStack(spacing: 8) {
                TextField("Add a comment", text: $newCommentText, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("comments-add-field")

                Button {
                    let text = newCommentText
                    newCommentText = ""
                    Task { await viewModel.post(body: text) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send comment")
            }
        } header: {
            HStack {
                Text("Comments (\(viewModel.comments.count))")
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .task { await viewModel.refresh() }
            .alert("Comments Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ comment: CachedComment) -> some View {
        let isPending = comment.pendingWrite
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(comment.creatorName ?? "Unknown")
                    .font(.crossPlatformCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isPending ? Color.secondary : Color.primary)
                Spacer()
                if isPending {
                    Image(systemName: "clock")
                        .font(.crossPlatformCaption2)
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel("Pending — not yet sent")
                } else if let date = comment.createdAt {
                    Text(date, style: .relative)
                        .font(.crossPlatformCaption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            Text(comment.body ?? "")
                .font(.crossPlatformSubheadline)
                .foregroundStyle(isPending ? Color.secondary : Color.primary)
        }
        .opacity(isPending ? 0.6 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(comment.creatorName ?? "Unknown"): \(comment.body ?? "")\(isPending ? " (pending)" : "")")
    }
}
