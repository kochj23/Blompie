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
}

struct OllamaChatResponse: Codable {
    let message: OllamaMessage
    let done: Bool
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

    func chatStreaming(messages: [OllamaMessage], onChunk: @escaping (String) -> Void) async throws {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatRequest = OllamaChatRequest(
            model: model,
            messages: messages,
            stream: true
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse(statusCode: nil, body: nil)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw OllamaError.invalidResponse(statusCode: httpResponse.statusCode, body: nil)
            }

            var buffer = ""
            for try await byte in asyncBytes {
                let char = Character(UnicodeScalar(byte))
                buffer.append(char)

                if char == "\n" {
                    if let data = buffer.data(using: .utf8),
                       let streamResponse = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) {
                        onChunk(streamResponse.message.content)
                    }
                    buffer = ""
                }
            }

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
            stream: false
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
