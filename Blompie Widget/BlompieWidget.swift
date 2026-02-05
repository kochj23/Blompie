//
//  BlompieWidget.swift
//  Blompie Widget
//
//  macOS Widget for Blompie - AI Text Adventure Game
//  Shows current game state, achievements, and AI backend status
//  Created by Jordan Koch on 2026-02-04.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget Entry

/// Timeline entry containing game data for the widget
struct BlompieWidgetEntry: TimelineEntry {
    let date: Date
    let gameData: WidgetGameData
    let configuration: BlompieWidgetConfigurationIntent

    static var placeholder: BlompieWidgetEntry {
        BlompieWidgetEntry(
            date: Date(),
            gameData: WidgetGameData.placeholder,
            configuration: BlompieWidgetConfigurationIntent()
        )
    }
}

// MARK: - Timeline Provider

/// Provides timeline entries for the widget
struct BlompieWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = BlompieWidgetEntry
    typealias Intent = BlompieWidgetConfigurationIntent

    /// Provides a placeholder entry for widget gallery
    func placeholder(in context: Context) -> BlompieWidgetEntry {
        BlompieWidgetEntry.placeholder
    }

    /// Provides a snapshot for quick previews
    func snapshot(for configuration: BlompieWidgetConfigurationIntent, in context: Context) async -> BlompieWidgetEntry {
        let gameData = SharedDataManager.shared.getGameData()
        return BlompieWidgetEntry(date: Date(), gameData: gameData, configuration: configuration)
    }

    /// Provides the timeline of entries
    func timeline(for configuration: BlompieWidgetConfigurationIntent, in context: Context) async -> Timeline<BlompieWidgetEntry> {
        let gameData = SharedDataManager.shared.getGameData()
        let entry = BlompieWidgetEntry(date: Date(), gameData: gameData, configuration: configuration)

        // Refresh every 15 minutes to keep AI status current
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
}

// MARK: - Configuration Intent

/// App Intent for widget configuration
struct BlompieWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Blompie Adventure"
    static var description: IntentDescription = IntentDescription("Display your current game status")

    @Parameter(title: "Show AI Status", default: true)
    var showAIStatus: Bool

    init() {
        self.showAIStatus = true
    }

    init(showAIStatus: Bool) {
        self.showAIStatus = showAIStatus
    }
}

// MARK: - Color Theme

/// Blompie brand colors (matching the app's modern design)
enum BlompieColors {
    static let cyan = Color(red: 0.0, green: 0.8, blue: 0.95)
    static let purple = Color(red: 0.6, green: 0.4, blue: 1.0)
    static let gold = Color(red: 0.95, green: 0.75, blue: 0.2)
    static let green = Color(red: 0.2, green: 0.9, blue: 0.5)
    static let red = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let backgroundDark = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let backgroundCard = Color(white: 0.15)
}

// MARK: - Small Widget View

/// Small widget view - Shows adventure name and quick status
struct SmallWidgetView: View {
    let entry: BlompieWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with app icon
            HStack(spacing: 6) {
                Image(systemName: "book.pages")
                    .font(.caption)
                    .foregroundStyle(BlompieColors.cyan)
                Text("Blompie")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer(minLength: 4)

            // Adventure name
            Text(entry.gameData.adventureName)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Action count
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(BlompieColors.purple)
                Text("\(entry.gameData.actionCount) actions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Achievement progress
            HStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .font(.caption2)
                    .foregroundStyle(BlompieColors.gold)
                Text(entry.gameData.achievementText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }
}

// MARK: - Medium Widget View

/// Medium widget view - Shows more details including last action
struct MediumWidgetView: View {
    let entry: BlompieWidgetEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left column - Game info
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "book.pages")
                        .font(.subheadline)
                        .foregroundStyle(BlompieColors.cyan)
                    Text("Blompie")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                }

                Spacer(minLength: 4)

                // Adventure name
                Text(entry.gameData.adventureName)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Last action
                Text(entry.gameData.lastAction)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            // Right column - Stats
            VStack(alignment: .trailing, spacing: 8) {
                // Open app button
                Link(destination: entry.gameData.deepLinkURL) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.subheadline)
                        .foregroundStyle(BlompieColors.cyan)
                }

                Spacer(minLength: 4)

                // Action count
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(entry.gameData.actionCount)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(BlompieColors.purple)
                    Text("actions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Achievement progress
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption2)
                            .foregroundStyle(BlompieColors.gold)
                        Text(entry.gameData.achievementText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(BlompieColors.gold)
                                .frame(width: geo.size.width * entry.gameData.achievementProgress)
                        }
                    }
                    .frame(width: 60, height: 4)
                }

                Spacer(minLength: 0)

                // AI Status
                if entry.configuration.showAIStatus {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(entry.gameData.aiBackend.isAvailable ? BlompieColors.green : BlompieColors.red)
                            .frame(width: 6, height: 6)
                        Text(entry.gameData.aiBackend.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 80)
        }
        .padding()
    }
}

// MARK: - Large Widget View

/// Large widget view - Full game status with all details
struct LargeWidgetView: View {
    let entry: BlompieWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "book.pages")
                        .font(.headline)
                        .foregroundStyle(BlompieColors.cyan)
                    Text("Blompie")
                        .font(.headline)
                        .fontWeight(.bold)
                }

                Spacer()

                Link(destination: entry.gameData.deepLinkURL) {
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.caption)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .foregroundStyle(BlompieColors.cyan)
                }
            }

            Divider()

            // Adventure section
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Adventure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(entry.gameData.adventureName)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)

                // Last action
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(BlompieColors.cyan)
                    Text(entry.gameData.lastAction)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
            }

            // Stats grid
            HStack(spacing: 16) {
                // Actions stat
                StatCard(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: BlompieColors.purple,
                    value: "\(entry.gameData.actionCount)",
                    label: "Actions"
                )

                // Achievements stat
                StatCard(
                    icon: "trophy.fill",
                    iconColor: BlompieColors.gold,
                    value: entry.gameData.achievementText,
                    label: "Achievements"
                )
            }

            // Achievement progress bar
            VStack(alignment: .leading, spacing: 4) {
                Text("Achievement Progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.1))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [BlompieColors.gold, BlompieColors.gold.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * entry.gameData.achievementProgress)
                    }
                }
                .frame(height: 8)
            }

            Spacer(minLength: 0)

            // AI Backend status
            if entry.configuration.showAIStatus {
                Divider()

                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.subheadline)
                        .foregroundStyle(entry.gameData.aiBackend.isAvailable ? BlompieColors.green : BlompieColors.red)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.gameData.aiBackend.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(entry.gameData.aiBackend.isAvailable ? "Online" : "Offline")
                                .font(.caption2)
                                .foregroundStyle(entry.gameData.aiBackend.isAvailable ? BlompieColors.green : BlompieColors.red)
                        }

                        Text("Model: \(entry.gameData.aiBackend.model)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .padding()
    }
}

// MARK: - Stat Card Component

struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Main Widget View

/// Entry point view that switches based on widget family
struct BlompieWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    var entry: BlompieWidgetEntry

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Definition

/// The main widget definition
@main
struct BlompieWidget: Widget {
    let kind: String = "BlompieWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: BlompieWidgetConfigurationIntent.self,
            provider: BlompieWidgetProvider()
        ) { entry in
            BlompieWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Blompie Adventure")
        .description("Track your AI text adventure progress")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    BlompieWidget()
} timeline: {
    BlompieWidgetEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    BlompieWidget()
} timeline: {
    BlompieWidgetEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    BlompieWidget()
} timeline: {
    BlompieWidgetEntry.placeholder
}
