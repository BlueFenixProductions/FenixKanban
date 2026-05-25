import SwiftUI

#if os(iOS)
/// Trailing-edge horizontal-swipe gesture that reveals a gold pill
/// button. iOS-only — SwiftUI's `.swipeActions` only works inside
/// `List`, and FenixKanban's cards live in a `LazyVStack`.
struct GoldenSwipeModifier: ViewModifier {
    let isGolden: Bool
    let onToggle: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isRevealed = false

    private let revealThreshold: CGFloat = -80
    private let buttonWidth: CGFloat = 96

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                onToggle()
                close()
            } label: {
                ZStack {
                    Color.goldenTicket
                    VStack(spacing: 2) {
                        Image(systemName: isGolden ? "ticket.slash" : "ticket.fill")
                            .font(.title3)
                        Text(isGolden ? "Remove" : "Golden")
                            .font(.crossPlatformCaption2)
                    }
                    .foregroundStyle(Color.goldenTicketIcon)
                }
                .frame(width: buttonWidth)
            }
            .opacity(isRevealed ? 1 : 0)
            .accessibilityHidden(!isRevealed)

            content
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Only respond to mostly-horizontal drags so
                            // we don't fight the column's vertical scroll
                            // or the card's long-press drag-and-drop.
                            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else {
                                return
                            }
                            dragOffset = min(0, value.translation.width)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if dragOffset < revealThreshold {
                                    dragOffset = -buttonWidth
                                    isRevealed = true
                                } else {
                                    close()
                                }
                            }
                        }
                )
        }
        .clipped()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = 0
            isRevealed = false
        }
    }
}

extension View {
    func goldenSwipe(isGolden: Bool, onToggle: @escaping () -> Void) -> some View {
        self.modifier(GoldenSwipeModifier(isGolden: isGolden, onToggle: onToggle))
    }
}
#else
extension View {
    /// No-op on macOS — swipe-row pattern is iOS-only.
    func goldenSwipe(isGolden: Bool, onToggle: @escaping () -> Void) -> some View {
        self
    }
}
#endif
