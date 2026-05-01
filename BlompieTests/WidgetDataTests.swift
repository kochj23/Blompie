//
//  WidgetDataTests.swift
//  BlompieTests
//
//  Tests for WidgetGameData model and SharedDataManager logic.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

final class WidgetDataTests: XCTestCase {

    // MARK: - WidgetGameData Codable

    func testWidgetGameDataDefaultInit() {
        let data = WidgetGameData()
        XCTAssertEqual(data.adventureName, "New Adventure")
        XCTAssertEqual(data.actionCount, 0)
        XCTAssertEqual(data.lastAction, "Start your adventure!")
        XCTAssertEqual(data.achievementsUnlocked, 0)
        XCTAssertEqual(data.achievementsTotal, 10)
        XCTAssertEqual(data.aiBackend.name, "Ollama")
        XCTAssertFalse(data.aiBackend.isAvailable)
        XCTAssertEqual(data.aiBackend.model, "mistral")
    }

    func testWidgetGameDataCodable() throws {
        let gameData = WidgetGameData(
            adventureName: "Dragon's Lair",
            actionCount: 42,
            lastAction: "Open the chest",
            achievementsUnlocked: 5,
            achievementsTotal: 10,
            aiBackend: WidgetGameData.AIBackendInfo(
                name: "Ollama",
                isAvailable: true,
                model: "mistral:latest"
            ),
            lastUpdate: Date()
        )
        let encoded = try JSONEncoder().encode(gameData)
        let decoded = try JSONDecoder().decode(WidgetGameData.self, from: encoded)
        XCTAssertEqual(decoded.adventureName, "Dragon's Lair")
        XCTAssertEqual(decoded.actionCount, 42)
        XCTAssertEqual(decoded.lastAction, "Open the chest")
        XCTAssertEqual(decoded.achievementsUnlocked, 5)
        XCTAssertEqual(decoded.achievementsTotal, 10)
        XCTAssertEqual(decoded.aiBackend.name, "Ollama")
        XCTAssertTrue(decoded.aiBackend.isAvailable)
    }

    // MARK: - Achievement Progress

    func testAchievementProgressZero() {
        let data = WidgetGameData(achievementsUnlocked: 0, achievementsTotal: 10)
        XCTAssertEqual(data.achievementProgress, 0.0)
    }

    func testAchievementProgressHalf() {
        let data = WidgetGameData(achievementsUnlocked: 5, achievementsTotal: 10)
        XCTAssertEqual(data.achievementProgress, 0.5, accuracy: 0.001)
    }

    func testAchievementProgressFull() {
        let data = WidgetGameData(achievementsUnlocked: 10, achievementsTotal: 10)
        XCTAssertEqual(data.achievementProgress, 1.0, accuracy: 0.001)
    }

    func testAchievementProgressZeroTotal() {
        let data = WidgetGameData(achievementsUnlocked: 0, achievementsTotal: 0)
        XCTAssertEqual(data.achievementProgress, 0.0)
    }

    // MARK: - AIBackendInfo

    func testAIBackendInfoCodable() throws {
        let info = WidgetGameData.AIBackendInfo(
            name: "MLX",
            isAvailable: true,
            model: "llama3.2"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(WidgetGameData.AIBackendInfo.self, from: data)
        XCTAssertEqual(decoded.name, "MLX")
        XCTAssertTrue(decoded.isAvailable)
        XCTAssertEqual(decoded.model, "llama3.2")
    }

    // MARK: - SharedDataManager

    func testSharedDataManagerSingleton() {
        let a = SharedDataManager.shared
        let b = SharedDataManager.shared
        XCTAssertTrue(a === b, "SharedDataManager should be a singleton")
    }

    func testAppGroupIdentifier() {
        XCTAssertEqual(SharedDataManager.appGroupIdentifier, "group.com.jkoch.blompie")
    }
}
