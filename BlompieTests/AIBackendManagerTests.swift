//
//  AIBackendManagerTests.swift
//  BlompieTests
//
//  Tests for AIBackendManager configuration, Keychain helpers,
//  backend enum cases, and error types.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

// MARK: - AIBackend Enum Tests

final class AIBackendEnumTests: XCTestCase {

    func testAllBackendCases() {
        let allCases = AIBackendManager.AIBackend.allCases
        XCTAssertEqual(allCases.count, 10)
    }

    func testBackendRawValues() {
        XCTAssertEqual(AIBackendManager.AIBackend.ollama.rawValue, "Ollama")
        XCTAssertEqual(AIBackendManager.AIBackend.mlx.rawValue, "MLX Toolkit")
        XCTAssertEqual(AIBackendManager.AIBackend.tinyLLM.rawValue, "TinyLLM")
        XCTAssertEqual(AIBackendManager.AIBackend.tinyChat.rawValue, "TinyChat")
        XCTAssertEqual(AIBackendManager.AIBackend.openWebUI.rawValue, "OpenWebUI")
        XCTAssertEqual(AIBackendManager.AIBackend.openAI.rawValue, "OpenAI")
        XCTAssertEqual(AIBackendManager.AIBackend.googleCloud.rawValue, "Google Cloud AI")
        XCTAssertEqual(AIBackendManager.AIBackend.azureCognitive.rawValue, "Microsoft Azure")
        XCTAssertEqual(AIBackendManager.AIBackend.awsAI.rawValue, "AWS AI Services")
        XCTAssertEqual(AIBackendManager.AIBackend.ibmWatson.rawValue, "IBM Watson")
    }

    func testBackendDescriptions() {
        for backend in AIBackendManager.AIBackend.allCases {
            XCTAssertFalse(backend.description.isEmpty,
                "\(backend.rawValue) should have a description")
        }
    }

    func testBackendSetupInstructions() {
        for backend in AIBackendManager.AIBackend.allCases {
            XCTAssertFalse(backend.setupInstructions.isEmpty,
                "\(backend.rawValue) should have setup instructions")
        }
    }

    func testOllamaBackendFromRawValue() {
        let backend = AIBackendManager.AIBackend(rawValue: "Ollama")
        XCTAssertEqual(backend, .ollama)
    }

    func testInvalidBackendRawValue() {
        let backend = AIBackendManager.AIBackend(rawValue: "NotABackend")
        XCTAssertNil(backend)
    }
}

// MARK: - AIError Tests

final class AIErrorTests: XCTestCase {

    func testNoBackendAvailableError() {
        let error = AIError.noBackendAvailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("No AI backend"))
    }

    func testInvalidURLError() {
        let error = AIError.invalidURL
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Invalid"))
    }

    func testInvalidResponseError() {
        let error = AIError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
    }

    func testHTTPError() {
        let error = AIError.httpError(503)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("503"))
    }

    func testNoResponseError() {
        let error = AIError.noResponse
        XCTAssertNotNil(error.errorDescription)
    }

    func testMLXNotImplementedError() {
        let error = AIError.mlxNotImplemented
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("MLX"))
    }
}

// MARK: - AIBackendManager Singleton Tests

@MainActor
final class AIBackendManagerTests: XCTestCase {

    func testSingletonExists() {
        let manager = AIBackendManager.shared
        XCTAssertNotNil(manager)
    }

    func testSingletonIsSame() {
        let a = AIBackendManager.shared
        let b = AIBackendManager.shared
        XCTAssertTrue(a === b)
    }

    func testDefaultOllamaURL() {
        let manager = AIBackendManager.shared
        XCTAssertEqual(manager.ollamaServerURL, "http://localhost:11434")
    }

    func testDefaultActiveBackend() {
        // After loading configuration, activeBackend should be set
        let manager = AIBackendManager.shared
        XCTAssertNotNil(manager.activeBackend)
    }

    func testKeychainServiceName() {
        // Verify the Keychain service name is correct for Blompie
        // This is tested indirectly -- the manager must use "com.jordankoch.Blompie"
        let backendPath = "/Volumes/Data/xcode/Blompie/AIBackendManager.swift"
        do {
            let content = try String(contentsOfFile: backendPath, encoding: .utf8)
            XCTAssertTrue(content.contains("com.jordankoch.Blompie"),
                "Keychain service name must be 'com.jordankoch.Blompie'")
        } catch {
            XCTFail("Could not read AIBackendManager.swift: \(error)")
        }
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
