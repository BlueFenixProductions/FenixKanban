// Widgets/PlaygroundBoardWidget.swift
//
// FenixKanban board widget — displays a column summary read live from the
// shared App Group CoreData store (FenixKanban.sqlite) via WidgetBoardReader.
//
// TimelineProvider reads `WidgetBoardReader().read()`, which opens the App Group
// store read-only (no CloudKit) and maps the first board (by sortOrder) into a
// WidgetBoardData. Returns nil when the store is unavailable or empty, and the
// view renders a "No board data" state.
//
// Refresh policy: every 30 minutes. The main app can request an immediate
// reload via `WidgetCenter.shared.reloadAllTimelines()` after a sync/save.

import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct BoardWidgetEntry: TimelineEntry {
    let date: Date
    let boardData: WidgetBoardData?
}

// MARK: - TimelineProvider

struct BoardWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoardWidgetEntry {
        BoardWidgetEntry(
            date: .now,
            boardData: WidgetBoardData(
                boardName: "My Board",
                columns: [
                    WidgetBoardData.ColumnSummary(
                        name: "To Do",
                        cardCount: 5,
                        topCardTitles: ["Write tests", "Fix bug", "Review PR"]
                    ),
                    WidgetBoardData.ColumnSummary(
                        name: "In Progress",
                        cardCount: 2,
                        topCardTitles: ["Design mockup", "Deploy fix"]
                    )
                ]
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BoardWidgetEntry) -> Void) {
        let boardData = WidgetBoardReader().read()
        completion(BoardWidgetEntry(date: .now, boardData: boardData))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardWidgetEntry>) -> Void) {
        let boardData = WidgetBoardReader().read()
        let entry = BoardWidgetEntry(date: .now, boardData: boardData)
        // Refresh every 30 minutes.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }
}

// MARK: - Widget view

struct BoardWidgetEntryView: View {
    var entry: BoardWidgetProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let boardData = entry.boardData, !boardData.boardName.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(boardData.boardName)
                    .font(.headline)
                    .lineLimit(1)

                ForEach(boardData.columns.prefix(3), id: \.name) { column in
                    ColumnSummaryRow(column: column)
                }
            }
            .padding(12)
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.3.group")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No board data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ColumnSummaryRow: View {
    let column: WidgetBoardData.ColumnSummary

    var body: some View {
        HStack(spacing: 4) {
            Text(column.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(column.cardCount)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget configuration

struct PlaygroundBoardWidget: Widget {
    let kind: String = "PlaygroundBoardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BoardWidgetProvider()) { entry in
            BoardWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Board Summary")
        .description("Shows a summary of your FenixKanban board columns.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget bundle

@main
struct FenixKanbanWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlaygroundBoardWidget()
    }
}
