//
//  GameEngineTests.swift
//  BlompieTests
//
//  Unit tests for the core GameEngine: models, save/load, undo, achievements,
//  response parsing, NPC/inventory/location tracking, and settings.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

// MARK: - Model Codable Tests

final class GameModelTests: XCTestCase {

    // MARK: GameMessage

    func testGameMessageInit() {
        let msg = GameMessage(text: "Hello world")
        XCTAssertFalse(msg.id.uuidString.isEmpty)
        XCTAssertEqual(msg.text, "Hello world")
        XCTAssertNotNil(msg.timestamp)
    }

    func testGameMessageCodable() throws {
        let original = GameMessage(text: "You enter a cave")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GameMessage.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.text, original.text)
    }

    func testGameMessageEmptyText() {
        let msg = GameMessage(text: "")
        XCTAssertEqual(msg.text, "")
    }

    func testGameMessageUnicodeText() throws {
        let msg = GameMessage(text: "You see a dragon breathing fire 🔥🐉")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GameMessage.self, from: data)
        XCTAssertEqual(decoded.text, msg.text)
    }

    // MARK: OllamaMessage

    func testOllamaMessageCodable() throws {
        let msg = OllamaMessage(role: "system", content: "You are a game master")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(OllamaMessage.self, from: data)
        XCTAssertEqual(decoded.role, "system")
        XCTAssertEqual(decoded.content, "You are a game master")
    }

    // MARK: SaveSlot

    func testSaveSlotCodable() throws {
        let slot = SaveSlot(id: "slot1", name: "My Save", savedDate: Date(), messageCount: 42)
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(SaveSlot.self, from: data)
        XCTAssertEqual(decoded.id, "slot1")
        XCTAssertEqual(decoded.name, "My Save")
        XCTAssertEqual(decoded.messageCount, 42)
    }

    // MARK: GameState

    func testGameStateCodable() throws {
        let messages = [GameMessage(text: "Hello"), GameMessage(text: "World")]
        let history = [OllamaMessage(role: "user", content: "test")]
        let state = GameState(
            messages: messages,
            conversationHistory: history,
            currentActions: ["Go north", "Look around"],
            slotName: "autosave",
            savedDate: Date()
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GameState.self, from: data)
        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.conversationHistory.count, 1)
        XCTAssertEqual(decoded.currentActions.count, 2)
        XCTAssertEqual(decoded.slotName, "autosave")
    }

    // MARK: GameSnapshot

    func testGameSnapshotCodable() throws {
        let snapshot = GameSnapshot(
            messages: [GameMessage(text: "Test")],
            conversationHistory: [OllamaMessage(role: "user", content: "hello")],
            currentActions: ["Act 1"]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(GameSnapshot.self, from: data)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.currentActions, ["Act 1"])
    }

    // MARK: Achievement

    func testAchievementCodable() throws {
        let achievement = Achievement(
            id: "first_step",
            title: "First Steps",
            description: "Take your first action",
            isUnlocked: true,
            unlockDate: Date()
        )
        let data = try JSONEncoder().encode(achievement)
        let decoded = try JSONDecoder().decode(Achievement.self, from: data)
        XCTAssertEqual(decoded.id, "first_step")
        XCTAssertEqual(decoded.title, "First Steps")
        XCTAssertTrue(decoded.isUnlocked)
        XCTAssertNotNil(decoded.unlockDate)
    }

    func testAchievementUnlockedFalse() throws {
        let achievement = Achievement(
            id: "explorer",
            title: "Explorer",
            description: "Visit 5 locations",
            isUnlocked: false,
            unlockDate: nil
        )
        let data = try JSONEncoder().encode(achievement)
        let decoded = try JSONDecoder().decode(Achievement.self, from: data)
        XCTAssertFalse(decoded.isUnlocked)
        XCTAssertNil(decoded.unlockDate)
    }

    // MARK: DetailLevel

    func testDetailLevelAllCases() {
        XCTAssertEqual(DetailLevel.allCases.count, 3)
        XCTAssertEqual(DetailLevel.brief.rawValue, "Brief")
        XCTAssertEqual(DetailLevel.normal.rawValue, "Normal")
        XCTAssertEqual(DetailLevel.detailed.rawValue, "Detailed")
    }

    func testDetailLevelCodable() throws {
        for level in DetailLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(DetailLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    // MARK: ToneStyle

    func testToneStyleAllCases() {
        XCTAssertEqual(ToneStyle.allCases.count, 3)
        XCTAssertEqual(ToneStyle.serious.rawValue, "Serious")
        XCTAssertEqual(ToneStyle.balanced.rawValue, "Balanced")
        XCTAssertEqual(ToneStyle.whimsical.rawValue, "Whimsical")
    }

    func testToneStyleCodable() throws {
        for tone in ToneStyle.allCases {
            let data = try JSONEncoder().encode(tone)
            let decoded = try JSONDecoder().decode(ToneStyle.self, from: data)
            XCTAssertEqual(decoded, tone)
        }
    }
}

// MARK: - GameEngine Core Tests

@MainActor
final class GameEngineTests: XCTestCase {

    var engine: GameEngine!

    override func setUp() async throws {
        // Clear persisted settings BEFORE constructing the engine so it loads
        // code defaults (mirrors a clean first launch). Must include the
        // consolidated "BlompieSettingsBundle" key that GameEngine reads first,
        // otherwise a bundle persisted by another test (shared UserDefaults in
        // the same process) leaks in and breaks the default-value assertions.
        let testKeys = [
            "BlompieSettingsBundle",
            "BlompieFontSize", "BlompieStreamingEnabled", "BlompieTemperature",
            "BlompieDetailLevel", "BlompieToneStyle", "BlompieAutoSaveEnabled",
            "BlompieSelectedModel", "BlompieRandomModelMode",
            "BlompieActionsUntilModelSwitch", "BlompieColorTheme",
            "BlompieAchievements", "BlompieSaveSlots"
        ]
        for key in testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        engine = GameEngine()
    }

    // MARK: Initial State

    func testInitialState() {
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertTrue(engine.currentActions.isEmpty)
        XCTAssertFalse(engine.isLoading)
        XCTAssertEqual(engine.streamingText, "")
        XCTAssertEqual(engine.selectedModel, "mistral")
    }

    func testDefaultSettings() {
        XCTAssertEqual(engine.fontSize, 14)
        XCTAssertTrue(engine.streamingEnabled)
        XCTAssertEqual(engine.temperature, 1.3)
        XCTAssertEqual(engine.detailLevel, .normal)
        XCTAssertEqual(engine.toneStyle, .balanced)
        XCTAssertTrue(engine.autoSaveEnabled)
        XCTAssertFalse(engine.randomModelMode)
        XCTAssertEqual(engine.actionsUntilModelSwitch, 5)
    }

    // MARK: Settings Persistence

    func testSaveAndLoadSettings() {
        engine.fontSize = 18
        engine.streamingEnabled = false
        engine.temperature = 0.8
        engine.detailLevel = .detailed
        engine.toneStyle = .whimsical
        engine.autoSaveEnabled = false
        engine.selectedModel = "llama3.2"
        engine.randomModelMode = true
        engine.actionsUntilModelSwitch = 10
        engine.saveSettings()

        // Create new engine to test loading
        let engine2 = GameEngine()
        XCTAssertEqual(engine2.fontSize, 18)
        XCTAssertFalse(engine2.streamingEnabled)
        XCTAssertEqual(engine2.temperature, 0.8, accuracy: 0.01)
        XCTAssertEqual(engine2.detailLevel, .detailed)
        XCTAssertEqual(engine2.toneStyle, .whimsical)
        XCTAssertFalse(engine2.autoSaveEnabled)
        XCTAssertEqual(engine2.selectedModel, "llama3.2")
        XCTAssertTrue(engine2.randomModelMode)
        XCTAssertEqual(engine2.actionsUntilModelSwitch, 10)
    }

    func testResetSettings() {
        engine.fontSize = 20
        engine.temperature = 0.5
        engine.detailLevel = .detailed
        engine.toneStyle = .serious
        engine.saveSettings()

        engine.resetSettings()
        XCTAssertEqual(engine.fontSize, 14)
        XCTAssertEqual(engine.temperature, 1.3, accuracy: 0.01)
        XCTAssertEqual(engine.detailLevel, .normal)
        XCTAssertEqual(engine.toneStyle, .balanced)
        XCTAssertTrue(engine.streamingEnabled)
        XCTAssertTrue(engine.autoSaveEnabled)
        XCTAssertFalse(engine.randomModelMode)
    }

    // MARK: Theme

    func testSetTheme() {
        engine.setTheme(ColorTheme.amber)
        XCTAssertEqual(engine.currentTheme.id, "amber")
        XCTAssertEqual(engine.currentTheme.name, "Amber Terminal")
    }

    func testThemePersistence() {
        engine.setTheme(ColorTheme.retroBlue)
        let engine2 = GameEngine()
        XCTAssertEqual(engine2.currentTheme.id, "retroBlue")
    }

    // MARK: Stats

    func testGetStatsInitial() {
        let stats = engine.getStats()
        XCTAssertEqual(stats["Total Actions"], "0")
        XCTAssertEqual(stats["NPCs Met"], "0")
        XCTAssertEqual(stats["Items Collected"], "0")
        XCTAssertEqual(stats["Locations Visited"], "0")
        XCTAssertEqual(stats["Current Model"], "mistral")
        XCTAssertEqual(stats["Messages"], "0")
    }

    // MARK: Undo

    func testUndoWithNoHistory() {
        // Should not crash
        engine.undoLastAction()
        XCTAssertTrue(engine.messages.isEmpty)
    }

    // MARK: Export Transcript

    func testExportTranscript() {
        let transcript = engine.exportTranscript()
        XCTAssertTrue(transcript.contains("BLOMPIE GAME TRANSCRIPT"))
        XCTAssertTrue(transcript.contains("Model: mistral"))
        XCTAssertTrue(transcript.contains("Total Messages: 0"))
    }

    // MARK: Achievements

    func testAchievementsInitialized() {
        XCTAssertEqual(engine.achievements.count, 10)
        XCTAssertFalse(engine.achievements.contains { $0.isUnlocked })
    }

    func testAchievementIDs() {
        let expectedIDs = ["first_step", "explorer", "world_traveler", "social",
                           "diplomat", "collector", "hoarder", "conversationalist",
                           "veteran", "trader"]
        for id in expectedIDs {
            XCTAssertTrue(engine.achievements.contains { $0.id == id }, "Missing achievement: \(id)")
        }
    }

    // MARK: Delete All Saves

    func testDeleteAllSaves() {
        // Save something first
        engine.saveGame(toSlot: "test-slot")
        XCTAssertFalse(engine.getSaveSlots().isEmpty)

        engine.deleteAllSaves()
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertTrue(engine.currentActions.isEmpty)
    }
}
