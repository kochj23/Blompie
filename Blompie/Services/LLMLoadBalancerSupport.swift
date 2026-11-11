//
//  LLMLoadBalancerSupport.swift
//  Blompie
//
//  Ported from AIStudio's shared multi-model load balancer.
//  Copyright © 2026 Jordan Koch. All rights reserved.
//
//  Minimal supporting types the copied load-balancer files depend on:
//  `ChatMessage`/`ChatRole` (the message shape `OpenAICompatibleRequest` builds
//  from) and `LLMError` (thrown by the request builder and balanced dispatch).
//  These are kept independent of Blompie's existing `OllamaMessage`/`AIError`
//  types so the balancer is a purely additive layer.
//

import Foundation

// MARK: - Chat message (balancer request shape)

/// Role in a chat conversation.
enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// A single chat message consumed by the OpenAI-compatible request builder.
struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let timestamp: Date

    init(role: ChatRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

// MARK: - Errors

/// Errors surfaced by the load-balancer request path.
enum LLMError: LocalizedError, Sendable {
    case noBackendAvailable
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noResponse
    case mlxNotAvailable
    case insecureEndpoint
    case missingAPIKey
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable:
            return "No LLM backend is available for balanced dispatch."
        case .invalidURL:
            return "Invalid backend URL configuration."
        case .invalidResponse:
            return "Received invalid response from LLM backend."
        case .httpError(let code):
            return "HTTP error \(code) from LLM backend."
        case .noResponse:
            return "No response received from LLM backend."
        case .mlxNotAvailable:
            return "MLX not available. Install: pip install mlx-lm"
        case .insecureEndpoint:
            return "Refusing to send an API key over plain http. Cloud endpoints must use https."
        case .missingAPIKey:
            return "No API key stored in the Keychain for this backend."
        case .invalidOutput:
            return "The model's reply failed validation and was discarded."
        }
    }
}
