//
//  SharedDataManager.swift
//  Blompie Widget
//
//  Shared data manager for reading game data from App Group container
//  Created by Jordan Koch on 2026-02-04.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import Foundation

/// Manages shared data access for the widget extension
/// Reads from the shared App Group UserDefaults container
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

    // MARK: - Data Access (Widget Extension)

    /// Retrieves game data from the shared container
    func getGameData() -> WidgetGameData {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: StorageKey.gameData),
              let gameData = try? JSONDecoder().decode(WidgetGameData.self, from: data) else {
            return WidgetGameData.empty
        }
        return gameData
    }

    /// Gets the last update timestamp
    func getLastUpdateDate() -> Date? {
        sharedDefaults?.object(forKey: StorageKey.lastUpdate) as? Date
    }

    // MARK: - Data Writing (Main App)

    /// Saves game data to the shared container (called from main app)
    func saveGameData(_ gameData: WidgetGameData) {
        guard let defaults = sharedDefaults,
              let data = try? JSONEncoder().encode(gameData) else {
            return
        }
        defaults.set(data, forKey: StorageKey.gameData)
        defaults.set(Date(), forKey: StorageKey.lastUpdate)
    }

    /// Updates game data from the main app's game engine
    func updateFromGameEngine(
        adventureName: String,
        actionCount: Int,
        lastAction: String,
        achievementsUnlocked: Int,
        achievementsTotal: Int,
        aiBackendName: String,
        aiBackendAvailable: Bool,
        aiModel: String
    ) {
        let gameData = WidgetGameData(
            adventureName: adventureName,
            actionCount: actionCount,
            lastAction: lastAction,
            achievementsUnlocked: achievementsUnlocked,
            achievementsTotal: achievementsTotal,
            aiBackend: WidgetGameData.AIBackendInfo(
                name: aiBackendName,
                isAvailable: aiBackendAvailable,
                model: aiModel
            ),
            lastUpdate: Date()
        )
        saveGameData(gameData)
    }
}
