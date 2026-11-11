//
//  AIBackendManagerTests.swift
//  BlompieTests
//
//  Tests for AIBackendManager configuration, Keychain services,
//  the canonical backend enum and its legacy migration, and error types.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

// MARK: - Backend Enum Tests (canonical LLMBackendType; the nested 10-case
// AIBackendManager.AIBackend with throwing cloud stubs was removed in 1.2.0)

final class AIBackendEnumTests: XCTestCase {

    func testAllBackendCases() {
        XCTAssertEqual(LLMBackendType.allCases.count, 9)
        XCTAssertEqual(LLMBackendType.concrete.count, 8)
        XCTAssertFalse(LLMBackendType.concrete.contains(.auto))
    }

    func testBackendRawValues() {
        XCTAssertEqual(LLMBackendType.auto.rawValue, "auto")
        XCTAssertEqual(LLMBackendType.ollama.rawValue, "ollama")
        XCTAssertEqual(LLMBackendType.mlx.rawValue, "mlx")
        XCTAssertEqual(LLMBackendType.tinyLLM.rawValue, "tinyllm")
        XCTAssertEqual(LLMBackendType.tinyChat.rawValue, "tinychat")
        XCTAssertEqual(LLMBackendType.openWebUI.rawValue, "openwebui")
        XCTAssertEqual(LLMBackendType.novaGateway.rawValue, "novagateway")
        XCTAssertEqual(LLMBackendType.openRouter.rawValue, "openrouter")
        XCTAssertEqual(LLMBackendType.openAI.rawValue, "openai")
    }

    func testBackendDescriptions() {
        for backend in LLMBackendType.allCases {
            XCTAssertFalse(backend.description.isEmpty, "\(backend.rawValue) should have a description")
            XCTAssertFalse(backend.displayName.isEmpty)
            XCTAssertFalse(backend.icon.isEmpty)
        }
    }

    func testBackendSetupInstructions() {
        // Every concrete network backend has a default URL; cloud defaults are https.
        for backend in LLMBackendType.concrete where backend != .mlx {
            XCTAssertTrue(EndpointPolicy.isValidBaseURL(backend.defaultURL), backend.rawValue)
        }
        XCTAssertTrue(LLMBackendType.openRouter.defaultURL.hasPrefix("https://"))
        XCTAssertTrue(LLMBackendType.openAI.defaultURL.hasPrefix("https://"))
    }

    func testOllamaBackendFromRawValue() {
        XCTAssertEqual(LLMBackendType(rawValue: "ollama"), .ollama)
        // Values persisted by <= 1.1.2 (display-name raw values) migrate.
        XCTAssertEqual(LLMBackendType.migrating("Ollama"), .ollama)
        XCTAssertEqual(LLMBackendType.migrating("MLX Toolkit"), .mlx)
        XCTAssertEqual(LLMBackendType.migrating("TinyLLM"), .tinyLLM)
        XCTAssertEqual(LLMBackendType.migrating("TinyChat"), .tinyChat)
        XCTAssertEqual(LLMBackendType.migrating("OpenWebUI"), .openWebUI)
        XCTAssertEqual(LLMBackendType.migrating("OpenAI"), .openAI)
    }

    func testInvalidBackendRawValue() {
        XCTAssertNil(LLMBackendType(rawValue: "NotABackend"))
        // Removed stubs and junk fall back to Auto.
        for removed in ["Google Cloud AI", "Microsoft Azure", "AWS AI Services", "IBM Watson", "NotABackend", ""] {
            XCTAssertEqual(LLMBackendType.migrating(removed), .auto, removed)
        }
        XCTAssertEqual(LLMBackendType.migrating(nil), .auto)
    }
}

// MARK: - LLMError Tests (AIError was folded into the canonical LLMError)

final class AIErrorTests: XCTestCase {

    func testNoBackendAvailableError() {
        let error = LLMError.noBackendAvailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("No LLM backend"))
    }

    func testInvalidURLError() {
        let error = LLMError.invalidURL
        XCTAssertTrue(error.errorDescription!.contains("Invalid"))
    }

    func testInvalidResponseError() {
        XCTAssertNotNil(LLMError.invalidResponse.errorDescription)
    }

    func testHTTPError() {
        let error = LLMError.httpError(503)
        XCTAssertTrue(error.errorDescription!.contains("503"))
    }

    func testNoResponseError() {
        XCTAssertNotNil(LLMError.noResponse.errorDescription)
    }

    func testMLXNotImplementedError() {
        XCTAssertTrue(LLMError.mlxNotAvailable.errorDescription!.contains("MLX"))
        XCTAssertTrue(LLMError.insecureEndpoint.errorDescription!.contains("https"))
        XCTAssertTrue(LLMError.missingAPIKey.errorDescription!.contains("Keychain"))
        XCTAssertNotNil(LLMError.invalidOutput.errorDescription)
    }
}

// MARK: - AIBackendManager Singleton Tests

@MainActor
final class AIBackendManagerTests: XCTestCase {

    func testSingletonExists() {
        XCTAssertNotNil(AIBackendManager.shared)
    }

    func testSingletonIsSame() {
        XCTAssertTrue(AIBackendManager.shared === AIBackendManager.shared)
    }

    func testDefaultOllamaURL() {
        XCTAssertEqual(AIBackendManager.shared.ollamaServerURL, "http://localhost:11434")
    }

    func testDefaultActiveBackend() throws {
        // A fresh install defaults to AI on + Auto.
        let suite = "com.jordankoch.Blompie.tests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AIBackendManager(defaults: defaults, keychainService: suite,
                                       openRouterKeychain: KeychainStore(service: suite + ".openrouter"),
                                       migrateLegacySecrets: false, probeOnLaunch: false)
        XCTAssertEqual(manager.activeBackend, .auto)
        XCTAssertTrue(manager.aiEnabled)
        // Legacy display-name value persisted by 1.1.x maps to the canonical id.
        defaults.set("MLX Toolkit", forKey: "AIBackend_Active")
        manager.loadConfiguration()
        XCTAssertEqual(manager.activeBackend, .mlx)
    }

    func testKeychainServiceName() {
        // Blompie's own services (not AIStudio's), checked on the live objects.
        XCTAssertEqual(AIBackendManager.keychainServiceName, "com.jordankoch.Blompie")
        XCTAssertEqual(OpenRouterProvider.keychainService, "com.jordankoch.Blompie.openrouter")
        XCTAssertEqual(KeychainStore().service, "com.jordankoch.Blompie.openrouter")
        XCTAssertNotEqual(OpenRouterProvider.keychainService, OpenRouterProvider.legacyKeychainService)
    }
}

// MARK: - Image Generation Error Tests

final class ImageGenerationErrorTests: XCTestCase {

    func testNoBackendAvailableError() {
        let error = ServiceImageGenerationError.noBackendAvailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("No image generation"))
    }

    func testInvalidURLError() {
        let error = ServiceImageGenerationError.invalidURL
        XCTAssertNotNil(error.errorDescription)
    }

    func testInvalidResponseError() {
        let error = ServiceImageGenerationError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
    }

    func testHTTPErrorDescription() {
        let error = ServiceImageGenerationError.httpError(500)
        XCTAssertTrue(error.errorDescription!.contains("500"))
    }

    func testNoImageGeneratedError() {
        let error = ServiceImageGenerationError.noImageGenerated
        XCTAssertNotNil(error.errorDescription)
    }

    func testNotImplementedError() {
        let error = ServiceImageGenerationError.notImplemented("ComfyUI coming soon")
        XCTAssertEqual(error.errorDescription, "ComfyUI coming soon")
    }
}

// MARK: - Image Style & Size Tests

final class ImageStyleTests: XCTestCase {

    func testAllImageStyleCases() {
        XCTAssertEqual(ServiceImageStyle.allCases.count, 6)
    }

    func testImageStyleRawValues() {
        XCTAssertEqual(ServiceImageStyle.realistic.rawValue, "Realistic")
        XCTAssertEqual(ServiceImageStyle.artistic.rawValue, "Artistic")
        XCTAssertEqual(ServiceImageStyle.fantasy.rawValue, "Fantasy")
        XCTAssertEqual(ServiceImageStyle.pixelArt.rawValue, "Pixel Art")
        XCTAssertEqual(ServiceImageStyle.cartoon.rawValue, "Cartoon")
        XCTAssertEqual(ServiceImageStyle.anime.rawValue, "Anime")
    }

    func testImageSizeDimensions() {
        XCTAssertEqual(ServiceImageSize.square512.width, 512)
        XCTAssertEqual(ServiceImageSize.square512.height, 512)
        XCTAssertEqual(ServiceImageSize.square1024.width, 1024)
        XCTAssertEqual(ServiceImageSize.square1024.height, 1024)
        XCTAssertEqual(ServiceImageSize.portrait.width, 768)
        XCTAssertEqual(ServiceImageSize.portrait.height, 1024)
        XCTAssertEqual(ServiceImageSize.landscape.width, 1024)
        XCTAssertEqual(ServiceImageSize.landscape.height, 768)
    }
}
