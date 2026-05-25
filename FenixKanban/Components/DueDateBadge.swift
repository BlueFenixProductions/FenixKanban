import SwiftUI

struct DueDateBadge: View {
    let date: Date

    private var color: Color {
        if date.isOverdue { return .red }
        if date.isDueToday { return .orange }
        if date.isDueSoon { return .yellow }
        return .secondary
    }

    private var icon: String {
        if date.isOverdue { return "exclamationmark.circle.fill" }
        return "calendar"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.crossPlatformCaption2)
            Text(date.relativeDisplay)
                .font(.crossPlatformCaption2)
        }
        .foregroundStyle(color)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        DueDateBadge(date: Date().addingTimeInterval(-86400))
        DueDateBadge(date: Date())
        DueDateBadge(date: Date().addingTimeInterval(86400))
        DueDateBadge(date: Date().addingTimeInterval(86400 * 7))
    }
    .padding()
    .preferredColorScheme(.dark)
}
