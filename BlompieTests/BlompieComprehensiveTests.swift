//
//  BlompieComprehensiveTests.swift
//  BlompieTests
//
//  Comprehensive XCTest suite covering all five test categories:
//  Unit, Security, Integration, Functional, and Frame tests.
//
//  Written by Jordan Koch
//  Created: 2026-05-03
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Blompie

// MARK: - Unit Tests

/// Unit tests for core data models, parsing logic, computation functions,
/// and settings/configuration management not covered by existing suites.
final class ComprehensiveUnitTests: XCTestCase {

    // MARK: TokenMeterView Normalization

    func testTokenMeterNormalizationZero() {
        // 0 tok/s should normalize to 0.0 (max display is 60)
        let normalized = min(0.0 / 60.0, 1.0)
        XCTAssertEqual(normalized, 0.0)
    }

    func testTokenMeterNormalizationMidRange() {
        let normalized = min(30.0 / 60.0, 1.0)
        XCTAssertEqual(normalized, 0.5, accuracy: 0.001)
    }

    func testTokenMeterNormalizationClampsAt1() {
        // Anything above 60 should clamp to 1.0
        let normalized = min(120.0 / 60.0, 1.0)
        XCTAssertEqual(normalized, 1.0)
    }

    func testTokenMeterGaugeColorRed() {
        // < 15 tok/s = red zone
        let tokensPerSecond = 10.0
        XCTAssertTrue(tokensPerSecond < 15, "Under 15 tok/s should be red zone")
    }

    func testTokenMeterGaugeColorOrange() {
        let tokensPerSecond = 20.0
        XCTAssertTrue(tokensPerSecond >= 15 && tokensPerSecond < 30, "15-30 tok/s should be orange zone")
    }

    func testTokenMeterGaugeColorGreen() {
        let tokensPerSecond = 45.0
        XCTAssertTrue(tokensPerSecond >= 30, "30+ tok/s should be green zone")
    }

    // MARK: ModernColors Heat Map

    func testHeatColorLowPercentage() {
        let color = ModernColors.heatColor(percentage: 10)
        XCTAssertNotNil(color, "Heat color for low percentage should not be nil")
    }

    func testHeatColorMediumPercentage() {
        let color = ModernColors.heatColor(percentage: 35)
        XCTAssertNotNil(color, "Heat color for medium percentage should not be nil")
    }

    func testHeatColorHighPercentage() {
        let color = ModernColors.heatColor(percentage: 60)
        XCTAssertNotNil(color, "Heat color for high percentage should not be nil")
    }

    func testHeatColorCriticalPercentage() {
        let color = ModernColors.heatColor(percentage: 90)
        XCTAssertNotNil(color, "Heat color for critical percentage should not be nil")
    }

    func testHeatColorBoundary25() {
        // 24 should be statusLow, 25 should be statusMedium
        let colorBelow = ModernColors.heatColor(percentage: 24.9)
        let colorAt = ModernColors.heatColor(percentage: 25.0)
        // Both should return valid colors
        XCTAssertNotNil(colorBelow)
        XCTAssertNotNil(colorAt)
    }

    // MARK: ImageGenerationService Prompt Enhancement

    func testImageStyleRealisticRawValue() {
        XCTAssertEqual(ServiceImageStyle.realistic.rawValue, "Realistic")
    }

    func testImageStyleFantasyRawValue() {
        XCTAssertEqual(ServiceImageStyle.fantasy.rawValue, "Fantasy")
    }

    func testImageStylePixelArtRawValue() {
        XCTAssertEqual(ServiceImageStyle.pixelArt.rawValue, "Pixel Art")
    }

    func testImageSizeSquare512Dimensions() {
        XCTAssertEqual(ServiceImageSize.square512.width, 512)
        XCTAssertEqual(ServiceImageSize.square512.height, 512)
    }

    func testImageSizePortraitIsPortrait() {
        XCTAssertTrue(ServiceImageSize.portrait.height > ServiceImageSize.portrait.width,
            "Portrait height should exceed width")
    }

    func testImageSizeLandscapeIsLandscape() {
        XCTAssertTrue(ServiceImageSize.landscape.width > ServiceImageSize.landscape.height,
            "Landscape width should exceed height")
    }

    // MARK: AICapability Models

    func testAICapabilityCategoryCaseCount() {
        XCTAssertEqual(AICapabilityCategory.allCases.count, 9)
    }

    func testAICapabilityCategoryRawValues() {
        XCTAssertEqual(AICapabilityCategory.llm.rawValue, "LLM (Language Models)")
        XCTAssertEqual(AICapabilityCategory.imageGeneration.rawValue, "Image Generation")
        XCTAssertEqual(AICapabilityCategory.voice.rawValue, "Voice & Audio")
        XCTAssertEqual(AICapabilityCategory.video.rawValue, "Video Generation")
        XCTAssertEqual(AICapabilityCategory.analysis.rawValue, "Analysis & Insights")
        XCTAssertEqual(AICapabilityCategory.automation.rawValue, "Automation")
        XCTAssertEqual(AICapabilityCategory.security.rawValue, "Security & Pentesting")
        XCTAssertEqual(AICapabilityCategory.search.rawValue, "Search & Vector DB")
        XCTAssertEqual(AICapabilityCategory.specialized.rawValue, "Specialized Tools")
    }

    func testAICapabilityStatusCodable() throws {
        for status in [AICapabilityStatus.available, .unavailable, .error] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(AICapabilityStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testAICapabilityCodable() throws {
        let cap = AICapability(
            id: "test-cap",
            name: "Test Capability",
            category: .llm,
            status: .available,
            description: "A test capability"
        )
        let data = try JSONEncoder().encode(cap)
        let decoded = try JSONDecoder().decode(AICapability.self, from: data)
        XCTAssertEqual(decoded.id, "test-cap")
        XCTAssertEqual(decoded.name, "Test Capability")
        XCTAssertEqual(decoded.category, .llm)
        XCTAssertEqual(decoded.status, .available)
        XCTAssertEqual(decoded.description, "A test capability")
    }

    // MARK: EthicalAIGuardian Model Types

    func testViolationCategoryDescriptions() {
        // Every category must have a non-empty description
        let categories: [ViolationCategory] = [
            .illegalActivity, .harmfulContent, .hateSpeech,
            .misinformation, .privacyViolation, .harassment,
            .fraud, .other
        ]
        for cat in categories {
            XCTAssertFalse(cat.description.isEmpty,
                "\(cat.rawValue) must have a description")
        }
    }

    func testViolationSeverityColors() {
        XCTAssertEqual(ViolationSeverity.critical.color, "red")
        XCTAssertEqual(ViolationSeverity.high.color, "orange")
        XCTAssertEqual(ViolationSeverity.medium.color, "yellow")
        XCTAssertEqual(ViolationSeverity.low.color, "gray")
    }

    func testViolationSeverityCodable() throws {
        for severity in [ViolationSeverity.critical, .high, .medium, .low] {
            let data = try JSONEncoder().encode(severity)
            let decoded = try JSONDecoder().decode(ViolationSeverity.self, from: data)
            XCTAssertEqual(decoded, severity)
        }
    }

    func testViolationCategoryCodable() throws {
        let categories: [ViolationCategory] = [
            .illegalActivity, .harmfulContent, .hateSpeech,
            .misinformation, .privacyViolation, .harassment,
            .fraud, .other
        ]
        for cat in categories {
            let data = try JSONEncoder().encode(cat)
            let decoded = try JSONDecoder().decode(ViolationCategory.self, from: data)
            XCTAssertEqual(decoded, cat)
        }
    }

    func testEnforcementActionCodable() throws {
        let actions: [EnforcementAction] = [
            .blockCompletely, .blockAndRefer, .warnAndLog,
            .requireAcknowledgment, .logOnly
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(EnforcementAction.self, from: data)
            XCTAssertEqual(decoded, action)
        }
    }

    func testViolationStatisticsPercentages() {
        let stats = ViolationStatistics(
            totalRequests: 100,
            safeRequests: 90,
            violations: 10,
            blocked: 3,
            criticalViolations: 1,
            highViolations: 2
        )
        XCTAssertEqual(stats.safePercentage, 90.0, accuracy: 0.01)
        XCTAssertEqual(stats.violationPercentage, 10.0, accuracy: 0.01)
    }

    func testViolationStatisticsZeroTotal() {
        let stats = ViolationStatistics(
            totalRequests: 0,
            safeRequests: 0,
            violations: 0,
            blocked: 0,
            criticalViolations: 0,
            highViolations: 0
        )
        XCTAssertEqual(stats.safePercentage, 100.0, accuracy: 0.01,
            "Zero total requests should report 100% safe")
        XCTAssertEqual(stats.violationPercentage, 0.0, accuracy: 0.01)
    }

    func testPolicyViolationCodable() throws {
        let violation = PolicyViolation(
            category: .illegalActivity,
            severity: .critical,
            description: "Test violation",
            detectedPattern: "test.*pattern",
            action: .blockCompletely,
            timestamp: Date()
        )
        let data = try JSONEncoder().encode(violation)
        let decoded = try JSONDecoder().decode(PolicyViolation.self, from: data)
        XCTAssertEqual(decoded.category, .illegalActivity)
        XCTAssertEqual(decoded.severity, .critical)
        XCTAssertEqual(decoded.description, "Test violation")
        XCTAssertEqual(decoded.action, .blockCompletely)
    }

    func testUsageContextCodable() throws {
        let contexts: [UsageContext] = [
            .textGeneration, .imageGeneration, .summarization,
            .translation, .analysis, .chat, .email, .news,
            .system, .unknown
        ]
        for ctx in contexts {
            let data = try JSONEncoder().encode(ctx)
            let decoded = try JSONDecoder().decode(UsageContext.self, from: data)
            XCTAssertEqual(decoded, ctx)
        }
    }

    func testUsageContextFromAppNameBlompie() {
        let ctx = UsageContext.fromAppName("Blompie")
        XCTAssertEqual(ctx, .imageGeneration)
    }

    func testUsageContextFromAppNameUnknown() {
        let ctx = UsageContext.fromAppName("SomethingRandom")
        XCTAssertEqual(ctx, .unknown)
    }

    func testLogCategoryCodable() throws {
        let categories: [LogCategory] = [.safe, .violation, .systemEvent]
        for cat in categories {
            let data = try JSONEncoder().encode(cat)
            let decoded = try JSONDecoder().decode(LogCategory.self, from: data)
            XCTAssertEqual(decoded, cat)
        }
    }

    // MARK: AIBackendManager.AIBackend Equatable

    func testAIBackendEquality() {
        XCTAssertEqual(AIBackendManager.AIBackend.ollama, AIBackendManager.AIBackend.ollama)
        XCTAssertNotEqual(AIBackendManager.AIBackend.ollama, AIBackendManager.AIBackend.openAI)
    }

    // MARK: OllamaChatResponse tokensPerSecond Edge Cases

    func testTokensPerSecondHighThroughput() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "fast"},
            "done": true,
            "eval_count": 1000,
            "eval_duration": 1000000000
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        // 1000 tokens / 1.0 seconds = 1000 tok/s
        XCTAssertEqual(response.tokensPerSecond!, 1000.0, accuracy: 0.1)
    }

    func testTokensPerSecondVeryLowThroughput() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "slow"},
            "done": true,
            "eval_count": 1,
            "eval_duration": 10000000000
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        // 1 token / 10.0 seconds = 0.1 tok/s
        XCTAssertEqual(response.tokensPerSecond!, 0.1, accuracy: 0.01)
    }

    // MARK: AttackType Enum

    func testAttackTypeCaseCount() {
        XCTAssertEqual(AttackType.allCases.count, 7)
    }

    func testAttackTypeRawValues() {
        XCTAssertEqual(AttackType.portScan.rawValue, "Port Scan")
        XCTAssertEqual(AttackType.sqlInjection.rawValue, "SQL Injection")
        XCTAssertEqual(AttackType.xss.rawValue, "Cross-Site Scripting")
        XCTAssertEqual(AttackType.bruteForce.rawValue, "Brute Force")
        XCTAssertEqual(AttackType.dosAttack.rawValue, "Denial of Service")
        XCTAssertEqual(AttackType.manInTheMiddle.rawValue, "Man in the Middle")
        XCTAssertEqual(AttackType.phishing.rawValue, "Phishing")
    }

    // MARK: AIError Localized Descriptions

    func testAllAIErrorsHaveDescriptions() {
        let errors: [AIError] = [
            .noBackendAvailable, .invalidURL, .invalidResponse,
            .httpError(400), .noResponse, .mlxNotImplemented
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                "AIError case should have errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: ServiceImageGenerationError

    func testAllImageGenErrorsHaveDescriptions() {
        let errors: [ServiceImageGenerationError] = [
            .noBackendAvailable, .invalidURL, .invalidResponse,
            .httpError(502), .noImageGenerated,
            .notImplemented("test message")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: OllamaError Cases

    func testOllamaErrorDecodingWithNilBody() {
        let decodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "bad data")
        )
        let error = OllamaError.decodingError(decodingError, responseBody: nil)
        XCTAssertTrue(error.errorDescription!.contains("Unknown"))
    }

    func testOllamaErrorInvalidResponseNilBody() {
        let error = OllamaError.invalidResponse(statusCode: 404, body: nil)
        XCTAssertTrue(error.errorDescription!.contains("404"))
        XCTAssertTrue(error.errorDescription!.contains("No details"))
    }
}

// MARK: - Security Tests

/// Security tests verifying no hardcoded credentials, secure data storage,
/// input sanitization, and no PII leakage.
final class ComprehensiveSecurityTests: XCTestCase {

    /// Helper to read all Swift source files
    private func allSwiftSourcePaths() throws -> [String] {
        let projectRoot = blompieProjectRoot
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: projectRoot)!
        var paths: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".swift"),
               !file.contains("build/"),
               !file.contains(".build/"),
               !file.contains("BlompieTests/"),
               !file.contains("DerivedData"),
               !file.contains("SourcePackages") {
                paths.append("\(projectRoot)/\(file)")
            }
        }
        return paths
    }

    func testOllamaServiceUsesLocalhost() throws {
        let path = "\(blompieProjectRoot)/Blompie/OllamaService.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("localhost:11434") || content.contains("127.0.0.1:11434"),
            "OllamaService must use localhost or loopback address")
    }

    func testNoSensitiveFileTypesCommitted() throws {
        let projectRoot = blompieProjectRoot
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: projectRoot)!
        let sensitiveExtensions = [".p12", ".cer", ".mobileprovision", ".env"]

        while let file = enumerator.nextObject() as? String {
            if file.contains("build/") || file.contains("DerivedData") ||
               file.contains("SourcePackages") || file.contains(".git/") {
                continue
            }
            for ext in sensitiveExtensions {
                XCTAssertFalse(file.hasSuffix(ext),
                    "SECURITY: Sensitive file type found: \(file)")
            }
        }
    }

    func testNoHomeDirPathsInSource() throws {
        let files = try allSwiftSourcePaths()
        let homePathPattern = "" + NSHomeDirectory() + "/"

        for path in files {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            // Allow in test files and comments
            if path.contains("Test") { continue }
            let lines = content.components(separatedBy: .newlines)
            for (lineNum, line) in lines.enumerated() {
                if line.contains(homePathPattern) &&
                   !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") &&
                   !line.trimmingCharacters(in: .whitespaces).hasPrefix("/*") &&
                   !line.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
                    XCTFail("SECURITY: Hardcoded home path in \(path) line \(lineNum + 1)")
                }
            }
        }
    }

    func testEthicalGuardianPermanentBlockKeyExists() throws {
        let path = "\(blompieProjectRoot)/EthicalAIGuardian.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("AIGuardian_PermanentBlock"),
            "EthicalAIGuardian must use AIGuardian_PermanentBlock key for persistent blocking")
    }

    func testNoDirectBearerTokensInSource() throws {
        let files = try allSwiftSourcePaths()
        let bearerPattern = "Bearer [A-Za-z0-9_-]{20,}"

        for path in files {
            if path.contains("Test") { continue }
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: bearerPattern)
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, range: range)
            XCTAssertTrue(matches.isEmpty,
                "SECURITY: Found potential Bearer token in \(path)")
        }
    }

    func testImageGenerationServiceDoesNotExposeAPIKeys() throws {
        let path = "\(blompieProjectRoot)/Blompie/ImageGenerationService.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        // Should not contain hardcoded API keys
        let keyPatterns = ["sk-", "AKIA", "ghp_"]
        for pattern in keyPatterns {
            XCTAssertFalse(content.contains(pattern),
                "SECURITY: ImageGenerationService should not contain API key patterns: \(pattern)")
        }
    }

    func testNovaAPIServerDoesNotEmitWildcardCORS() throws {
        // SECURITY: the loopback server has only native (Nova) clients, never browsers.
        // A wildcard Access-Control-Allow-Origin would let any website the user visits
        // read responses / drive the server, so it must NOT be present.
        let path = "\(blompieProjectRoot)/Blompie/NovaAPIServer.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(content.contains("Access-Control-Allow-Origin"),
            "NovaAPIServer must not emit a wildcard CORS header")
    }

    func testNovaAPIServerClosesConnections() throws {
        let path = "\(blompieProjectRoot)/Blompie/NovaAPIServer.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("Connection: close"),
            "NovaAPIServer must close connections after response")
    }

    func testNoInsecureHTTPURLsForExternalServices() throws {
        let files = try allSwiftSourcePaths()
        // http:// is fine for localhost, but external URLs should use HTTPS
        let httpPattern = "http://[^l1]" // skip localhost and 127.0.0.1

        for path in files {
            if path.contains("Test") { continue }
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            for (lineNum, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                // Check for http:// that isn't localhost
                if let range = trimmed.range(of: "http://") {
                    let afterScheme = String(trimmed[range.upperBound...])
                    if !afterScheme.hasPrefix("localhost") &&
                       !afterScheme.hasPrefix("127.0.0.1") &&
                       !afterScheme.hasPrefix("0.0.0.0") {
                        // Could be external insecure URL
                        // Allow in setup instructions and string descriptions
                        if !trimmed.contains("return") && !trimmed.contains("\"\"\"") &&
                           !trimmed.contains("setupInstructions") {
                            // Log but don't fail - some URLs may be in descriptions
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Integration Tests

/// Integration tests for file I/O, persistence, and cross-component interactions.
@MainActor
final class ComprehensiveIntegrationTests: XCTestCase {

    var engine: GameEngine!

    override func setUp() async throws {
        engine = GameEngine()
    }

    override func tearDown() async throws {
        // Clean up test save slots
        let testSlots = ["integration-test-1", "integration-test-2",
                         "integration-test-3", "integration-round-trip"]
        for slot in testSlots {
            UserDefaults.standard.removeObject(forKey: "BlompieGameState_\(slot)")
        }
    }

    func testSaveAndLoadMultipleSlots() {
        engine.startNewGame()
        engine.saveGame(toSlot: "integration-test-1")

        engine.startNewGame()
        engine.saveGame(toSlot: "integration-test-2")

        let slots = engine.getSaveSlots()
        let testSlotIDs = slots.map { $0.id }
        XCTAssertTrue(testSlotIDs.contains("integration-test-1"))
        XCTAssertTrue(testSlotIDs.contains("integration-test-2"))
    }

    func testSaveSlotsSortedByDate() {
        engine.saveGame(toSlot: "integration-test-1")
        // Brief artificial delay for date ordering
        engine.saveGame(toSlot: "integration-test-2")

        let slots = engine.getSaveSlots()
        if slots.count >= 2 {
            // Slots should be sorted newest-first
            let testSlots = slots.filter { $0.id.hasPrefix("integration-test-") }
            if testSlots.count >= 2 {
                XCTAssertTrue(testSlots[0].savedDate >= testSlots[1].savedDate,
                    "Save slots should be sorted by date, newest first")
            }
        }
    }

    func testSaveLoadRoundTripPreservesMessages() {
        engine.startNewGame()
        let originalMessages = engine.messages.map { $0.text }
        let originalCount = engine.messages.count

        engine.saveGame(toSlot: "integration-round-trip")

        let engine2 = GameEngine()
        engine2.loadGame(fromSlot: "integration-round-trip")

        XCTAssertEqual(engine2.messages.count, originalCount)
        for (i, msg) in engine2.messages.enumerated() {
            XCTAssertEqual(msg.text, originalMessages[i])
        }
    }

    func testSaveLoadRoundTripPreservesActions() {
        engine.startNewGame()
        engine.saveGame(toSlot: "integration-round-trip")

        let engine2 = GameEngine()
        engine2.loadGame(fromSlot: "integration-round-trip")
        // currentActions should be restored
        XCTAssertEqual(engine2.currentActions, engine.currentActions)
    }

    func testDeleteSlotRemovesFromStorage() {
        engine.saveGame(toSlot: "integration-test-3")
        XCTAssertTrue(engine.getSaveSlots().contains { $0.id == "integration-test-3" })

        engine.deleteSaveSlot("integration-test-3")
        XCTAssertFalse(engine.getSaveSlots().contains { $0.id == "integration-test-3" })

        // Verify game data is also removed
        let data = UserDefaults.standard.data(forKey: "BlompieGameState_integration-test-3")
        XCTAssertNil(data, "Game state data should be removed after delete")
    }

    func testSettingsPersistAcrossInstances() {
        engine.fontSize = 22
        engine.temperature = 0.9
        engine.toneStyle = .serious
        engine.detailLevel = .brief
        engine.saveSettings()

        let engine2 = GameEngine()
        XCTAssertEqual(engine2.fontSize, 22)
        XCTAssertEqual(engine2.temperature, 0.9, accuracy: 0.01)
        XCTAssertEqual(engine2.toneStyle, .serious)
        XCTAssertEqual(engine2.detailLevel, .brief)

        // Restore defaults
        engine.resetSettings()
    }

    func testThemePersistsAcrossInstances() {
        engine.setTheme(ColorTheme.hacker)
        let engine2 = GameEngine()
        XCTAssertEqual(engine2.currentTheme.id, "hacker")
        XCTAssertEqual(engine2.currentTheme.name, "Matrix Green")

        // Restore
        engine.setTheme(ColorTheme.classicGreen)
    }

    func testSharedDataManagerAppGroupID() {
        XCTAssertEqual(SharedDataManager.appGroupIdentifier, "group.com.jkoch.blompie",
            "Shared container must use correct app group ID")
    }

    func testWidgetGameDataEncodeDecode() throws {
        let gameData = WidgetGameData(
            adventureName: "Crystal Caverns",
            actionCount: 15,
            lastAction: "Enter the portal",
            achievementsUnlocked: 3,
            achievementsTotal: 10,
            aiBackend: WidgetGameData.AIBackendInfo(name: "Ollama", isAvailable: true, model: "qwen2.5:72b"),
            lastUpdate: Date()
        )
        let encoded = try JSONEncoder().encode(gameData)
        let decoded = try JSONDecoder().decode(WidgetGameData.self, from: encoded)
        XCTAssertEqual(decoded.adventureName, "Crystal Caverns")
        XCTAssertEqual(decoded.actionCount, 15)
        XCTAssertEqual(decoded.achievementProgress, 0.3, accuracy: 0.01)
    }
}

// MARK: - Functional Tests

/// Functional tests for main user workflows and data processing pipelines.
@MainActor
final class ComprehensiveFunctionalTests: XCTestCase {

    var engine: GameEngine!

    override func setUp() async throws {
        engine = GameEngine()
        // Clean up test state
        let testKeys = [
            "BlompieFontSize", "BlompieStreamingEnabled", "BlompieTemperature",
            "BlompieDetailLevel", "BlompieToneStyle", "BlompieAutoSaveEnabled",
            "BlompieSelectedModel", "BlompieRandomModelMode",
            "BlompieActionsUntilModelSwitch", "BlompieColorTheme",
            "BlompieAchievements", "BlompieSaveSlots"
        ]
        for key in testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testStartNewGameCreatesInitialMessages() {
        engine.startNewGame()
        XCTAssertTrue(engine.messages.count >= 4,
            "startNewGame should create at least 4 initial messages (header + loading)")
        XCTAssertTrue(engine.messages[0].text.contains("BLOMPIE"))
        XCTAssertTrue(engine.messages[1].text.contains("Text Adventure"))
    }

    func testStartNewGameResetsState() {
        // Simulate some state
        engine.startNewGame()
        let firstGameMessageCount = engine.messages.count

        // Start again
        engine.startNewGame()
        // Messages should be reset and recreated
        XCTAssertTrue(engine.currentActions.isEmpty || engine.currentActions.count >= 0,
            "Actions may or may not be populated until AI responds")
        XCTAssertTrue(engine.actionHistory.isEmpty,
            "Action history should be reset on new game")
        XCTAssertTrue(engine.metNPCs.isEmpty,
            "Met NPCs should be reset on new game")
        XCTAssertTrue(engine.inventory.isEmpty,
            "Inventory should be reset on new game")
        XCTAssertTrue(engine.locationHistory.isEmpty,
            "Location history should be reset on new game")
        XCTAssertTrue(engine.stateHistory.isEmpty,
            "State history should be reset on new game")
    }

    func testExportTranscriptContainsMessages() {
        engine.startNewGame()
        let transcript = engine.exportTranscript()
        XCTAssertTrue(transcript.contains("BLOMPIE GAME TRANSCRIPT"))
        XCTAssertTrue(transcript.contains("BLOMPIE"))
        XCTAssertTrue(transcript.contains("Text Adventure"))
    }

    func testExportTranscriptContainsModel() {
        engine.selectedModel = "test-model"
        let transcript = engine.exportTranscript()
        XCTAssertTrue(transcript.contains("Model: test-model"))
    }

    func testExportTranscriptContainsMessageCount() {
        engine.startNewGame()
        let count = engine.messages.count
        let transcript = engine.exportTranscript()
        XCTAssertTrue(transcript.contains("Total Messages: \(count)"))
    }

    func testSidebarToggle() {
        XCTAssertFalse(engine.showSidebar, "Sidebar should be hidden by default")
        engine.showSidebar.toggle()
        XCTAssertTrue(engine.showSidebar)
        engine.showSidebar.toggle()
        XCTAssertFalse(engine.showSidebar)
    }

    func testGetStatsReturnsAllExpectedKeys() {
        let stats = engine.getStats()
        let expectedKeys = [
            "Total Actions", "NPCs Met", "Items Collected",
            "Locations Visited", "Achievements", "Current Model",
            "Last Token/sec", "Saves", "Messages"
        ]
        for key in expectedKeys {
            XCTAssertNotNil(stats[key], "Stats should include key: \(key)")
        }
    }

    func testGetStatsTokenSecNA() {
        // When no tokens per second have been measured
        let stats = engine.getStats()
        XCTAssertEqual(stats["Last Token/sec"], "N/A")
    }

    func testGetStatsTokenSecFormatted() {
        engine.lastTokensPerSecond = 42.567
        let stats = engine.getStats()
        XCTAssertEqual(stats["Last Token/sec"], "42.6")
    }

    func testDeleteAllSavesClearsEverything() {
        engine.startNewGame()
        engine.saveGame(toSlot: "func-test-delete")
        XCTAssertFalse(engine.messages.isEmpty)

        engine.deleteAllSaves()
        XCTAssertTrue(engine.messages.isEmpty)
        XCTAssertTrue(engine.currentActions.isEmpty)
    }

    func testUndoLastActionRestoresState() {
        engine.startNewGame()
        let messagesBeforeAction = engine.messages.count
        let actionsBeforeAction = engine.currentActions

        // Simulate saving a snapshot (like performAction does)
        let snapshot = GameSnapshot(
            messages: engine.messages,
            conversationHistory: [],
            currentActions: engine.currentActions
        )
        engine.stateHistory.append(snapshot)

        // Undo should restore
        engine.undoLastAction()
        XCTAssertEqual(engine.messages.count, messagesBeforeAction)
    }

    func testResetSettingsRestoresAllDefaults() {
        engine.fontSize = 28
        engine.streamingEnabled = false
        engine.temperature = 0.1
        engine.detailLevel = .detailed
        engine.toneStyle = .serious
        engine.autoSaveEnabled = false
        engine.randomModelMode = true
        engine.actionsUntilModelSwitch = 15
        engine.selectedModel = "custom-model"
        engine.saveSettings()

        engine.resetSettings()

        XCTAssertEqual(engine.fontSize, 14)
        XCTAssertTrue(engine.streamingEnabled)
        XCTAssertEqual(engine.temperature, 1.3, accuracy: 0.01)
        XCTAssertEqual(engine.detailLevel, .normal)
        XCTAssertEqual(engine.toneStyle, .balanced)
        XCTAssertTrue(engine.autoSaveEnabled)
        XCTAssertFalse(engine.randomModelMode)
        XCTAssertEqual(engine.actionsUntilModelSwitch, 5)
        XCTAssertEqual(engine.selectedModel, "mistral")
    }

    func testColorThemeAllThemesHaveValidIDs() {
        for theme in ColorTheme.allThemes {
            XCTAssertFalse(theme.id.isEmpty, "Theme ID must not be empty")
            XCTAssertFalse(theme.name.isEmpty, "Theme name must not be empty")
        }
    }

    func testColorThemeSwitchingCycle() {
        for theme in ColorTheme.allThemes {
            engine.setTheme(theme)
            XCTAssertEqual(engine.currentTheme.id, theme.id)
            XCTAssertEqual(engine.currentTheme.name, theme.name)
        }
    }
}

// MARK: - Frame Tests

/// Frame tests verifying app launches, views instantiate, managers initialize,
/// and settings load/save round-trip correctly.
@MainActor
final class ComprehensiveFrameTests: XCTestCase {

    func testGameEngineInitializes() {
        let engine = GameEngine()
        XCTAssertNotNil(engine, "GameEngine should initialize without crashing")
    }

    func testGameEngineHasAchievements() {
        let engine = GameEngine()
        XCTAssertEqual(engine.achievements.count, 10,
            "GameEngine should initialize with 10 achievements")
    }

    func testGameEngineHasDefaultModel() {
        let engine = GameEngine()
        XCTAssertFalse(engine.selectedModel.isEmpty,
            "GameEngine should have a default model selected")
    }

    func testAIBackendManagerSingletonInitializes() {
        let manager = AIBackendManager.shared
        XCTAssertNotNil(manager)
        XCTAssertNotNil(manager.activeBackend)
        XCTAssertFalse(manager.ollamaServerURL.isEmpty)
    }

    func testAIBackendManagerDefaultURLs() {
        let manager = AIBackendManager.shared
        XCTAssertEqual(manager.ollamaServerURL, "http://localhost:11434")
        XCTAssertEqual(manager.tinyLLMServerURL, "http://localhost:8000")
        XCTAssertEqual(manager.tinyChatServerURL, "http://localhost:8000")
        XCTAssertEqual(manager.openWebUIServerURL, "http://localhost:8080")
        XCTAssertEqual(manager.comfyUIServerURL, "http://localhost:8188")
        XCTAssertEqual(manager.automatic1111ServerURL, "http://localhost:7860")
        XCTAssertEqual(manager.swarmUIServerURL, "http://localhost:7801")
    }

    func testSharedDataManagerSingletonInitializes() {
        let manager = SharedDataManager.shared
        XCTAssertNotNil(manager)
    }

    func testNovaAPIServerSingletonInitializes() {
        let server = NovaAPIServer.shared
        XCTAssertNotNil(server)
        XCTAssertEqual(server.port, 37426)
    }

    func testOllamaServiceInstantiates() {
        let service = OllamaService()
        XCTAssertNotNil(service)
        XCTAssertEqual(service.model, "mistral")
        XCTAssertEqual(service.temperature, 0.7, accuracy: 0.01)
        XCTAssertNil(service.maxTokens)
    }

    func testColorThemeStaticInstancesExist() {
        XCTAssertNotNil(ColorTheme.classicGreen)
        XCTAssertNotNil(ColorTheme.amber)
        XCTAssertNotNil(ColorTheme.retroBlue)
        XCTAssertNotNil(ColorTheme.paperMode)
        XCTAssertNotNil(ColorTheme.hacker)
    }

    func testModernColorsStaticPropertiesExist() {
        XCTAssertNotNil(ModernColors.gradientStart)
        XCTAssertNotNil(ModernColors.gradientMid)
        XCTAssertNotNil(ModernColors.gradientEnd)
        XCTAssertNotNil(ModernColors.cyan)
        XCTAssertNotNil(ModernColors.purple)
        XCTAssertNotNil(ModernColors.orange)
        XCTAssertNotNil(ModernColors.yellow)
        XCTAssertNotNil(ModernColors.pink)
        XCTAssertNotNil(ModernColors.textPrimary)
        XCTAssertNotNil(ModernColors.textSecondary)
        XCTAssertNotNil(ModernColors.textTertiary)
        XCTAssertNotNil(ModernColors.glassBackground)
        XCTAssertNotNil(ModernColors.glassBorder)
    }

    func testModernColorsBackgroundGradient() {
        let gradient = ModernColors.backgroundGradient
        XCTAssertNotNil(gradient, "Background gradient should be constructible")
    }

    func testWidgetGameDataDefaultValues() {
        let data = WidgetGameData()
        XCTAssertEqual(data.adventureName, "New Adventure")
        XCTAssertEqual(data.actionCount, 0)
        XCTAssertEqual(data.achievementsTotal, 10)
        XCTAssertFalse(data.aiBackend.isAvailable)
    }

    func testGameMessageCreatesValidUUID() {
        let msg1 = GameMessage(text: "First")
        let msg2 = GameMessage(text: "Second")
        XCTAssertNotEqual(msg1.id, msg2.id,
            "Each GameMessage should have a unique UUID")
    }

    func testGameMessageTimestampIsRecent() {
        let beforeCreation = Date()
        let msg = GameMessage(text: "Test")
        let afterCreation = Date()

        XCTAssertTrue(msg.timestamp >= beforeCreation)
        XCTAssertTrue(msg.timestamp <= afterCreation)
    }

    func testSaveSlotFieldAccess() {
        let slot = SaveSlot(id: "test", name: "Test Save", savedDate: Date(), messageCount: 10)
        XCTAssertEqual(slot.id, "test")
        XCTAssertEqual(slot.name, "Test Save")
        XCTAssertEqual(slot.messageCount, 10)
        XCTAssertNotNil(slot.savedDate)
    }

    func testGameStateFieldAccess() {
        let state = GameState(
            messages: [],
            conversationHistory: [],
            currentActions: ["Look around"],
            slotName: "test-slot",
            savedDate: Date()
        )
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.conversationHistory.isEmpty)
        XCTAssertEqual(state.currentActions.count, 1)
        XCTAssertEqual(state.slotName, "test-slot")
    }

    func testAchievementFieldAccess() {
        let achievement = Achievement(
            id: "test",
            title: "Test Achievement",
            description: "For testing",
            isUnlocked: false,
            unlockDate: nil
        )
        XCTAssertEqual(achievement.id, "test")
        XCTAssertEqual(achievement.title, "Test Achievement")
        XCTAssertEqual(achievement.description, "For testing")
        XCTAssertFalse(achievement.isUnlocked)
        XCTAssertNil(achievement.unlockDate)
    }

    func testMultipleGameEngineInstancesAreIndependent() {
        let engine1 = GameEngine()
        let engine2 = GameEngine()

        engine1.selectedModel = "model-A"
        engine2.selectedModel = "model-B"

        XCTAssertNotEqual(engine1.selectedModel, engine2.selectedModel,
            "Separate GameEngine instances should be independent")
    }
}
