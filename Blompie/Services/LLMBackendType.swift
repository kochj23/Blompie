//
//  LLMBackendType.swift
//  Blompie
//
//  Canonical LLM backend identifier shared by every Jordan Koch game
//  (the "AI parity" contract). The stable lowercase raw values are what gets
//  persisted; display names are separate so they can change freely.
//
//  Claude is reached through `.novaGateway` or `.openRouter`
//  (e.g. `anthropic/claude-*`); there is no direct Anthropic backend.
//  Google Cloud, Azure, AWS and IBM Watson were removed in 1.2.0: they were
//  stubs that always threw and never worked.
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation

/// LLM backend type identifier (canonical, Codable-safe).
enum LLMBackendType: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case ollama = "ollama"
    case mlx = "mlx"
    case tinyLLM = "tinyllm"
    case tinyChat = "tinychat"
    case openWebUI = "openwebui"
    case novaGateway = "novagateway"
    case openRouter = "openrouter"
    case openAI = "openai"

    /// Fixed failover order used by `.auto`: local first, then gateway, then cloud.
    static let autoOrder: [LLMBackendType] = [
        .ollama, .mlx, .tinyChat, .tinyLLM, .openWebUI, .novaGateway, .openRouter, .openAI
    ]

    /// Concrete backends (everything except `.auto`).
    static var concrete: [LLMBackendType] { allCases.filter { $0 != .auto } }

    /// Cloud backends need an API key and are only ever called over https.
    var isCloud: Bool { self == .openRouter || self == .openAI }

    /// Map a value persisted by Blompie <= 1.1.2 (`AIBackendManager.AIBackend`
    /// display-name raw values such as "Ollama" or "MLX Toolkit") or a current
    /// raw value to the canonical case. Removed cloud stubs map to `.auto`.
    static func migrating(_ stored: String?) -> LLMBackendType {
        guard let stored, !stored.isEmpty else { return .auto }
        if let current = LLMBackendType(rawValue: stored) { return current }
        switch stored {
        case "Ollama": return .ollama
        case "MLX Toolkit": return .mlx
        case "TinyLLM": return .tinyLLM
        case "TinyChat": return .tinyChat
        case "OpenWebUI": return .openWebUI
        case "OpenAI": return .openAI
        default: return .auto   // Google Cloud AI, Microsoft Azure, AWS AI Services, IBM Watson
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto (first reachable)"
        case .ollama: return "Ollama"
        case .mlx: return "MLX Native"
        case .tinyLLM: return "TinyLLM"
        case .tinyChat: return "TinyChat"
        case .openWebUI: return "OpenWebUI"
        case .novaGateway: return "Nova Gateway"
        case .openRouter: return "OpenRouter (Frontier Models)"
        case .openAI: return "OpenAI"
        }
    }

    /// Short name for status badges.
    var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .openRouter: return "OpenRouter"
        default: return displayName
        }
    }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .ollama: return "network"
        case .mlx: return "cpu"
        case .tinyLLM: return "cube"
        case .tinyChat: return "bubble.left.and.bubble.right.fill"
        case .openWebUI: return "globe"
        case .novaGateway: return "sparkle.magnifyingglass"
        case .openRouter: return "cloud"
        case .openAI: return "cloud.fill"
        }
    }

    var defaultURL: String {
        switch self {
        case .auto, .mlx: return ""
        case .ollama: return "http://localhost:11434"
        case .tinyLLM: return "http://localhost:8000"
        case .tinyChat: return "http://localhost:8000"
        case .openWebUI: return "http://localhost:8080"
        case .novaGateway: return ModelRegistry.novaGatewayDefaultURL
        case .openRouter: return OpenRouterProvider.baseURL
        case .openAI: return "https://api.openai.com/v1"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Try every reachable backend in a fixed order: Ollama, MLX, TinyChat, TinyLLM, OpenWebUI, Nova Gateway, OpenRouter, OpenAI"
        case .ollama: return "Local or LAN Ollama server (/api/chat)"
        case .mlx: return "Apple Silicon native inference via mlx_lm.generate"
        case .tinyLLM: return "TinyLLM lightweight OpenAI-compatible server"
        case .tinyChat: return "TinyChat by Jason Cox"
        case .openWebUI: return "Self-hosted OpenWebUI (OpenAI-compatible /api/chat/completions)"
        case .novaGateway: return "Nova's gateway: OpenAI-compatible, inherits Nova's own routing (also the Claude route)"
        case .openRouter: return "Frontier cloud models via OpenRouter (one Keychain key; https only)"
        case .openAI: return "OpenAI API (Keychain key; https only)"
        }
    }
}
