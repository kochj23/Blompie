import Foundation
import SwiftUI

//
//  AIBackendManager.swift
//  Blompie
//
//  Owns every AI setting and the live status of each backend:
//    - global "AI on/off" toggle (off => the scripted narrator runs the game)
//    - backend picker over the canonical `LLMBackendType` (with Auto)
//    - per-backend endpoint URLs and model names (editable, persisted)
//    - API keys, only in the Keychain under Blompie's own services
//    - availability probes and the narrator status badge
//  Generation lives in `AIBackendManager+Generation.swift`; the multi-model
//  balancer in `AIBackendManager+Balancer.swift`.
//
//  Author: Jordan Koch
//

/// What `GameEngine` needs from the AI layer (a protocol so tests can inject one).
protocol StoryNarrating: AnyObject {
    /// Global AI switch. Off => no network at all; the scripted narrator answers.
    var aiEnabled: Bool { get }
    /// Narrate one turn. Throws when no backend produced a valid reply.
    func narrate(
        messages: [OllamaMessage],
        model: String,
        temperature: Double,
        onChunk: ((String) -> Void)?
    ) async throws -> NarrationReply
}

/// A validated model reply plus where it came from.
struct NarrationReply: Equatable, Sendable {
    let text: String
    let backend: LLMBackendType
    let model: String
    var tokensPerSecond: Double? = nil
}

final class AIBackendManager: ObservableObject {

    // MARK: - Singleton

    /// Under XCTest the shared manager uses a separate defaults suite and Keychain
    /// service, never migrates the legacy key and never probes at launch, so test
    /// runs cannot touch the player's real settings or secrets.
    static let shared: AIBackendManager = {
        if isRunningTests {
            return AIBackendManager(
                defaults: UserDefaults(suiteName: "com.jordankoch.Blompie.tests") ?? .standard,
                keychainService: "com.jordankoch.Blompie.tests",
                openRouterKeychain: KeychainStore(service: "com.jordankoch.Blompie.tests.openrouter"),
                migrateLegacySecrets: false,
                probeOnLaunch: false
            )
        }
        return AIBackendManager()
    }()

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Game-level switches

    /// Global AI toggle. Off => the scripted narrator runs the game with no network.
    @Published var aiEnabled = true
    /// Backend picked in Settings. `.auto` fails over in `LLMBackendType.autoOrder`.
    @Published var activeBackend: LLMBackendType = .auto

    // MARK: - Availability (refreshed by `refreshAllBackends`)

    @Published var isOllamaAvailable = false
    @Published var isMLXAvailable = false
    @Published var isTinyLLMAvailable = false
    @Published var isTinyChatAvailable = false
    @Published var isOpenWebUIAvailable = false
    @Published var isNovaGatewayAvailable = false
    @Published var isOpenRouterAvailable = false
    @Published var isOpenAIAvailable = false

    // Image generation backends
    @Published var isAutomatic1111Available = false
    @Published var isSwarmUIAvailable = false

    @Published var lastRefreshDate: Date?

    /// Narrator status badge: the backend a turn would use now, and whether it is reachable.
    @Published var statusBackend: LLMBackendType?
    @Published var statusOnline = false
    /// Backend that answered the last turn (nil if the last turn was scripted).
    @Published var lastNarrationBackend: LLMBackendType?

    // MARK: - Endpoints (editable; defaults are local)

    @Published var ollamaServerURL = LLMBackendType.ollama.defaultURL
    @Published var tinyLLMServerURL = LLMBackendType.tinyLLM.defaultURL
    @Published var tinyChatServerURL = LLMBackendType.tinyChat.defaultURL
    @Published var openWebUIServerURL = LLMBackendType.openWebUI.defaultURL
    @Published var novaGatewayServerURL = LLMBackendType.novaGateway.defaultURL
    @Published var openRouterServerURL = LLMBackendType.openRouter.defaultURL
    @Published var openAIServerURL = LLMBackendType.openAI.defaultURL
    @Published var automatic1111ServerURL = "http://localhost:7860"
    @Published var swarmUIServerURL = "http://localhost:7801"

    // MARK: - Models (Ollama/TinyChat/OpenWebUI use the game's model picker)

    @Published var openRouterModels: [String] = OpenRouterProvider.fallbackModels
    @Published var selectedOpenRouterModel: String = OpenRouterProvider.defaultModel
    @Published var selectedOpenAIModel = AIBackendManager.defaultOpenAIModel
    @Published var selectedMLXModel = AIBackendManager.defaultMLXModel
    @Published var tinyLLMModel = "default"

    static let defaultOpenAIModel = "gpt-4o-mini"
    static let defaultMLXModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    static let mlxExecutable = "/opt/homebrew/bin/mlx_lm.generate"

    // MARK: - Multi-model load balancer (shared cross-app design)

    /// Toggle: spread work across ALL local models (Ollama + MLX).
    @Published var useAllLocalModels = false
    /// Toggle: include all OpenRouter frontier models in the pool.
    @Published var enableAllFrontierModels = false
    /// Toggle: include the Nova Gateway (optional; never required).
    @Published var useNovaGateway = false
    /// The models currently discovered for the balanced pool (all enabled sources).
    @Published var discoveredModels: [DiscoveredModel] = []

    /// Pure, network-free balancer that spreads work across the enabled pool.
    let balancer = LoadBalancer()
    /// Balancer policy (least-busy mirrors how Nova's gateway spreads load).
    var balancerPolicy: BalancerPolicy = .leastBusy

    /// True when any load-balancing toggle is on.
    var isBalancingEnabled: Bool {
        useAllLocalModels || enableAllFrontierModels || useNovaGateway
    }

    // MARK: - Secrets (Keychain only)

    /// Keychain service for Blompie's non-OpenRouter secrets.
    static let keychainServiceName = "com.jordankoch.Blompie"
    static let openAIKeyAccount = "AIBackend_OpenAI_Key"

    let keychainService: String
    /// Keychain-backed store for the single OpenRouter API key.
    let openRouterKeychain: KeychainStore
    /// Keychain-backed store for the OpenAI API key.
    let openAIKeychain: KeychainStore

    // MARK: - Transport, timeouts, retries

    /// HTTP seam (tests inject a stub; no network in unit tests).
    var transport: HTTPTransport = HTTP.live
    /// Bounded retries per backend before failing over (408/429/5xx and transport errors only).
    var retryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 0.5, multiplier: 2, maxDelay: 2)
    var retrySleep: RetrySleeper = Retry.realSleep
    /// Per-request timeout for local/LAN models (first load of a large model is slow).
    var localRequestTimeout: TimeInterval = 180
    /// Per-request timeout for cloud models.
    var cloudRequestTimeout: TimeInterval = 60
    /// Availability probe timeout.
    var probeTimeout: TimeInterval = 3
    /// Auto mode re-probes when the last refresh is older than this.
    var availabilityMaxAge: TimeInterval = 30

    let defaults: UserDefaults

    // MARK: - Initialization

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = AIBackendManager.keychainServiceName,
        openRouterKeychain: KeychainStore = KeychainStore(),
        migrateLegacySecrets: Bool = true,
        probeOnLaunch: Bool = true
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.openRouterKeychain = openRouterKeychain
        self.openAIKeychain = KeychainStore(service: keychainService, account: Self.openAIKeyAccount)

        if migrateLegacySecrets {
            Self.migrateAPIKeysFromUserDefaults(defaults: defaults, openAI: openAIKeychain)
            Self.migrateLegacyOpenRouterKey(defaults: defaults, to: openRouterKeychain)
        }
        loadConfiguration()
        if probeOnLaunch {
            Task { await refreshAllBackends() }
        }
    }

    // MARK: - Legacy migration

    /// UserDefaults keys used by Blompie <= 1.0 for API keys. OpenAI's moves to the
    /// Keychain; the removed cloud stubs' values are deleted (never kept in plaintext).
    static let legacyDefaultsKeys = [
        "AIBackend_OpenAI_Key",
        "AIBackend_GoogleCloud_Key",
        "AIBackend_Azure_Key",
        "AIBackend_Azure_Endpoint",
        "AIBackend_AWS_AccessKey",
        "AIBackend_AWS_SecretKey",
        "AIBackend_IBM_Key",
        "AIBackend_IBM_URL"
    ]

    static func migrateAPIKeysFromUserDefaults(defaults: UserDefaults, openAI: KeychainStore) {
        for key in legacyDefaultsKeys {
            guard let value = defaults.string(forKey: key) else { continue }
            if key == openAIKeyAccount, !value.isEmpty, !openAI.hasValue {
                openAI.set(value)
            }
            defaults.removeObject(forKey: key)
        }
    }

    static let openRouterMigratedFlag = "AIBackend_OpenRouterKeyMigrated"

    /// Read the AIStudio-shared OpenRouter item once and copy it to Blompie's own
    /// service. The old item is never written or deleted (AIStudio still owns it).
    static func migrateLegacyOpenRouterKey(
        defaults: UserDefaults,
        to target: KeychainStore,
        legacy: KeychainStore = KeychainStore(service: OpenRouterProvider.legacyKeychainService)
    ) {
        guard !defaults.bool(forKey: openRouterMigratedFlag) else { return }
        KeychainStore.migrate(from: legacy, to: target)
        defaults.set(true, forKey: openRouterMigratedFlag)
    }

    // MARK: - Keys

    func setOpenAIAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { openAIKeychain.delete() } else { openAIKeychain.set(trimmed) }
    }

    func openAIAPIKey() -> String? { openAIKeychain.get() }
    var hasOpenAIKey: Bool { openAIKeychain.hasValue }

    /// The Keychain key a cloud backend sends, or nil (local backends never send one).
    func apiKey(for backend: LLMBackendType) -> String? {
        switch backend {
        case .openRouter: return openRouterKeychain.get().flatMap { $0.isEmpty ? nil : $0 }
        case .openAI: return openAIKeychain.get().flatMap { $0.isEmpty ? nil : $0 }
        default: return nil
        }
    }

    // MARK: - Endpoints

    /// Base URL configured for a backend ("" for MLX/Auto).
    func baseURL(for backend: LLMBackendType) -> String {
        let raw: String
        switch backend {
        case .auto, .mlx: return ""
        case .ollama: raw = ollamaServerURL
        case .tinyLLM: raw = tinyLLMServerURL
        case .tinyChat: raw = tinyChatServerURL
        case .openWebUI: raw = openWebUIServerURL
        case .novaGateway: raw = novaGatewayServerURL
        case .openRouter: raw = openRouterServerURL
        case .openAI: raw = openAIServerURL
        }
        return EndpointPolicy.normalizedBaseURL(raw)
    }

    /// Full chat endpoint for a backend.
    func chatEndpoint(for backend: LLMBackendType) -> String {
        let base = baseURL(for: backend)
        switch backend {
        case .auto, .mlx: return ""
        case .ollama: return "\(base)/api/chat"
        case .tinyLLM: return "\(base)/v1/chat/completions"
        case .tinyChat: return "\(base)/api/chat/stream"
        case .openWebUI: return "\(base)/api/chat/completions"
        case .novaGateway: return "\(base)/v1/chat/completions"
        case .openRouter, .openAI: return "\(base)/chat/completions"
        }
    }

    /// Endpoint probed for reachability (nil = no network probe).
    func probeURL(for backend: LLMBackendType) -> URL? {
        let base = baseURL(for: backend)
        switch backend {
        case .auto, .mlx: return nil
        case .ollama: return URL(string: "\(base)/api/tags")
        case .tinyLLM: return URL(string: "\(base)/v1/models")
        case .tinyChat, .openWebUI: return URL(string: "\(base)/")
        case .novaGateway: return URL(string: "\(base)/v1/models")
        case .openRouter, .openAI: return URL(string: "\(base)/models")
        }
    }

    /// Model name sent to a backend. Ollama, TinyChat and OpenWebUI use the
    /// game's model picker (Ollama tags); the others have their own setting.
    func modelName(for backend: LLMBackendType, gameModel: String) -> String {
        switch backend {
        case .ollama, .tinyChat, .openWebUI, .auto: return gameModel
        case .tinyLLM: return tinyLLMModel
        case .mlx: return selectedMLXModel
        case .novaGateway: return "nova"
        case .openRouter: return selectedOpenRouterModel
        case .openAI: return selectedOpenAIModel
        }
    }

    // MARK: - Availability

    /// Cached availability from the last refresh.
    func isAvailable(_ backend: LLMBackendType) -> Bool {
        switch backend {
        case .auto: return autoChain().first != nil
        case .ollama: return isOllamaAvailable
        case .mlx: return isMLXAvailable
        case .tinyLLM: return isTinyLLMAvailable
        case .tinyChat: return isTinyChatAvailable
        case .openWebUI: return isOpenWebUIAvailable
        case .novaGateway: return isNovaGatewayAvailable
        case .openRouter: return isOpenRouterAvailable
        case .openAI: return isOpenAIAvailable
        }
    }

    var availabilityMap: [LLMBackendType: Bool] {
        Dictionary(uniqueKeysWithValues: LLMBackendType.concrete.map { ($0, isAvailable($0)) })
    }

    /// Reachable backends in the fixed Auto order.
    func autoChain() -> [LLMBackendType] {
        FailoverPlanner.orderedHealthy(chain: LLMBackendType.autoOrder, availability: availabilityMap)
    }

    /// Cloud backends count as available when a key is stored and the URL is https;
    /// no network call is made for them during a refresh.
    func cloudConfigured(_ backend: LLMBackendType) -> Bool {
        guard backend.isCloud, apiKey(for: backend) != nil,
              let url = URL(string: baseURL(for: backend)) else { return false }
        return EndpointPolicy.isSecure(url)
    }

    /// Live reachability probe for one backend (short timeout, no retries).
    func probe(_ backend: LLMBackendType) async -> Bool {
        switch backend {
        case .auto:
            return false
        case .mlx:
            return FileManager.default.isExecutableFile(atPath: Self.mlxExecutable)
        case .openRouter, .openAI:
            guard cloudConfigured(backend), let url = probeURL(for: backend), let key = apiKey(for: backend) else { return false }
            var request = URLRequest(url: url, timeoutInterval: probeTimeout)
            let headers = backend == .openRouter
                ? OpenRouterProvider.authHeaders(apiKey: key)
                : ["Authorization": "Bearer \(key)"]
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            return await reachable(request)
        default:
            guard let url = probeURL(for: backend) else { return false }
            return await reachable(URLRequest(url: url, timeoutInterval: probeTimeout))
        }
    }

    private func reachable(_ request: URLRequest) async -> Bool {
        do {
            let (_, response) = try await transport(request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
            return status < 500
        } catch {
            return false
        }
    }

    /// Probe every backend (text and image) concurrently and update the status badge.
    func refreshAllBackends() async {
        guard aiEnabled else {
            await MainActor.run { self.updateStatus(); self.lastRefreshDate = Date() }
            return
        }
        async let ollama = probe(.ollama)
        async let mlx = probe(.mlx)
        async let tinyLLM = probe(.tinyLLM)
        async let tinyChat = probe(.tinyChat)
        async let openWebUI = probe(.openWebUI)
        async let nova = probe(.novaGateway)
        async let a1111 = probeImage(automatic1111ServerURL, path: "/sdapi/v1/sd-models")
        async let swarm = probeImage(swarmUIServerURL, path: "/API/ListModels")
        let results = await (ollama, mlx, tinyLLM, tinyChat, openWebUI, nova, a1111, swarm)
        let openRouter = cloudConfigured(.openRouter)
        let openAI = cloudConfigured(.openAI)

        await MainActor.run {
            isOllamaAvailable = results.0
            isMLXAvailable = results.1
            isTinyLLMAvailable = results.2
            isTinyChatAvailable = results.3
            isOpenWebUIAvailable = results.4
            isNovaGatewayAvailable = results.5
            isAutomatic1111Available = results.6
            isSwarmUIAvailable = results.7
            isOpenRouterAvailable = openRouter
            isOpenAIAvailable = openAI
            lastRefreshDate = Date()
            updateStatus()
        }
    }

    private func probeImage(_ base: String, path: String) async -> Bool {
        guard let url = URL(string: EndpointPolicy.normalizedBaseURL(base) + path) else { return false }
        return await reachable(URLRequest(url: url, timeoutInterval: probeTimeout))
    }

    /// "Test connection": live-probe the selected backend (or the whole Auto chain).
    @discardableResult
    func testConnection() async -> Bool {
        if activeBackend == .auto {
            await refreshAllBackends()
            return await MainActor.run { statusOnline }
        }
        let ok = await probe(activeBackend)
        await MainActor.run {
            setAvailable(activeBackend, ok)
            lastRefreshDate = Date()
            updateStatus()
        }
        return ok
    }

    func setAvailable(_ backend: LLMBackendType, _ value: Bool) {
        switch backend {
        case .auto: break
        case .ollama: isOllamaAvailable = value
        case .mlx: isMLXAvailable = value
        case .tinyLLM: isTinyLLMAvailable = value
        case .tinyChat: isTinyChatAvailable = value
        case .openWebUI: isOpenWebUIAvailable = value
        case .novaGateway: isNovaGatewayAvailable = value
        case .openRouter: isOpenRouterAvailable = value
        case .openAI: isOpenAIAvailable = value
        }
    }

    /// Recompute the status badge from cached availability.
    func updateStatus() {
        guard aiEnabled else {
            statusBackend = nil
            statusOnline = false
            return
        }
        if activeBackend == .auto {
            let first = autoChain().first
            statusBackend = first
            statusOnline = first != nil
        } else {
            statusBackend = activeBackend
            statusOnline = isAvailable(activeBackend)
        }
    }

    /// One-line status for the badge and the widget.
    var statusText: String {
        guard aiEnabled else { return "AI off: scripted narrator" }
        guard let backend = statusBackend else { return "Narrator away: no backend reachable" }
        return statusOnline ? "Narrator online: \(backend.shortName)" : "Narrator away: \(backend.shortName) unreachable"
    }

    // MARK: - Configuration Persistence

    func loadConfiguration() {
        aiEnabled = defaults.object(forKey: "AIBackend_Enabled") as? Bool ?? true
        activeBackend = LLMBackendType.migrating(defaults.string(forKey: "AIBackend_Active"))

        ollamaServerURL = defaults.string(forKey: "AIBackend_OllamaURL") ?? LLMBackendType.ollama.defaultURL
        tinyLLMServerURL = defaults.string(forKey: "AIBackend_TinyLLMURL") ?? LLMBackendType.tinyLLM.defaultURL
        tinyChatServerURL = defaults.string(forKey: "AIBackend_TinyChatURL") ?? LLMBackendType.tinyChat.defaultURL
        openWebUIServerURL = defaults.string(forKey: "AIBackend_OpenWebUIURL") ?? LLMBackendType.openWebUI.defaultURL
        novaGatewayServerURL = defaults.string(forKey: "AIBackend_NovaGatewayURL") ?? LLMBackendType.novaGateway.defaultURL
        openRouterServerURL = defaults.string(forKey: "AIBackend_OpenRouterURL") ?? LLMBackendType.openRouter.defaultURL
        openAIServerURL = defaults.string(forKey: "AIBackend_OpenAIURL") ?? LLMBackendType.openAI.defaultURL
        automatic1111ServerURL = defaults.string(forKey: "AIBackend_Automatic1111URL") ?? "http://localhost:7860"
        swarmUIServerURL = defaults.string(forKey: "AIBackend_SwarmUIURL") ?? "http://localhost:7801"

        selectedOpenRouterModel = defaults.string(forKey: "AIBackend_OpenRouterModel") ?? OpenRouterProvider.defaultModel
        selectedOpenAIModel = defaults.string(forKey: "AIBackend_OpenAIModel") ?? Self.defaultOpenAIModel
        selectedMLXModel = defaults.string(forKey: "AIBackend_MLXModel") ?? Self.defaultMLXModel
        tinyLLMModel = defaults.string(forKey: "AIBackend_TinyLLMModel") ?? "default"

        useAllLocalModels = defaults.bool(forKey: "AIBackend_UseAllLocalModels")
        enableAllFrontierModels = defaults.bool(forKey: "AIBackend_EnableAllFrontierModels")
        useNovaGateway = defaults.bool(forKey: "AIBackend_UseNovaGateway")
        updateStatus()
    }

    /// Persist settings (URLs, models, toggles). Secrets are never written here.
    func saveConfiguration() {
        defaults.set(aiEnabled, forKey: "AIBackend_Enabled")
        defaults.set(activeBackend.rawValue, forKey: "AIBackend_Active")

        defaults.set(ollamaServerURL, forKey: "AIBackend_OllamaURL")
        defaults.set(tinyLLMServerURL, forKey: "AIBackend_TinyLLMURL")
        defaults.set(tinyChatServerURL, forKey: "AIBackend_TinyChatURL")
        defaults.set(openWebUIServerURL, forKey: "AIBackend_OpenWebUIURL")
        defaults.set(novaGatewayServerURL, forKey: "AIBackend_NovaGatewayURL")
        defaults.set(openRouterServerURL, forKey: "AIBackend_OpenRouterURL")
        defaults.set(openAIServerURL, forKey: "AIBackend_OpenAIURL")
        defaults.set(automatic1111ServerURL, forKey: "AIBackend_Automatic1111URL")
        defaults.set(swarmUIServerURL, forKey: "AIBackend_SwarmUIURL")

        defaults.set(selectedOpenRouterModel, forKey: "AIBackend_OpenRouterModel")
        defaults.set(selectedOpenAIModel, forKey: "AIBackend_OpenAIModel")
        defaults.set(selectedMLXModel, forKey: "AIBackend_MLXModel")
        defaults.set(tinyLLMModel, forKey: "AIBackend_TinyLLMModel")

        defaults.set(useAllLocalModels, forKey: "AIBackend_UseAllLocalModels")
        defaults.set(enableAllFrontierModels, forKey: "AIBackend_EnableAllFrontierModels")
        defaults.set(useNovaGateway, forKey: "AIBackend_UseNovaGateway")
        updateStatus()
    }
}
