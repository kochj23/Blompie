import Foundation

//
//  AIBackendManager+Generation.swift
//  Blompie
//
//  The single request path for every text backend. `narrate` is the story
//  entry point used by `GameEngine`:
//    1. AI off                 -> throws at once (no network); caller goes scripted
//    2. balancer toggle(s) on  -> balanced pool (LoadBalancer.firstSuccess)
//    3. otherwise              -> the selected backend, or for Auto every
//                                 reachable backend in `LLMBackendType.autoOrder`
//  Each backend gets bounded retries (`Retry.http`, 408/429/5xx/transport only)
//  and a timeout. Every reply must pass a validator; a reply that fails counts
//  as a failed backend. Keys are only ever sent over https.
//
//  Author: Jordan Koch
//

extension AIBackendManager: StoryNarrating {

    // MARK: - Story entry point

    func narrate(
        messages: [OllamaMessage],
        model: String,
        temperature: Double,
        onChunk: ((String) -> Void)?
    ) async throws -> NarrationReply {
        try await narrate(messages: messages, model: model, temperature: temperature,
                          maxTokens: nil, onChunk: onChunk, validate: NarrationValidator.clean)
    }

    func narrate(
        messages: [OllamaMessage],
        model: String,
        temperature: Double,
        maxTokens: Int?,
        onChunk: ((String) -> Void)?,
        validate: (String) -> String?
    ) async throws -> NarrationReply {
        guard aiEnabled else { throw LLMError.noBackendAvailable }

        // Balanced pool first (non-streaming). nil => balancing off / nothing healthy.
        if isBalancingEnabled,
           let reply = try? await generateBalancedNarration(messages: messages, temperature: temperature,
                                                            maxTokens: maxTokens, validate: validate) {
            await recordSuccess(reply.backend)
            return reply
        }

        let chain = await narrationChain()
        guard !chain.isEmpty else {
            await MainActor.run { self.updateStatus() }
            throw LLMError.noBackendAvailable
        }

        var lastError: Error = LLMError.noBackendAvailable
        for backend in chain {
            do {
                let chosenModel = modelName(for: backend, gameModel: model)
                var tps: Double?
                let raw: String
                if backend == .ollama, let onChunk {
                    raw = try await streamOllama(messages: messages, model: chosenModel, temperature: temperature,
                                                 maxTokens: maxTokens, onChunk: onChunk) { tps = $0 }
                } else {
                    raw = try await send(backend: backend, model: chosenModel, messages: messages,
                                         temperature: temperature, maxTokens: maxTokens ?? 1024)
                }
                guard let text = validate(raw) else { throw LLMError.invalidOutput }
                await recordSuccess(backend)
                return NarrationReply(text: text, backend: backend, model: chosenModel, tokensPerSecond: tps)
            } catch {
                lastError = error
                print("[AI] \(backend.rawValue) failed: \(error.localizedDescription)")
                await MainActor.run {
                    // A reply that failed validation came from a reachable server.
                    if !(error is LLMError && (error as? LLMError) == .invalidOutput) {
                        self.setAvailable(backend, false)
                    }
                    self.updateStatus()
                }
            }
        }
        throw lastError
    }

    /// Backends to try for one turn: the selected one, or (Auto) every reachable
    /// backend in the fixed order. Auto re-probes when availability is stale.
    func narrationChain() async -> [LLMBackendType] {
        if activeBackend != .auto { return [activeBackend] }
        let stale = lastRefreshDate.map { Date().timeIntervalSince($0) > availabilityMaxAge } ?? true
        if stale { await refreshAllBackends() }
        return autoChain()
    }

    private func recordSuccess(_ backend: LLMBackendType) async {
        await MainActor.run {
            self.setAvailable(backend, true)
            self.lastNarrationBackend = backend
            self.statusBackend = backend
            self.statusOnline = true
        }
    }

    // MARK: - One request to one backend

    /// Send a full conversation to one concrete backend and return the raw reply.
    func send(
        backend: LLMBackendType,
        model: String,
        messages: [OllamaMessage],
        temperature: Double,
        maxTokens: Int,
        endpoint: String? = nil
    ) async throws -> String {
        switch backend {
        case .auto:
            throw LLMError.noBackendAvailable
        case .mlx:
            return try runMLX(model: model, messages: messages, maxTokens: maxTokens)
        case .ollama:
            let request = try Self.ollamaChatRequest(
                endpoint: endpoint ?? chatEndpoint(for: .ollama), model: model, messages: messages,
                temperature: temperature, maxTokens: maxTokens, timeout: localRequestTimeout)
            let (data, _) = try await Retry.http(request, label: "ollama", transport: transport,
                                                 policy: retryPolicy, sleep: retrySleep)
            return try Self.parseOllamaChat(data)
        case .tinyLLM, .tinyChat, .openWebUI, .novaGateway, .openRouter, .openAI:
            var headers: [String: String] = [:]
            if backend.isCloud {
                guard let key = apiKey(for: backend) else { throw LLMError.missingAPIKey }
                headers = backend == .openRouter
                    ? OpenRouterProvider.authHeaders(apiKey: key)
                    : ["Authorization": "Bearer \(key)"]
            }
            var request = try OpenAICompatibleRequest.build(
                endpoint: endpoint ?? chatEndpoint(for: backend),
                model: model,
                messages: Self.openAIMessages(messages),
                temperature: Float(temperature),
                maxTokens: maxTokens,
                stream: false,
                headers: headers
            )
            request.timeoutInterval = backend.isCloud ? cloudRequestTimeout : localRequestTimeout
            let (data, _) = try await Retry.http(request, label: backend.rawValue, transport: transport,
                                                 policy: retryPolicy, sleep: retrySleep)
            return try Self.parseOpenAIChat(data)
        }
    }

    // MARK: - Pure request/response helpers (unit-tested)

    /// Map the game's conversation to the OpenAI `messages` shape. Multiple system
    /// messages (prompt + history summary) are folded into one leading system message.
    static func openAIMessages(_ messages: [OllamaMessage]) -> [[String: String]] {
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        var out: [[String: String]] = system.isEmpty ? [] : [["role": "system", "content": system]]
        for m in messages where m.role != "system" {
            out.append(["role": m.role == "assistant" ? "assistant" : "user", "content": m.content])
        }
        return out
    }

    static func ollamaChatRequest(
        endpoint: String, model: String, messages: [OllamaMessage],
        temperature: Double, maxTokens: Int, timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint), url.host != nil else { throw LLMError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": openAIMessages(messages),
            "stream": false,
            "options": ["temperature": temperature, "num_predict": maxTokens]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Ollama `/api/chat` reply -> text.
    static func parseOllamaChat(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }

    /// OpenAI-compatible `/chat/completions` reply -> text.
    static func parseOpenAIChat(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }

    // MARK: - Ollama streaming (story path with streaming on)

    private func streamOllama(
        messages: [OllamaMessage],
        model: String,
        temperature: Double,
        maxTokens: Int?,
        onChunk: @escaping (String) -> Void,
        onRate: @escaping (Double?) -> Void
    ) async throws -> String {
        let service = OllamaService(baseURL: baseURL(for: .ollama))
        service.model = model
        service.temperature = temperature
        service.maxTokens = maxTokens
        var full = ""
        try await service.chatStreaming(messages: messages) { chunk in
            full += chunk
            onChunk(chunk)
        } onComplete: { rate in
            onRate(rate)
        }
        return full
    }

    // MARK: - MLX (local CLI)

    private func runMLX(model: String, messages: [OllamaMessage], maxTokens: Int) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.mlxExecutable) else { throw LLMError.mlxNotAvailable }
        let prompt = Self.openAIMessages(messages).map { "\($0["role"] ?? ""): \($0["content"] ?? "")" }
            .joined(separator: "\n\n") + "\n\nassistant:"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.mlxExecutable)
        process.arguments = ["--model", model, "--prompt", prompt, "--max-tokens", "\(maxTokens)"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LLMError.mlxNotAvailable }
        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            throw LLMError.noResponse
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LLMError: Equatable {
    static func == (lhs: LLMError, rhs: LLMError) -> Bool {
        switch (lhs, rhs) {
        case (.httpError(let a), .httpError(let b)): return a == b
        case (.noBackendAvailable, .noBackendAvailable), (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse), (.noResponse, .noResponse),
             (.mlxNotAvailable, .mlxNotAvailable), (.insecureEndpoint, .insecureEndpoint),
             (.missingAPIKey, .missingAPIKey), (.invalidOutput, .invalidOutput):
            return true
        default:
            return false
        }
    }
}
