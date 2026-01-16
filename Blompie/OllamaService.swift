//
//  OllamaService.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import Foundation

struct OllamaMessage: Codable {
    let role: String
    let content: String
}

struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let options: OllamaOptions?
}

struct OllamaOptions: Codable {
    let temperature: Double?
    let num_predict: Int?
}

struct OllamaChatResponse: Codable {
    let message: OllamaMessage
    let done: Bool
    let eval_count: Int?
    let eval_duration: Int64?
    let prompt_eval_count: Int?
    let prompt_eval_duration: Int64?

    var tokensPerSecond: Double? {
        guard let count = eval_count, let duration = eval_duration, duration > 0 else {
            return nil
        }
        let seconds = Double(duration) / 1_000_000_000.0
        return Double(count) / seconds
    }
}

struct OllamaModel: Codable {
    let name: String
    let size: Int64?
    let modified_at: String?
}

struct OllamaModelsResponse: Codable {
    let models: [OllamaModel]
}

enum OllamaError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse(statusCode: Int?, body: String?)
    case decodingError(Error, responseBody: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse(let statusCode, let body):
            if let statusCode = statusCode {
                return "Invalid response (HTTP \(statusCode)): \(body ?? "No details")"
            }
            return "Invalid response from Ollama: \(body ?? "No details")"
        case .decodingError(let error, let body):
            return "Failed to decode response: \(error.localizedDescription)\nResponse: \(body ?? "Unknown")"
        }
    }
}

class OllamaService {
    private let baseURL = "http://localhost:11434"
    var model: String = "mistral"
    var temperature: Double = 0.7
    var maxTokens: Int? = nil

    // Custom URLSession with extended timeout for model loading
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes for request
        config.timeoutIntervalForResource = 600 // 10 minutes for resource
        return URLSession(configuration: config)
    }()

    func fetchInstalledModels() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse(statusCode: nil, body: nil)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw OllamaError.invalidResponse(statusCode: httpResponse.statusCode, body: nil)
            }

            let modelsResponse = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            return modelsResponse.models.map { $0.name }

        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.networkError(error)
        }
    }

    func chatStreaming(messages: [OllamaMessage], onChunk: @escaping (String) -> Void, onComplete: @escaping (Double?) -> Void) async throws {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatRequest = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: true,
            options: OllamaOptions(temperature: temperature, num_predict: maxTokens)
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        do {
            let (asyncBytes, response) = try await urlSession.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse(statusCode: nil, body: nil)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw OllamaError.invalidResponse(statusCode: httpResponse.statusCode, body: nil)
            }

            var buffer = ""
            var lastResponse: OllamaChatResponse?
            for try await byte in asyncBytes {
                let char = Character(UnicodeScalar(byte))
                buffer.append(char)

                if char == "\n" {
                    if let data = buffer.data(using: .utf8),
                       let streamResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) {
                        onChunk(streamResponse.message.content)
                        lastResponse = streamResponse
                    }
                    buffer = ""
                }
            }

            // Call completion handler with token/second metrics
            onComplete(lastResponse?.tokensPerSecond)

        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.networkError(error)
        }
    }

    func chat(messages: [OllamaMessage]) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatRequest = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: false,
            options: OllamaOptions(temperature: temperature, num_predict: maxTokens)
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        do {
            let (data, response) = try await urlSession.data(for: request)
            let bodyString = String(data: data, encoding: .utf8)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse(statusCode: nil, body: bodyString)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw OllamaError.invalidResponse(statusCode: httpResponse.statusCode, body: bodyString)
            }

            do {
                let chatResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                return chatResponse.message.content
            } catch let decodingError as DecodingError {
                throw OllamaError.decodingError(decodingError, responseBody: bodyString)
            }

        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.networkError(error)
        }
    }
}
