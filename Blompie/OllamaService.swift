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

enum OllamaError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
}

class OllamaService {
    private let baseURL = "http://localhost:11434"
    private let model = "mistral"

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

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw OllamaError.invalidResponse
            }

            let chatResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return chatResponse.message.content

        } catch let error as DecodingError {
            throw OllamaError.decodingError(error)
        } catch {
            throw OllamaError.networkError(error)
        }
    }
}
