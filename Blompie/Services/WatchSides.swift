//
//  WatchSides.swift
//  Blompie
//
//  Model vs model for Watch AI Play. Each AI side (the adventurer choosing commands
//  and the narrator answering them) can run on its own backend + model through
//  NovaAIKit's per-request override; `.auto` keeps the side on the AI Narrator
//  settings (AIBackendManager). Keys and URLs for the override backends live in
//  the kit's settings (Keychain services `com.jkoch.blompie.<backend>`).
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation
import NovaAIKit

/// Blompie's NovaAIKit instance (model-vs-model sides, Allow Nova switch).
@MainActor
enum BlompieAI {
    static let shared: NovaAI = {
        let config = NovaAIConfiguration(appID: "Blompie", appName: "Blompie")
        guard !AIBackendManager.isRunningTests else {
            // Tests never touch the player's settings or Keychain.
            return NovaAI(configuration: config, storage: NovaAIMemoryStorage(), keyStore: NovaAIMemoryKeyStore())
        }
        let ai = NovaAI(configuration: config)
        // One-time, read-only import of the AI Narrator URLs/model/toggle, and a copy (never a move) of
        // the OpenAI and OpenRouter keys Blompie already has.
        _ = ai.migrateLegacySettings()
        _ = ai.migrateLegacyKey(service: "com.jordankoch.Blompie", account: "AIBackend_OpenAI_Key", to: .openAI)
        _ = ai.migrateLegacyKey(service: OpenRouterProvider.keychainService, account: "apiKey", to: .openRouter)
        ai.allowNova = AIBackendManager.shared.allowNova
        return ai
    }()
}

/// One AI side's choice of backend + model. `.auto` = the AI Narrator settings.
struct WatchSide: Codable, Equatable, Sendable {
    var backend: NovaAIBackend = .auto
    var model: String = ""

    var isOverride: Bool { backend != .auto }

    static func load(_ key: String, defaults: UserDefaults = .standard) -> WatchSide {
        guard let data = defaults.data(forKey: key), let side = try? JSONDecoder().decode(WatchSide.self, from: data) else {
            return WatchSide()
        }
        return side
    }

    func save(_ key: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// A reply from an overridden side.
struct SideReply: Equatable, Sendable {
    let text: String
    let backend: String
    let model: String
    let latency: TimeInterval
}

/// The request path for an overridden side: exactly that backend + model, no failover.
/// `NovaAI` conforms; tests inject a stub.
@MainActor
protocol SideAI: AnyObject {
    func complete(messages: [OllamaMessage], side: WatchSide, temperature: Double, maxTokens: Int) async throws -> SideReply
}

extension NovaAI: SideAI {
    func complete(messages: [OllamaMessage], side: WatchSide, temperature: Double, maxTokens: Int) async throws -> SideReply {
        let msgs = messages.map { m -> NovaAIMessage in
            switch m.role {
            case "system": return .system(m.content)
            case "assistant": return .assistant(m.content)
            default: return .user(m.content)
            }
        }
        let r = try await complete(NovaAIRequest(messages: msgs, temperature: temperature, maxTokens: maxTokens,
                                                 backend: side.backend, model: side.model.isEmpty ? nil : side.model))
        return SideReply(text: r.text, backend: r.backend.rawValue, model: r.model, latency: r.latency)
    }
}
