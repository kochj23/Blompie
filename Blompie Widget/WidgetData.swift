//
//  WidgetData.swift
//  Blompie Widget
//
//  Data models for Blompie widget display
//  Created by Jordan Koch on 2026-02-04.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import Foundation

/// Lightweight game data model for widget display
/// Contains essential game state information
struct WidgetGameData: Codable {
    let adventureName: String
    let actionCount: Int
    let lastAction: String
    let achievementsUnlocked: Int
    let achievementsTotal: Int
    let aiBackend: AIBackendInfo
    let lastUpdate: Date

    struct AIBackendInfo: Codable {
        let name: String
        let isAvailable: Bool
        let model: String
    }

    /// Initialize with default/empty values
    init(
        adventureName: String = "New Adventure",
        actionCount: Int = 0,
        lastAction: String = "Start your adventure!",
        achievementsUnlocked: Int = 0,
        achievementsTotal: Int = 10,
        aiBackend: AIBackendInfo = AIBackendInfo(name: "Ollama", isAvailable: false, model: "mistral"),
        lastUpdate: Date = Date()
    ) {
        self.adventureName = adventureName
        self.actionCount = actionCount
        self.lastAction = lastAction
        self.achievementsUnlocked = achievementsUnlocked
        self.achievementsTotal = achievementsTotal
        self.aiBackend = aiBackend
        self.lastUpdate = lastUpdate
    }

    /// Default data for placeholder/preview
    static let placeholder = WidgetGameData(
        adventureName: "The Crystal Caves",
        actionCount: 42,
        lastAction: "Enter the mysterious portal",
        achievementsUnlocked: 4,
        achievementsTotal: 10,
        aiBackend: AIBackendInfo(name: "Ollama", isAvailable: true, model: "mistral:latest"),
        lastUpdate: Date()
    )

    /// Empty state when no game is active
    static let empty = WidgetGameData(
        adventureName: "No Active Game",
        actionCount: 0,
        lastAction: "Launch Blompie to begin!",
        achievementsUnlocked: 0,
        achievementsTotal: 10,
        aiBackend: AIBackendInfo(name: "Unknown", isAvailable: false, model: "N/A"),
        lastUpdate: Date()
    )

    /// URL for opening the app
    var deepLinkURL: URL {
        URL(string: "blompie://open")!
    }

    /// URL for continuing the game
    var continueGameURL: URL {
        URL(string: "blompie://continue")!
    }

    /// Achievement progress as percentage (0.0 - 1.0)
    var achievementProgress: Double {
        guard achievementsTotal > 0 else { return 0.0 }
        return Double(achievementsUnlocked) / Double(achievementsTotal)
    }

    /// Formatted achievement text
    var achievementText: String {
        "\(achievementsUnlocked)/\(achievementsTotal)"
    }

    /// AI status indicator
    var aiStatusText: String {
        if aiBackend.isAvailable {
            return "\(aiBackend.name): \(aiBackend.model)"
        } else {
            return "\(aiBackend.name): Offline"
        }
    }
}
