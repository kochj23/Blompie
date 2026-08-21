import Foundation

//
//  AIBackendManager+Balancer.swift
//  Shared AI Backend Manager - Multi-model load balancing
//
//  Adds the shared cross-app load balancer on top of the existing AIBackend
//  layer: OpenRouter frontier models (one Keychain key), the optional Nova
//  Gateway, and balanced dispatch across ALL local models (Ollama + MLX).
//  Mirrors AIStudio's `LLMBackendManager` balanced-dispatch. Purely additive —
//  the existing single-backend Ollama/direct paths are untouched.
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
              let url = URL(string: OpenRouterProvider.modelsURL) else {
            await MainActor.run { self.openRouterModels = OpenRouterProvider.fallbackModels }
            return
        }

        var request = URLRequest(url: url)
        for (header, value) in OpenRouterProvider.authHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
            ollama = await ModelRegistry.discoverOllama(baseURL: ollamaServerURL)
            mlx = ModelRegistry.discoverMLX()
        }
        if enableAllFrontierModels {
            frontier = ModelRegistry.frontierModels(from: openRouterModels)
        }
        let nova = useNovaGateway ? ModelRegistry.novaGatewayModel(url: novaGatewayServerURL) : nil

        let pool = ModelRegistry.assemblePool(
            ollama: ollama,
            mlx: mlx,
            frontier: frontier,
            novaGateway: nova,
            useAllLocalModels: useAllLocalModels,
            enableAllFrontierModels: enableAllFrontierModels,
            useNovaGateway: useNovaGateway
        )
        await MainActor.run { self.discoveredModels = pool }
        return pool
    }

    // MARK: - Health gating

    /// Quick availability probe for a single balancer backend. Failures → false;
    /// the Nova Gateway is never required (failed health simply → unavailable).
    func balancerAvailability(_ backend: LLMBackendType) async -> Bool {
        switch backend {
        case .ollama:
            guard let url = URL(string: "\(ollamaServerURL)/api/tags") else { return false }
            return await probe(url)
        case .mlx:
            return FileManager.default.fileExists(atPath: "/opt/homebrew/bin/mlx_lm.generate")
        case .openRouter:
            guard let key = openRouterAPIKey(), !key.isEmpty else { return false }
            guard let url = URL(string: OpenRouterProvider.modelsURL) else { return false }
            var request = URLRequest(url: url)
            for (header, value) in OpenRouterProvider.authHeaders(apiKey: key) {
                request.setValue(value, forHTTPHeaderField: header)
            }
            return await probe(request)
        case .novaGateway:
            guard let url = URL(string: "\(novaGatewayServerURL)/v1/models") else { return false }
            return await probe(url)
        default:
            return false
        }
    }

    private func probe(_ url: URL) async -> Bool {
        await probe(URLRequest(url: url))
    }

    private func probe(_ request: URLRequest) async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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

    /// Entry point for the game's story/narration path. Converts the running
    /// `OllamaMessage` conversation into the balancer request shape and dispatches
    /// across the enabled pool. Returns `nil` when balancing is disabled or the
    /// pool is empty/unreachable, so the caller can fall back to the existing
    /// Ollama path cleanly.
    func generateBalancedNarration(
        messages: [OllamaMessage],
        temperature: Double,
        maxTokens: Int?
    ) async throws -> String? {
        guard isBalancingEnabled else { return nil }

        // Fold all system messages into the system prompt; convert the rest to history.
        let systemPrompt = messages
            .filter { $0.role == "system" }
            .map { $0.content }
            .joined(separator: "\n\n")
        let history: [ChatMessage] = messages.compactMap { msg in
            switch msg.role {
            case "system": return nil
            case "assistant": return ChatMessage(role: .assistant, content: msg.content)
            default: return ChatMessage(role: .user, content: msg.content)
            }
        }
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""

        return try await generateBalanced(
            prompt: prompt,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: history,
            temperature: temperature,
            maxTokens: maxTokens ?? 2048
        )
    }

    /// Balanced dispatch: pick a model via the `LoadBalancer` over the healthy
    /// enabled pool and route it through the appropriate backend. Returns `nil`
    /// when no pool/healthy model exists so the caller can fall back cleanly.
    func generateBalanced(
        prompt: String,
        systemPrompt: String?,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String? {
        let pool = await discoverEnabledPool()
        guard !pool.isEmpty else { return nil }

        let health = await healthMap(for: pool)
        var remaining = pool
        var lastError: Error?

        while let choice = balancer.next(pool: remaining, health: health, policy: balancerPolicy) {
            balancer.checkOut(choice.id)
            do {
                let result = try await dispatchBalanced(
                    model: choice,
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens
                )
                balancer.checkIn(choice.id)
                return result
            } catch {
                balancer.checkIn(choice.id)
                lastError = error
                remaining.removeAll { $0.id == choice.id }
                continue
            }
        }

        if let lastError = lastError { throw lastError }
        return nil
    }

    /// Route a single balancer-selected model through the appropriate backend
    /// implementation (all OpenAI-compatible backends ride the generic path).
    private func dispatchBalanced(
        model: DiscoveredModel,
        prompt: String,
        systemPrompt: String?,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        switch model.backend {
        case .ollama:
            return try await generateOllamaChat(
                model: model.modelName,
                prompt: prompt,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .mlx:
            return try await generateMLXBalanced(
                model: model.modelName,
                prompt: prompt,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens
            )
        case .openRouter:
            guard let key = openRouterAPIKey(), !key.isEmpty else { throw LLMError.noBackendAvailable }
            return try await generateOpenAICompatible(
                endpoint: model.endpoint,
                model: model.modelName,
                headers: OpenRouterProvider.authHeaders(apiKey: key),
                prompt: prompt,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            )
        case .novaGateway:
            return try await generateOpenAICompatible(
                endpoint: model.endpoint,
                model: model.modelName,
                headers: [:],
                prompt: prompt,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens
            )
        default:
            throw LLMError.noBackendAvailable
        }
    }

    // MARK: - Backend request implementations

    /// Ollama `/api/chat` (non-streaming) for a specific model.
    private func generateOllamaChat(
        model: String,
        prompt: String,
        systemPrompt: String?,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        guard let url = URL(string: "\(ollamaServerURL)/api/chat") else { throw LLMError.invalidURL }

        // Ollama shares the OpenAI message shape for /api/chat.
        let apiMessages = OpenAICompatibleRequest.chatMessages(
            prompt: prompt, systemPrompt: systemPrompt, history: messages
        )
        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": false,
            "options": ["temperature": temperature, "num_predict": maxTokens]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.noResponse
        }
        return content
    }

    /// Non-streaming generation against a full OpenAI-compatible endpoint URL
    /// (OpenRouter frontier + Nova Gateway).
    private func generateOpenAICompatible(
        endpoint: String,
        model: String,
        headers: [String: String],
        prompt: String,
        systemPrompt: String?,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        let apiMessages = OpenAICompatibleRequest.chatMessages(
            prompt: prompt, systemPrompt: systemPrompt, history: messages
        )
        var request = try OpenAICompatibleRequest.build(
            endpoint: endpoint,
            model: model,
            messages: apiMessages,
            temperature: Float(temperature),
            maxTokens: maxTokens,
            stream: false,
            headers: headers
        )
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    /// MLX generation via the local `mlx_lm.generate` CLI for a discovered model.
    private func generateMLXBalanced(
        model: String,
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> String {
        let mlxPath = "/opt/homebrew/bin/mlx_lm.generate"
        guard FileManager.default.fileExists(atPath: mlxPath) else { throw LLMError.mlxNotAvailable }

        var fullPrompt = prompt
        if let system = systemPrompt, !system.isEmpty {
            fullPrompt = "\(system)\n\n\(prompt)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mlxPath)
        process.arguments = ["--model", model, "--prompt", fullPrompt, "--max-tokens", "\(maxTokens)"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LLMError.mlxNotAvailable }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            throw LLMError.noResponse
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
