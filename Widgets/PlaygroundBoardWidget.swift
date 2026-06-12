// Widgets/PlaygroundBoardWidget.swift
//
// FenixKanban board widget — displays a column summary from the latest
// BoardSnapshot written by the main app after each sync.
//
// TimelineProvider reads `BoardSnapshotWriter.readSnapshot()` which checks:
//   1. App Group container  (group.com.bluefenixproductions.FenixKanban)
//   2. Application Support  (fallback for dev/CI builds without entitlement)
//
// Refresh policy: every 30 minutes. The main app can request an immediate
// reload via `WidgetCenter.shared.reloadAllTimelines()` after a sync.

import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct BoardWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BoardSnapshot?
}

// MARK: - TimelineProvider

struct BoardWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoardWidgetEntry {
        BoardWidgetEntry(
            date: .now,
            snapshot: BoardSnapshot(
                boardName: "My Board",
                columns: [
                    BoardSnapshot.ColumnSummary(
                        name: "To Do",
                        cardCount: 5,
                        topCardTitles: ["Write tests", "Fix bug", "Review PR"]
                    ),
                    BoardSnapshot.ColumnSummary(
                        name: "In Progress",
                        cardCount: 2,
                        topCardTitles: ["Design mockup", "Deploy fix"]
                    )
                ],
                generatedAt: .now
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BoardWidgetEntry) -> Void) {
        let snapshot = WidgetSnapshotReader.readSnapshot()
        completion(BoardWidgetEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardWidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshotReader.readSnapshot()
        let entry = BoardWidgetEntry(date: .now, snapshot: snapshot)
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
        if let snapshot = entry.snapshot, !snapshot.boardName.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.boardName)
                    .font(.headline)
                    .lineLimit(1)

                ForEach(snapshot.columns.prefix(3), id: \.name) { column in
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
    let column: BoardSnapshot.ColumnSummary

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
