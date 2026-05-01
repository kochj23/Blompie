//
//  OllamaServiceTests.swift
//  BlompieTests
//
//  Unit tests for OllamaService models, request/response codable contracts,
//  and OllamaError descriptions.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

final class OllamaServiceTests: XCTestCase {

    // MARK: - OllamaMessage Codable

    func testOllamaMessageEncodeDecode() throws {
        let msg = OllamaMessage(role: "user", content: "Hello")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(OllamaMessage.self, from: data)
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Hello")
    }

    func testOllamaMessageRoles() throws {
        let roles = ["system", "user", "assistant"]
        for role in roles {
            let msg = OllamaMessage(role: role, content: "test")
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(OllamaMessage.self, from: data)
            XCTAssertEqual(decoded.role, role)
        }
    }

    // MARK: - OllamaChatRequest Codable

    func testOllamaChatRequestEncode() throws {
        let request = OllamaChatRequest(
            model: "mistral",
            messages: [OllamaMessage(role: "user", content: "test")],
            stream: false,
            options: OllamaOptions(temperature: 0.7, num_predict: 100)
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "mistral")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testOllamaChatRequestWithNilOptions() throws {
        let request = OllamaChatRequest(
            model: "llama3",
            messages: [],
            stream: true,
            options: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "llama3")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    // MARK: - OllamaOptions

    func testOllamaOptionsCodable() throws {
        let options = OllamaOptions(temperature: 1.3, num_predict: 512)
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(OllamaOptions.self, from: data)
        XCTAssertEqual(decoded.temperature, 1.3)
        XCTAssertEqual(decoded.num_predict, 512)
    }

    func testOllamaOptionsNilValues() throws {
        let options = OllamaOptions(temperature: nil, num_predict: nil)
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(OllamaOptions.self, from: data)
        XCTAssertNil(decoded.temperature)
        XCTAssertNil(decoded.num_predict)
    }

    // MARK: - OllamaChatResponse

    func testOllamaChatResponseDecode() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "Hello!"},
            "done": true,
            "eval_count": 50,
            "eval_duration": 2000000000,
            "prompt_eval_count": 20,
            "prompt_eval_duration": 500000000
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        XCTAssertEqual(response.message.role, "assistant")
        XCTAssertEqual(response.message.content, "Hello!")
        XCTAssertTrue(response.done)
        XCTAssertEqual(response.eval_count, 50)
    }

    func testTokensPerSecondCalculation() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "test"},
            "done": true,
            "eval_count": 100,
            "eval_duration": 2000000000
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        // 100 tokens / 2.0 seconds = 50 tokens/sec
        XCTAssertEqual(response.tokensPerSecond!, 50.0, accuracy: 0.01)
    }

    func testTokensPerSecondNilWhenNoEvalCount() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "test"},
            "done": true
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        XCTAssertNil(response.tokensPerSecond)
    }

    func testTokensPerSecondNilWhenZeroDuration() throws {
        let json = """
        {
            "message": {"role": "assistant", "content": "test"},
            "done": true,
            "eval_count": 100,
            "eval_duration": 0
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: json)
        XCTAssertNil(response.tokensPerSecond)
    }

    // MARK: - OllamaModel

    func testOllamaModelDecode() throws {
        let json = """
        {
            "name": "mistral:latest",
            "size": 4109853184,
            "modified_at": "2024-01-15T12:00:00Z"
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(OllamaModel.self, from: json)
        XCTAssertEqual(model.name, "mistral:latest")
        XCTAssertEqual(model.size, 4109853184)
    }

    func testOllamaModelsResponseDecode() throws {
        let json = """
        {
            "models": [
                {"name": "mistral:latest", "size": 4109853184},
                {"name": "llama3.2:latest", "size": 7365960704}
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OllamaModelsResponse.self, from: json)
        XCTAssertEqual(response.models.count, 2)
        XCTAssertEqual(response.models[0].name, "mistral:latest")
        XCTAssertEqual(response.models[1].name, "llama3.2:latest")
    }

    // MARK: - OllamaError Descriptions

    func testOllamaErrorInvalidURL() {
        let error = OllamaError.invalidURL
        XCTAssertEqual(error.errorDescription, "Invalid Ollama URL")
    }

    func testOllamaErrorNetworkError() {
        let underlying = NSError(domain: "test", code: -1009, userInfo: [NSLocalizedDescriptionKey: "No internet"])
        let error = OllamaError.networkError(underlying)
        XCTAssertTrue(error.errorDescription!.contains("Network error"))
        XCTAssertTrue(error.errorDescription!.contains("No internet"))
    }

    func testOllamaErrorInvalidResponseWithStatusCode() {
        let error = OllamaError.invalidResponse(statusCode: 500, body: "Internal Server Error")
        XCTAssertTrue(error.errorDescription!.contains("500"))
        XCTAssertTrue(error.errorDescription!.contains("Internal Server Error"))
    }

    func testOllamaErrorInvalidResponseNilStatusCode() {
        let error = OllamaError.invalidResponse(statusCode: nil, body: nil)
        XCTAssertTrue(error.errorDescription!.contains("Invalid response from Ollama"))
    }

    func testOllamaErrorDecodingError() {
        let decodingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "test")
        )
        let error = OllamaError.decodingError(decodingError, responseBody: "{bad json}")
        XCTAssertTrue(error.errorDescription!.contains("Failed to decode"))
        XCTAssertTrue(error.errorDescription!.contains("{bad json}"))
    }
}
