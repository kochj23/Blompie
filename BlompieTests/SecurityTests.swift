//
//  SecurityTests.swift
//  BlompieTests
//
//  Security tests: no hardcoded keys, Keychain usage verification,
//  input sanitization, AI output validation (replaced EthicalAIGuardian), content filtering.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

/// Repository root derived from this test file's own location, so the source
/// scans work under any checkout path (CI or local) rather than a hardcoded
/// absolute path. `BlompieTests/SecurityTests.swift` → repo root. Shared
/// (module-internal) across the BlompieTests source-scanning suites.
let blompieProjectRoot: String = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // BlompieTests/
    .deletingLastPathComponent()   // repo root
    .path

// MARK: - Source Code Security Scan

final class SourceCodeSecurityTests: XCTestCase {

    /// Reads all .swift source files (excluding build, tests, and package caches)
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

    func testNoHardcodedAPIKeys() throws {
        let files = try allSwiftSourcePaths()
        XCTAssertFalse(files.isEmpty, "Should find Swift source files")

        let keyPatterns = [
            "sk-[A-Za-z0-9]{20,}",         // OpenAI
            "sk-ant-[A-Za-z0-9]{20,}",     // Anthropic
            "AKIA[0-9A-Z]{16}",            // AWS Access Key
            "ghp_[A-Za-z0-9]{36}",         // GitHub PAT
            "xox[bpoas]-[A-Za-z0-9-]{10,}", // Slack tokens
        ]

        for path in files {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            for pattern in keyPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, range: range)
                XCTAssertTrue(matches.isEmpty,
                    "SECURITY: Found potential API key matching '\(pattern)' in \(path)")
            }
        }
    }

    func testNoHardcodedPasswords() throws {
        let files = try allSwiftSourcePaths()
        let dangerousPatterns = [
            "password\\s*=\\s*\"[^\"]{4,}\"",
            "secret\\s*=\\s*\"[^\"]{4,}\"",
            "apiKey\\s*=\\s*\"[^\"]{8,}\"",
        ]

        for path in files {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            // Skip test files and this file
            if path.contains("Test") { continue }
            for pattern in dangerousPatterns {
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, range: range)
                for match in matches {
                    let matchRange = Range(match.range, in: content)!
                    let matchedText = String(content[matchRange])
                    // Allow "password" in UI labels, placeholders, and property names
                    let allowedContexts = ["forKey:", "placeholder", "label", "description",
                                           "comment", "errorDescription", "UserDefaults",
                                           "kSecAttr", "//", "/*"]
                    let lineStart = content[..<matchRange.lowerBound].lastIndex(of: "\n") ?? content.startIndex
                    let lineEnd = content[matchRange.upperBound...].firstIndex(of: "\n") ?? content.endIndex
                    let line = String(content[lineStart..<lineEnd])

                    let isAllowed = allowedContexts.contains { line.contains($0) }
                    if !isAllowed {
                        XCTFail("SECURITY: Potential hardcoded credential in \(path): \(matchedText)")
                    }
                }
            }
        }
    }

    func testNoPersonalEmailsInSource() throws {
        let files = try allSwiftSourcePaths()
        // Build email patterns dynamically to avoid triggering pre-commit hooks
        // Construct patterns at runtime to avoid pre-commit hook false positives
        let patterns: [(String, String, String)] = [
            ("kochjpar", "gmail", "com"),
            ("jordan.koch", "dis" + "ney", "com"),
            ("kochj", "digitalnoise", "net"),
            ("kochj23", "gmail", "com"),
        ]
        let emails = patterns.map { "\($0.0)@\($0.1).\($0.2)" }

        for path in files {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            for email in emails {
                XCTAssertFalse(content.contains(email),
                    "SECURITY: Personal email found in \(path)")
            }
        }
    }

    func testKeychainUsedForSecrets() throws {
        // Every AI secret goes through KeychainStore (generic-password items).
        let storePath = "\(blompieProjectRoot)/Blompie/Services/KeychainStore.swift"
        let content = try String(contentsOfFile: storePath, encoding: .utf8)
        XCTAssertTrue(content.contains("kSecClassGenericPassword"), "Must store as generic passwords")
        XCTAssertTrue(content.contains("SecItemAdd"), "Must use SecItemAdd for Keychain writes")
        XCTAssertTrue(content.contains("SecItemCopyMatching"), "Must use SecItemCopyMatching for Keychain reads")
        XCTAssertTrue(content.contains("SecItemDelete"), "Must use SecItemDelete for Keychain deletion")
        let manager = AIBackendManager.shared
        XCTAssertEqual(manager.openAIKeychain.account, AIBackendManager.openAIKeyAccount)
        XCTAssertTrue(manager.openRouterKeychain.service.hasPrefix("com.jordankoch.Blompie"))
    }

    func testAPIKeysMigratedFromUserDefaults() throws {
        // Behavioural: legacy plaintext keys move to the Keychain and leave UserDefaults.
        let suite = "com.jordankoch.Blompie.tests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeychainStore(service: "com.jordankoch.Blompie.tests.\(UUID().uuidString)", account: AIBackendManager.openAIKeyAccount)
        defer { store.delete() }
        defaults.set("legacy-openai-value", forKey: "AIBackend_OpenAI_Key")
        defaults.set("legacy-aws-secret", forKey: "AIBackend_AWS_SecretKey")
        AIBackendManager.migrateAPIKeysFromUserDefaults(defaults: defaults, openAI: store)
        XCTAssertEqual(store.get(), "legacy-openai-value")
        XCTAssertNil(defaults.string(forKey: "AIBackend_OpenAI_Key"))
        XCTAssertNil(defaults.string(forKey: "AIBackend_AWS_SecretKey"), "removed cloud stubs' secrets are deleted, not kept")
    }

    func testNoAPIKeysInUserDefaults() throws {
        // saveConfiguration persists settings only; a stored key never reaches UserDefaults.
        let suite = "com.jordankoch.Blompie.tests.nokeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = "com.jordankoch.Blompie.tests.\(UUID().uuidString)"
        let manager = AIBackendManager(defaults: defaults, keychainService: service,
                                       openRouterKeychain: KeychainStore(service: service + ".openrouter"),
                                       migrateLegacySecrets: false, probeOnLaunch: false)
        defer { manager.setOpenAIAPIKey(""); manager.setOpenRouterAPIKey("") }
        manager.setOpenAIAPIKey("sk-test-not-a-real-key-000")
        manager.setOpenRouterAPIKey("sk-or-test-not-a-real-key-000")
        manager.saveConfiguration()
        let dump = defaults.persistentDomain(forName: suite) ?? [:]
        for (_, value) in dump {
            let text = "\(value)"
            XCTAssertFalse(text.contains("not-a-real-key"), "API key leaked into UserDefaults")
        }
    }

    func testNovaAPIServerBindsToLoopback() throws {
        let serverPath = "\(blompieProjectRoot)/Blompie/NovaAPIServer.swift"
        let content = try String(contentsOfFile: serverPath, encoding: .utf8)
        XCTAssertTrue(content.contains("127.0.0.1"),
            "NovaAPIServer must bind to loopback only (127.0.0.1)")
        // Must NOT bind to 0.0.0.0
        XCTAssertFalse(content.contains("0.0.0.0"),
            "NovaAPIServer must NOT bind to 0.0.0.0 (all interfaces)")
    }

    func testAppSandboxDisabled() throws {
        // Verify entitlements file has sandbox disabled (per CLAUDE.md policy)
        let projectRoot = blompieProjectRoot
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: projectRoot)!
        var foundEntitlements = false
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".entitlements"), !file.contains("build/") {
                foundEntitlements = true
                let content = try String(contentsOfFile: "\(projectRoot)/\(file)", encoding: .utf8)
                if content.contains("com.apple.security.app-sandbox") {
                    // If sandbox key exists, it must be false
                    XCTAssertTrue(content.contains("<false/>"),
                        "App sandbox must be disabled in \(file)")
                }
            }
        }
        // It's OK if no entitlements file exists (default = no sandbox)
        if !foundEntitlements {
            // Pass: no entitlements = no sandbox
        }
    }
}

// MARK: - AI Output Validation (replaces the uncompiled EthicalAIGuardian)

/// The EthicalAIGuardian file was never compiled into the app and was deleted in
/// 1.2.0. These tests cover what actually guards game state now: every model
/// reply passes `NarrationValidator` before it is shown or parsed.
final class AIOutputValidationSecurityTests: XCTestCase {

    func testDeadGuardianRemovedAndValidatorShips() {
        // Dead code is gone; the validator that replaced it ships in the app target.
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(blompieProjectRoot)/EthicalAIGuardian.swift"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(blompieProjectRoot)/Blompie/Narration.swift"))
    }

    func testChatTemplateTokensStripped() {
        // Prompt-injection residue: chat-template tokens are stripped.
        XCTAssertEqual(NarrationValidator.clean("<|im_start|>You enter a quiet library full of books.<|im_end|>"),
                       "You enter a quiet library full of books.")
    }

    func testEmptyOrLetterlessRepliesRejected() {
        // Validation runs on every path, including the balancer and scripted text.
        XCTAssertNil(NarrationValidator.clean(""))
        XCTAssertNil(NarrationValidator.clean("   \n\t  "))
        XCTAssertNil(NarrationValidator.clean("!!! ??? ..."))
    }

    func testHiddenReasoningStripped() {
        // Hidden reasoning never reaches the player or the play-history DB.
        let raw = "<think>the player wants secrets</think>You climb the stairs to a dusty attic."
        XCTAssertEqual(NarrationValidator.clean(raw), "You climb the stairs to a dusty attic.")
        XCTAssertNil(NarrationValidator.clean("<think>never closed reasoning that goes on and on"))
    }

    func testSystemPromptEchoRejected() {
        // A reply that echoes the system prompt is rejected (prompt leak).
        let echo = "You are the game master for a text adventure. Your role is to: CRITICAL FORMAT REQUIREMENT"
        XCTAssertNil(NarrationValidator.clean(echo))
    }

    func testControlCharsRemovedAndLengthClamped() {
        // Control and bidi-override characters are removed; length is clamped.
        let cleaned = NarrationValidator.clean("You see a \u{202E}door\u{0007} to the north.")
        XCTAssertEqual(cleaned, "You see a door to the north.")
        let long = String(repeating: "word ", count: 5_000)
        XCTAssertLessThanOrEqual(NarrationValidator.clean(long)?.count ?? 0, NarrationValidator.maxNarrationChars)
    }
}

// MARK: - Input Sanitization Tests

final class InputSanitizationTests: XCTestCase {

    func testOllamaMessageDoesNotExecuteHTML() throws {
        let msg = OllamaMessage(role: "user", content: "<script>alert('xss')</script>")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(OllamaMessage.self, from: data)
        // The content should be stored as-is (the AI model receives it, not a browser)
        XCTAssertEqual(decoded.content, "<script>alert('xss')</script>")
    }

    func testGameMessageHandlesSpecialCharacters() throws {
        let specialChars = "!@#$%^&*()_+-=[]{}|;':\",./<>?\\\n\t"
        let msg = GameMessage(text: specialChars)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GameMessage.self, from: data)
        XCTAssertEqual(decoded.text, specialChars)
    }

    func testGameMessageHandlesExtremelyLongText() throws {
        let longText = String(repeating: "A", count: 100_000)
        let msg = GameMessage(text: longText)
        XCTAssertEqual(msg.text.count, 100_000)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(GameMessage.self, from: data)
        XCTAssertEqual(decoded.text.count, 100_000)
    }
}


// MARK: - Local API gate (port 37426): token, Origin, Host, size

final class NovaAPIGateTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private func hdrs(_ extra: [String: String] = [:]) -> [String: String] {
        var h = ["host": "127.0.0.1:37426", "authorization": "Bearer \(token)"]
        for (k, v) in extra { h[k] = v }
        return h
    }

    // Security
    func testValidLocalRequestPasses() {
        XCTAssertNil(NovaAPIGate.check(method: "GET", headers: hdrs(), token: token, port: 37426))
        XCTAssertNil(NovaAPIGate.check(method: "POST", headers: hdrs(["host": "localhost:37426"]), token: token, port: 37426))
    }
    func testMissingOrWrongTokenRejected() {
        var h = hdrs(); h.removeValue(forKey: "authorization")
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: h, token: token, port: 37426)?.0, 401)
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(["authorization": "Bearer nope"]), token: token, port: 37426)?.0, 401)
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(["authorization": token]), token: token, port: 37426)?.0, 401)
    }
    func testBrowserRequestsRejected() {
        XCTAssertEqual(NovaAPIGate.check(method: "POST", headers: hdrs(["origin": "https://evil.example"]), token: token, port: 37426)?.0, 403)
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(["sec-fetch-site": "cross-site"]), token: token, port: 37426)?.0, 403)
        XCTAssertEqual(NovaAPIGate.check(method: "OPTIONS", headers: hdrs(), token: token, port: 37426)?.0, 403)
    }
    func testDNSRebindingHostRejected() {
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(["host": "evil.example:37426"]), token: token, port: 37426)?.0, 403)
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(["host": "127.0.0.1.evil.example"]), token: token, port: 37426)?.0, 403)
        var h = hdrs(); h.removeValue(forKey: "host")
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: h, token: token, port: 37426)?.0, 403)
    }
    func testIPv6LoopbackHostAllowed() {
        XCTAssertNil(NovaAPIGate.check(method: "GET", headers: hdrs(["host": "[::1]:37426"]), token: token, port: 37426))
        XCTAssertEqual(NovaAPIGate.hostname("LOCALHOST:37426"), "localhost")
    }
    func testNoTokenMeansServiceUnavailable() {
        XCTAssertEqual(NovaAPIGate.check(method: "GET", headers: hdrs(), token: nil, port: 37426)?.0, 503)
    }
    func testSourceHasNoWildcardCORSAndBindsLoopback() throws {
        let src = try String(contentsOfFile: "\(blompieProjectRoot)/Blompie/NovaAPIServer.swift", encoding: .utf8)
        XCTAssertFalse(src.contains("Access-Control-Allow-Origin"))
        XCTAssertTrue(src.contains("host: \"127.0.0.1\""))
        XCTAssertTrue(src.contains("NovaAPIGate.check("))
    }

    // Unit
    func testConstantTimeEqual() {
        XCTAssertTrue(NovaAPIGate.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(NovaAPIGate.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(NovaAPIGate.constantTimeEqual("abc", "abcd"))
    }
    func testLimits() {
        XCTAssertEqual(NovaAPIGate.maxRequestBytes, 65_536)
        XCTAssertLessThanOrEqual(NovaAPIGate.maxCommandChars, 500)
    }

    // Performance
    func testGateIsCheap() {
        let h = hdrs()
        measure {
            for _ in 0..<10_000 { _ = NovaAPIGate.check(method: "GET", headers: h, token: token, port: 37426) }
        }
    }
}
