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
        let commentID = comment.fizzyCommentID ?? ""
        let rowReactions = viewModel.reactions[commentID] ?? []
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

            if !isPending && !commentID.isEmpty {
                reactionStrip(commentID: commentID, reactions: rowReactions)
            }
        }
        .opacity(isPending ? 0.6 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(comment.creatorName ?? "Unknown"): \(comment.body ?? "")\(isPending ? " (pending)" : "")")
        .task {
            if !isPending && !commentID.isEmpty {
                await viewModel.loadReactions(for: commentID)
            }
        }
    }

    /// Groups reactions by emoji, returning ordered (emoji, count, isMine) tuples.
    private func groupedReactions(_ reactions: [FizzyReaction]) -> [(emoji: String, count: Int, isMine: Bool)] {
        var seen = Set<String>()
        var result: [(emoji: String, count: Int, isMine: Bool)] = []
        for reaction in reactions {
            guard !seen.contains(reaction.content) else { continue }
            seen.insert(reaction.content)
            let emojiReactions = reactions.filter { $0.content == reaction.content }
            let isMine = emojiReactions.contains { $0.reacter.id == viewModel.currentFizzyUserID }
            result.append((emoji: reaction.content, count: emojiReactions.count, isMine: isMine))
        }
        return result
    }

    /// Horizontal reaction bar: existing bubbles grouped by emoji, plus an
    /// add-reaction menu with 5 common emoji.
    private func reactionStrip(commentID: String, reactions: [FizzyReaction]) -> some View {
        let commonEmoji = ["👍", "❤️", "🎉", "👀", "🚀"]
        let counts = groupedReactions(reactions)
        return HStack(spacing: 4) {
            ForEach(counts, id: \.emoji) { entry in
                Button {
                    Task { await viewModel.toggleReaction(emoji: entry.emoji, for: commentID) }
                } label: {
                    Text("\(entry.emoji) \(entry.count)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(entry.isMine
                                      ? Color.accentColor.opacity(0.25)
                                      : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(entry.isMine ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.emoji), \(entry.count) reaction\(entry.count == 1 ? "" : "s")\(entry.isMine ? ", reacted" : "")")
            }

            Menu {
                ForEach(commonEmoji, id: \.self) { emoji in
                    Button(emoji) {
                        Task { await viewModel.toggleReaction(emoji: emoji, for: commentID) }
                    }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Add reaction")
        }
        .padding(.top, 2)
    }
}
