import Foundation

//
//  AIBackendManager+Balancer.swift
//  Shared AI Backend Manager - Multi-model load balancing
//
//  The shared cross-app load balancer (canonical copy for every game):
//  OpenRouter frontier models (one Keychain key), the optional Nova Gateway,
//  and balanced dispatch across ALL local models (Ollama + MLX). Requests go
//  through the same `send(backend:...)` path as single-backend narration, so
//  retries, timeouts, https-only keys and validation are identical.
//
//  Author: Jordan Koch
//

extension AIBackendManager {

    // MARK: - OpenRouter API key (Keychain-backed)

    /// Store the OpenRouter API key in the Keychain (empty string clears it).
    func setOpenRouterAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            openRouterKeychain.delete()
        } else {
            openRouterKeychain.set(trimmed)
        }
    }

    /// Read the stored OpenRouter API key, if any.
    func openRouterAPIKey() -> String? {
        openRouterKeychain.get()
    }

    /// True when an OpenRouter key has been configured.
    var hasOpenRouterKey: Bool {
        openRouterKeychain.hasValue
    }

    /// Fetch the OpenRouter model list for the picker; falls back to the
    /// hardcoded popular-models list if the fetch fails.
    func fetchOpenRouterModels() async {
        guard let key = openRouterAPIKey(), !key.isEmpty,
              let url = URL(string: "\(baseURL(for: .openRouter))/models"), EndpointPolicy.isSecure(url) else {
            await MainActor.run { self.openRouterModels = OpenRouterProvider.fallbackModels }
            return
        }

        var request = URLRequest(url: url)
        for (header, value) in OpenRouterProvider.authHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        do {
            let (data, response) = try await transport(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                await MainActor.run { self.openRouterModels = OpenRouterProvider.fallbackModels }
                return
            }
            let models = OpenRouterProvider.parseModels(data)
            await MainActor.run {
                self.openRouterModels = models.isEmpty ? OpenRouterProvider.fallbackModels : models
                if !self.openRouterModels.contains(self.selectedOpenRouterModel) {
                    self.selectedOpenRouterModel = self.openRouterModels.contains(OpenRouterProvider.defaultModel)
                        ? OpenRouterProvider.defaultModel : (self.openRouterModels.first ?? OpenRouterProvider.defaultModel)
                }
            }
        } catch {
            await MainActor.run { self.openRouterModels = OpenRouterProvider.fallbackModels }
        }
    }

    // MARK: - Pool discovery (honors the three toggles)

    /// Discover the enabled balancer pool honoring the three toggles. Resilient:
    /// any unreachable source contributes zero models.
    func discoverEnabledPool() async -> [DiscoveredModel] {
        var ollama: [DiscoveredModel] = []
        var mlx: [DiscoveredModel] = []
        var frontier: [DiscoveredModel] = []

        if useAllLocalModels {
            ollama = await ModelRegistry.discoverOllama(baseURL: baseURL(for: .ollama))
            mlx = ModelRegistry.discoverMLX()
        }
        if enableAllFrontierModels {
            frontier = ModelRegistry.frontierModels(from: openRouterModels, baseURL: baseURL(for: .openRouter))
        }
        let nova = useNovaGateway && allowNova ? ModelRegistry.novaGatewayModel(url: baseURL(for: .novaGateway)) : nil

        let pool = ModelRegistry.assemblePool(
            ollama: ollama,
            mlx: mlx,
            frontier: frontier,
            novaGateway: nova,
            useAllLocalModels: useAllLocalModels,
            enableAllFrontierModels: enableAllFrontierModels,
            useNovaGateway: useNovaGateway && allowNova
        )
        await MainActor.run { self.discoveredModels = pool }
        return pool
    }

    // MARK: - Health gating

    /// Quick availability probe for a single balancer backend. Failures -> false;
    /// the Nova Gateway is never required (failed health simply -> unavailable).
    func balancerAvailability(_ backend: LLMBackendType) async -> Bool {
        await probe(backend)
    }

    /// Build a `[modelId: Bool]` health map for `pool` by probing each distinct
    /// backend once.
    private func healthMap(for pool: [DiscoveredModel]) async -> [String: Bool] {
        var backendHealth: [LLMBackendType: Bool] = [:]
        for backend in Set(pool.map { $0.backend }) {
            backendHealth[backend] = await balancerAvailability(backend)
        }
        var map: [String: Bool] = [:]
        for model in pool {
            map[model.id] = backendHealth[model.backend] ?? false
        }
        return map
    }

    // MARK: - Balanced dispatch

    /// Story path through the balanced pool. Returns `nil` when balancing is
    /// disabled or nothing in the pool is healthy, so the caller falls through to
    /// the single-backend chain. A reply that fails `validate` counts as a failed
    /// model and the next one is tried.
    func generateBalancedNarration(
        messages: [OllamaMessage],
        temperature: Double,
        maxTokens: Int?,
        validate: (String) -> String? = NarrationValidator.clean
    ) async throws -> NarrationReply? {
        guard isBalancingEnabled else { return nil }
        let pool = await discoverEnabledPool()
        guard !pool.isEmpty else { return nil }

        let health = await healthMap(for: pool)
        return try await balancer.firstSuccess(pool: pool, health: health, policy: balancerPolicy) { choice in
            let raw = try await send(
                backend: choice.backend,
                model: choice.modelName,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens ?? 2048,
                endpoint: choice.backend == .mlx ? nil : choice.endpoint
            )
            guard let text = validate(raw) else { throw LLMError.invalidOutput }
            return NarrationReply(text: text, backend: choice.backend, model: choice.modelName)
        }
    }
}
