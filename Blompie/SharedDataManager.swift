//
//  SharedDataManager.swift
//  Blompie
//
//  Shared data manager for syncing game data to the widget
//  Created by Jordan Koch on 2026-02-04.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import Foundation
import WidgetKit

/// Manages shared data access for syncing with the widget extension
/// Writes to the shared App Group UserDefaults container
class SharedDataManager {
    static let shared = SharedDataManager()

    // MARK: - Constants

    /// App Group identifier for shared container
    static let appGroupIdentifier = "group.com.jkoch.blompie"

    /// Storage keys for shared data
    enum StorageKey {
        static let gameData = "widget_game_data"
        static let lastUpdate = "widget_last_update"
    }

    // MARK: - Properties

    /// Shared UserDefaults for App Group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedDataManager.appGroupIdentifier)
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Data Writing

    /// Saves game data to the shared container and refreshes widget
    func saveGameData(_ gameData: WidgetGameData) {
        guard let defaults = sharedDefaults,
              let data = try? JSONEncoder().encode(gameData) else {
            return
        }
        defaults.set(data, forKey: StorageKey.gameData)
        defaults.set(Date(), forKey: StorageKey.lastUpdate)

        // Refresh the widget timeline
        WidgetCenter.shared.reloadTimelines(ofKind: "BlompieWidget")
    }

    /// Updates game data from the main app's game engine
    @MainActor
    func updateFromGameEngine(_ gameEngine: GameEngine) {
        // Determine AI backend info
        let aiBackend = AIBackendManager.shared
        let backendName = aiBackend.isOllamaAvailable ? "Ollama" : (aiBackend.isMLXAvailable ? "MLX" : "Unknown")
        let backendAvailable = aiBackend.isOllamaAvailable || aiBackend.isMLXAvailable

        let gameData = WidgetGameData(
            adventureName: getAdventureName(from: gameEngine),
            actionCount: gameEngine.actionHistory.count,
            lastAction: gameEngine.actionHistory.last ?? "Start your adventure!",
            achievementsUnlocked: gameEngine.achievements.filter { $0.isUnlocked }.count,
            achievementsTotal: gameEngine.achievements.count,
            aiBackend: WidgetGameData.AIBackendInfo(
                name: backendName,
                isAvailable: backendAvailable,
                model: gameEngine.selectedModel
            ),
            lastUpdate: Date()
        )
        saveGameData(gameData)
    }

    /// Extracts adventure name from game messages
    @MainActor
    private func getAdventureName(from gameEngine: GameEngine) -> String {
        // Try to extract adventure name from the first few messages
        // Looking for location names or scene descriptions
        let messages = gameEngine.messages.prefix(10)

        for message in messages {
            let text = message.text
            // Skip system messages
            if text.hasPrefix("===") || text.hasPrefix(">") || text.isEmpty {
                continue
            }

            // Look for location indicators
            let locationPatterns = ["enter", "arrive", "standing in", "find yourself", "welcome to"]
            for pattern in locationPatterns {
                if text.lowercased().contains(pattern) {
                    // Extract a short description
                    let words = text.components(separatedBy: .whitespaces).prefix(6)
                    return words.joined(separator: " ") + "..."
                }
            }

            // Otherwise use first meaningful content
            if text.count > 10 {
                let words = text.components(separatedBy: .whitespaces).prefix(4)
                return words.joined(separator: " ") + "..."
            }
        }

        // Fallback
        if !gameEngine.locationHistory.isEmpty {
            return gameEngine.locationHistory.last ?? "Active Adventure"
        }

        return "Active Adventure"
    }
}

// MARK: - Widget Game Data Model (Shared with Widget)

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

    /// Achievement progress as percentage (0.0 - 1.0)
    var achievementProgress: Double {
        guard achievementsTotal > 0 else { return 0.0 }
        return Double(achievementsUnlocked) / Double(achievementsTotal)
    }
}
