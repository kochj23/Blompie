//
//  AIParityTests.swift
//  BlompieTests
//
//  The games "AI parity" contract, in all 7 categories: global AI toggle,
//  scripted fallback (a failed AI call never loses a turn), backend + model
//  pickers with editable URLs, Keychain-only keys under Blompie's own service
//  (with the one-time AIStudio migration), https-only cloud calls, status,
//  Auto failover in a fixed order with timeouts and bounded retries, and AI
//  output validation. No test touches the network: HTTP goes through a stub
//  transport and GameEngine gets a stub narrator.
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

// MARK: - Fixtures

/// Records every request and answers from a per-URL script.
final class StubTransport: @unchecked Sendable {
    typealias Responder = (URLRequest) throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let responder: Responder

    init(_ responder: @escaping Responder) { self.responder = responder }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var hosts: [String] { requests.compactMap { $0.url?.host } }
    func count(path: String) -> Int { requests.filter { $0.url?.path == path }.count }

    var transport: HTTPTransport {
        { [self] request in
            lock.withLock { _requests.append(request) }
            let (status, data) = try responder(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    static func ollamaReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": text], "done": true])
    }

    static func openAIReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
    }
}

enum AIFixtures {
    static let narration = "You step into a sunlit clearing. A wizard named Orrin waves at you.\nACTIONS: Talk to Orrin | Go north | Look around"

    /// A manager isolated from the player's settings and Keychain, with no probes,
    /// no sleeping between retries and the given transport.
    static func manager(_ stub: StubTransport) -> (AIBackendManager, () -> Void) {
        let suite = "com.jordankoch.Blompie.tests.parity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = AIBackendManager(defaults: defaults, keychainService: suite,
                                       openRouterKeychain: KeychainStore(service: suite + ".openrouter"),
                                       migrateLegacySecrets: false, probeOnLaunch: false)
        manager.transport = stub.transport
        manager.retrySleep = { _ in }
        manager.lastRefreshDate = Date()   // treat availability as fresh unless a test says otherwise
        let cleanup = {
            manager.setOpenAIAPIKey("")
            manager.setOpenRouterAPIKey("")
            defaults.removePersistentDomain(forName: suite)
        }
        return (manager, cleanup)
    }

    static let messages = [
        OllamaMessage(role: "system", content: "You are the game master."),
        OllamaMessage(role: "user", content: "Start a new adventure.")
    ]
}

/// Narrator stub for GameEngine tests.
final class StubNarrator: StoryNarrating {
    var aiEnabled: Bool
    var replies: [Result<NarrationReply, Error>]
    private(set) var calls = 0

    init(aiEnabled: Bool = true, replies: [Result<NarrationReply, Error>] = []) {
        self.aiEnabled = aiEnabled
        self.replies = replies
    }

    func narrate(messages: [OllamaMessage], model: String, temperature: Double,
                 onChunk: ((String) -> Void)?) async throws -> NarrationReply {
        calls += 1
        guard !replies.isEmpty else { throw LLMError.noBackendAvailable }
        return try replies.removeFirst().get()
    }

    static func failing() -> StubNarrator { StubNarrator(replies: []) }
    static func ok(_ text: String, backend: LLMBackendType = .ollama) -> Result<NarrationReply, Error> {
        .success(NarrationReply(text: text, backend: backend, model: "stub"))
    }
}

@MainActor
private func makeEngine(_ narrator: StoryNarrating, logger: PlayLogger? = nil) -> GameEngine {
    let engine = GameEngine(playLogger: logger, narrator: narrator)
    engine.autoSaveEnabled = false     // never overwrite the player's real autosave
    engine.streamingEnabled = false
    return engine
}

/// Wait (bounded) for the engine's turn task to finish.
@MainActor
private func settle(_ engine: GameEngine, turns: Int = 1, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !engine.isLoading && engine.lastNarrationSource != nil { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // one more hop so the turn's trailing main-actor work completes
    await Task.yield()
}

@MainActor
private func act(_ engine: GameEngine, _ action: String) async {
    engine.performAction(action)
    // performAction schedules the turn; wait for isLoading to go true then false
    try? await Task.sleep(nanoseconds: 5_000_000)
    let deadline = Date().addingTimeInterval(5)
    while engine.isLoading && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    await Task.yield()
}

// MARK: - Unit

final class AIParityUnitTests: XCTestCase {

    func testAutoOrderIsFixed() {
        XCTAssertEqual(LLMBackendType.autoOrder,
                       [.ollama, .mlx, .tinyChat, .tinyLLM, .openWebUI, .novaGateway, .openRouter, .openAI])
        XCTAssertEqual(FailoverPlanner.defaultChain, LLMBackendType.autoOrder)
        XCTAssertEqual(Set(LLMBackendType.autoOrder), Set(LLMBackendType.concrete))
    }

    func testChatEndpointsFollowEditableURLs() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.ollamaServerURL = "http://studio.lan:11434/"
        m.tinyLLMServerURL = "http://tiny.lan:8000"
        m.openWebUIServerURL = "http://webui.lan:3000"
        XCTAssertEqual(m.chatEndpoint(for: .ollama), "http://studio.lan:11434/api/chat")
        XCTAssertEqual(m.chatEndpoint(for: .tinyLLM), "http://tiny.lan:8000/v1/chat/completions")
        XCTAssertEqual(m.chatEndpoint(for: .tinyChat), "http://localhost:8000/api/chat/stream")
        XCTAssertEqual(m.chatEndpoint(for: .openWebUI), "http://webui.lan:3000/api/chat/completions")
        XCTAssertEqual(m.chatEndpoint(for: .novaGateway), "http://127.0.0.1:18792/v1/chat/completions")
        XCTAssertEqual(m.chatEndpoint(for: .openRouter), "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(m.chatEndpoint(for: .openAI), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(m.chatEndpoint(for: .mlx), "")
    }

    func testModelNamePerBackend() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        XCTAssertEqual(m.modelName(for: .ollama, gameModel: "qwen3:8b"), "qwen3:8b")
        XCTAssertEqual(m.modelName(for: .openWebUI, gameModel: "qwen3:8b"), "qwen3:8b")
        XCTAssertEqual(m.modelName(for: .tinyLLM, gameModel: "qwen3:8b"), "default")
        XCTAssertEqual(m.modelName(for: .novaGateway, gameModel: "x"), "nova")
        XCTAssertEqual(m.modelName(for: .openRouter, gameModel: "x"), OpenRouterProvider.defaultModel)
        XCTAssertEqual(m.modelName(for: .openAI, gameModel: "x"), AIBackendManager.defaultOpenAIModel)
        XCTAssertEqual(m.modelName(for: .mlx, gameModel: "x"), AIBackendManager.defaultMLXModel)
    }

    func testOpenAIMessagesFoldSystemMessages() {
        let msgs = [OllamaMessage(role: "system", content: "rules"),
                    OllamaMessage(role: "system", content: "summary"),
                    OllamaMessage(role: "user", content: "hi"),
                    OllamaMessage(role: "assistant", content: "hello")]
        let out = AIBackendManager.openAIMessages(msgs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], ["role": "system", "content": "rules\n\nsummary"])
        XCTAssertEqual(out[1]["role"], "user")
        XCTAssertEqual(out[2]["role"], "assistant")
    }

    func testResponseParsers() throws {
        XCTAssertEqual(try AIBackendManager.parseOllamaChat(StubTransport.ollamaReply("hi")), "hi")
        XCTAssertEqual(try AIBackendManager.parseOpenAIChat(StubTransport.openAIReply("yo")), "yo")
        XCTAssertThrowsError(try AIBackendManager.parseOllamaChat(Data("{}".utf8)))
        XCTAssertThrowsError(try AIBackendManager.parseOpenAIChat(Data("not json".utf8)))
        XCTAssertThrowsError(try AIBackendManager.parseOpenAIChat(Data(#"{"choices":[]}"#.utf8)))
    }

    func testValidatorAcceptsNormalNarration() {
        XCTAssertEqual(NarrationValidator.clean("  \(AIFixtures.narration)\n "), AIFixtures.narration)
    }

    func testSanitizeActionsClamps() {
        let long = String(repeating: "x", count: 81)
        let raw = ["**Open door**", "open door", "", "  Talk  ", long, "a", "b", "c", "d", "e", "f"]
        let out = NarrationValidator.sanitizeActions(raw)
        XCTAssertEqual(out.first, "Open door")
        XCTAssertEqual(out.count, NarrationValidator.maxActions)
        XCTAssertFalse(out.contains(long))
        XCTAssertEqual(out.filter { $0.lowercased() == "open door" }.count, 1)
        XCTAssertTrue(out.contains("Talk"))
    }

    func testEndpointPolicy() {
        XCTAssertTrue(EndpointPolicy.isValidBaseURL("http://localhost:11434"))
        XCTAssertTrue(EndpointPolicy.isValidBaseURL("https://openrouter.ai/api/v1"))
        XCTAssertTrue(EndpointPolicy.isValidBaseURL("http://192.168.1.20:8080"))
        XCTAssertFalse(EndpointPolicy.isValidBaseURL("localhost:11434"))
        XCTAssertFalse(EndpointPolicy.isValidBaseURL("ftp://host"))
        XCTAssertFalse(EndpointPolicy.isValidBaseURL("javascript:alert(1)"))
        XCTAssertFalse(EndpointPolicy.isValidBaseURL("http://user:pw@host"))
        XCTAssertFalse(EndpointPolicy.isValidBaseURL(""))
        XCTAssertEqual(EndpointPolicy.normalizedBaseURL(" http://h:1/// "), "http://h:1")
        XCTAssertTrue(EndpointPolicy.isSecure(URL(string: "https://a.b")!))
        XCTAssertFalse(EndpointPolicy.isSecure(URL(string: "http://a.b")!))
    }

    func testStatusTextStates() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.updateStatus()
        XCTAssertTrue(m.statusText.contains("away"))
        m.isOllamaAvailable = true
        m.updateStatus()
        XCTAssertEqual(m.statusBackend, .ollama)
        XCTAssertEqual(m.statusText, "Narrator online: Ollama")
        m.aiEnabled = false
        m.updateStatus()
        XCTAssertEqual(m.statusText, "AI off: scripted narrator")
        XCTAssertNil(m.statusBackend)
    }

    func testFrontierModelsFollowConfiguredBase() {
        let models = ModelRegistry.frontierModels(from: ["a/b"], baseURL: "https://proxy.example/api/v1/")
        XCTAssertEqual(models.first?.endpoint, "https://proxy.example/api/v1/chat/completions")
    }
}

// MARK: - Security

final class AIParitySecurityTests: XCTestCase {

    func testKeyNeverSentOverPlainHTTP() {
        XCTAssertThrowsError(try OpenAICompatibleRequest.build(
            endpoint: "http://openrouter.example/v1/chat/completions", model: "m", messages: [],
            temperature: 0.5, maxTokens: 10, stream: false, headers: ["Authorization": "Bearer k"])) { error in
            XCTAssertEqual(error as? LLMError, .insecureEndpoint)
        }
        // Without a secret, local http is fine.
        XCTAssertNoThrow(try OpenAICompatibleRequest.build(
            endpoint: "http://localhost:8000/v1/chat/completions", model: "m", messages: [],
            temperature: 0.5, maxTokens: 10, stream: false))
    }

    func testCloudBackendRefusesHTTPEndpointWithoutNetwork() async {
        let stub = StubTransport { _ in (200, StubTransport.openAIReply("x")) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.setOpenAIAPIKey("sk-test-0000000000")
        m.openAIServerURL = "http://evil.example/v1"
        do {
            _ = try await m.send(backend: .openAI, model: "gpt", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
            XCTFail("must refuse http")
        } catch {
            XCTAssertEqual(error as? LLMError, .insecureEndpoint)
        }
        XCTAssertTrue(stub.requests.isEmpty, "nothing may leave the machine")
        XCTAssertFalse(m.cloudConfigured(.openAI), "an http cloud URL never counts as available")
    }

    func testCloudBackendWithoutKeyFailsWithoutNetwork() async {
        let stub = StubTransport { _ in (200, Data()) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        for backend in [LLMBackendType.openAI, .openRouter] {
            do {
                _ = try await m.send(backend: backend, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
                XCTFail("expected missing key")
            } catch {
                XCTAssertEqual(error as? LLMError, .missingAPIKey)
            }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testLocalBackendsNeverSendAuthorization() async throws {
        let stub = StubTransport { req in
            req.url?.path == "/api/chat" ? (200, StubTransport.ollamaReply("ok text here")) : (200, StubTransport.openAIReply("ok text here"))
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.setOpenAIAPIKey("sk-test-0000000000")
        m.setOpenRouterAPIKey("sk-or-test-000000000")
        for backend in [LLMBackendType.ollama, .tinyLLM, .tinyChat, .openWebUI, .novaGateway] {
            _ = try await m.send(backend: backend, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
        }
        XCTAssertEqual(stub.requests.count, 5)
        for req in stub.requests {
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "\(req.url!) must not carry a key")
        }
    }

    func testCloudRequestCarriesBearerAndBlompieAttribution() async throws {
        let stub = StubTransport { _ in (200, StubTransport.openAIReply("frontier says hi")) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.setOpenRouterAPIKey("sk-or-test-000000000")
        _ = try await m.send(backend: .openRouter, model: "anthropic/claude-sonnet-4.5", messages: AIFixtures.messages,
                             temperature: 0.5, maxTokens: 10)
        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.url?.scheme, "https")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test-000000000")
        XCTAssertEqual(req.value(forHTTPHeaderField: "HTTP-Referer"), "https://github.com/kochj23/Blompie")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "Blompie")
    }

    func testLegacyOpenRouterKeyMigratedOnceAndLegacyUntouched() throws {
        let id = UUID().uuidString
        let suite = "com.jordankoch.Blompie.tests.migrate.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let legacy = KeychainStore(service: "com.jordankoch.Blompie.tests.legacy.\(id)")
        let target = KeychainStore(service: "com.jordankoch.Blompie.tests.target.\(id)")
        defer { legacy.delete(); target.delete(); defaults.removePersistentDomain(forName: suite) }

        legacy.set("sk-or-legacy-value")
        AIBackendManager.migrateLegacyOpenRouterKey(defaults: defaults, to: target, legacy: legacy)
        XCTAssertEqual(target.get(), "sk-or-legacy-value")
        XCTAssertEqual(legacy.get(), "sk-or-legacy-value", "AIStudio's item is never modified")
        XCTAssertTrue(defaults.bool(forKey: AIBackendManager.openRouterMigratedFlag))

        // Read once: later changes to the legacy item are ignored.
        target.delete()
        legacy.set("sk-or-changed")
        AIBackendManager.migrateLegacyOpenRouterKey(defaults: defaults, to: target, legacy: legacy)
        XCTAssertNil(target.get())
    }

    func testMigrationNeverOverwritesExistingKey() {
        let id = UUID().uuidString
        let legacy = KeychainStore(service: "com.jordankoch.Blompie.tests.legacy.\(id)")
        let target = KeychainStore(service: "com.jordankoch.Blompie.tests.target.\(id)")
        defer { legacy.delete(); target.delete() }
        legacy.set("old")
        target.set("mine")
        XCTAssertFalse(KeychainStore.migrate(from: legacy, to: target))
        XCTAssertEqual(target.get(), "mine")
        XCTAssertFalse(KeychainStore.migrate(from: KeychainStore(service: "nothing.\(id)"), to: KeychainStore(service: "empty.\(id)")))
    }

    func testAIOffSendsNothing() async {
        let stub = StubTransport { _ in (200, StubTransport.ollamaReply("hello there traveller")) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.isOllamaAvailable = true
        m.aiEnabled = false
        do {
            _ = try await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
            XCTFail("AI off must not narrate")
        } catch {}
        await m.refreshAllBackends()
        XCTAssertTrue(stub.requests.isEmpty, "AI off: no request, not even probes")
    }

    func testKeychainRoundTripUnderTestService() {
        let store = KeychainStore(service: "com.jordankoch.Blompie.tests.\(UUID().uuidString)", account: "k")
        defer { store.delete() }
        XCTAssertFalse(store.hasValue)
        XCTAssertTrue(store.set("value-1"))
        XCTAssertEqual(store.get(), "value-1")
        XCTAssertTrue(store.set("value-2"))
        XCTAssertEqual(store.get(), "value-2")
        XCTAssertTrue(store.delete())
        XCTAssertNil(store.get())
    }

    func testEmptyKeyDeletesInsteadOfStoringBlank() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.setOpenAIAPIKey("sk-test-1")
        XCTAssertTrue(m.hasOpenAIKey)
        m.setOpenAIAPIKey("   ")
        XCTAssertFalse(m.hasOpenAIKey)
        XCTAssertNil(m.openAIKeychain.get())
    }
}

// MARK: - Retry

final class AIParityRetryTests: XCTestCase {

    func testTransient503IsRetriedThenSucceeds() async throws {
        var first = true
        let lock = NSLock()
        let stub = StubTransport { _ in
            lock.lock(); defer { lock.unlock() }
            if first { first = false; return (503, Data()) }
            return (200, StubTransport.ollamaReply("second time lucky"))
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        let text = try await m.send(backend: .ollama, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
        XCTAssertEqual(text, "second time lucky")
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testPermanent4xxIsNotRetried() async {
        let stub = StubTransport { _ in (404, Data()) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        do {
            _ = try await m.send(backend: .tinyLLM, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
            XCTFail("404 must throw")
        } catch {
            XCTAssertEqual(error as? HTTPStatusError, HTTPStatusError(statusCode: 404))
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testRetriesAreBounded() async {
        let stub = StubTransport { _ in (500, Data()) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        _ = try? await m.send(backend: .novaGateway, model: "nova", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testAutoFailsOverInFixedOrder() async throws {
        let stub = StubTransport { req in
            switch req.url?.host {
            case "ollama.test": return (500, Data())
            case "tiny.test": return (200, StubTransport.openAIReply(AIFixtures.narration))
            default: return (200, StubTransport.openAIReply("should not be reached"))
            }
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.ollamaServerURL = "http://ollama.test:11434"
        m.tinyLLMServerURL = "http://tiny.test:8000"
        m.isOllamaAvailable = true
        m.isTinyLLMAvailable = true
        m.isNovaGatewayAvailable = true
        let reply = try await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
        XCTAssertEqual(reply.backend, .tinyLLM)
        XCTAssertEqual(reply.text, AIFixtures.narration)
        XCTAssertEqual(stub.hosts, ["ollama.test", "ollama.test", "tiny.test"], "Ollama (2 bounded attempts), then TinyLLM; Nova untouched")
        XCTAssertFalse(m.isOllamaAvailable, "a failed backend is marked unreachable")
        XCTAssertEqual(m.lastNarrationBackend, .tinyLLM)
    }

    func testInvalidOutputFailsOverToNextBackend() async throws {
        let stub = StubTransport { req in
            req.url?.path == "/api/chat"
                ? (200, StubTransport.ollamaReply("<think>only reasoning, never closed"))
                : (200, StubTransport.openAIReply(AIFixtures.narration))
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.isOllamaAvailable = true
        m.isNovaGatewayAvailable = true
        let reply = try await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
        XCTAssertEqual(reply.backend, .novaGateway)
        XCTAssertTrue(m.isOllamaAvailable, "nonsense output is not an outage")
    }

    func testExplicitBackendDoesNotFailOver() async {
        let stub = StubTransport { req in
            req.url?.path == "/api/chat" ? (500, Data()) : (200, StubTransport.openAIReply(AIFixtures.narration))
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.activeBackend = .ollama
        m.isTinyLLMAvailable = true
        do {
            _ = try await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
            XCTFail("explicit backend failing must throw (caller goes scripted)")
        } catch {}
        XCTAssertTrue(stub.requests.allSatisfy { $0.url?.path == "/api/chat" })
    }

    func testTimeoutsAreApplied() async throws {
        let stub = StubTransport { req in
            req.url?.path == "/api/chat" ? (200, StubTransport.ollamaReply("local text ok")) : (200, StubTransport.openAIReply("cloud text ok"))
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.setOpenAIAPIKey("sk-test-0000000000")
        _ = try await m.send(backend: .ollama, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
        _ = try await m.send(backend: .openAI, model: "m", messages: AIFixtures.messages, temperature: 0.5, maxTokens: 10)
        XCTAssertEqual(stub.requests[0].timeoutInterval, m.localRequestTimeout)
        XCTAssertEqual(stub.requests[1].timeoutInterval, m.cloudRequestTimeout)
        _ = await m.probe(.ollama)
        XCTAssertEqual(stub.requests[2].timeoutInterval, m.probeTimeout)
    }

    func testBalancerFailureFallsThroughToChain() async throws {
        let stub = StubTransport { req in
            let port = req.url?.port ?? 0, path = req.url?.path ?? ""
            if port == 18792 { return path == "/v1/models" ? (200, Data("{}".utf8)) : (502, Data()) }  // Nova healthy, chat fails
            return path == "/api/chat" ? (200, StubTransport.ollamaReply(AIFixtures.narration)) : (404, Data())
        }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.useNovaGateway = true
        m.isOllamaAvailable = true
        let reply = try await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
        XCTAssertEqual(reply.backend, .ollama)
        XCTAssertEqual(stub.requests.filter { $0.url?.port == 18792 && $0.url?.path == "/v1/chat/completions" }.count, 2)
    }
}

// MARK: - Performance

final class AIParityPerformanceTests: XCTestCase {

    private func elapsed(_ block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent(); block(); return CFAbsoluteTimeGetCurrent() - start
    }

    func testValidatorThroughput() {
        let text = String(repeating: "You walk down a winding path past an old mill. ", count: 40) + "\nACTIONS: a | b"
        let t = elapsed { for _ in 0..<2_000 { _ = NarrationValidator.clean(text) } }
        XCTAssertLessThan(t, 3.0, "2k validations took \(t)s")
    }

    func testValidatorMeasure() {
        let text = "<think>plan</think>" + String(repeating: "A lantern flickers in the hall. ", count: 30)
        measure { for _ in 0..<500 { _ = NarrationValidator.clean(text) } }
    }

    func testScriptedNarratorThroughput() {
        let n = ScriptedNarrator()
        let actions = ["Go north", "Talk to Pim", "Go up", "Take the silver bell clapper", "Go down", "Go south", "Look around", "dance"]
        let t = elapsed { for i in 0..<10_000 { _ = n.respond(to: actions[i % actions.count]) } }
        XCTAssertLessThan(t, 2.0, "10k scripted turns took \(t)s")
    }

    func testNarrateFailsFastWhenNothingIsReachable() async {
        let stub = StubTransport { _ in (200, Data()) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        let start = Date()
        _ = try? await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(stub.requests.isEmpty, "fresh availability says nothing is up: no request")
    }

    func testAutoChainComputationIsCheap() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.isOllamaAvailable = true; m.isNovaGatewayAvailable = true
        let t = elapsed { for _ in 0..<20_000 { _ = m.autoChain() } }
        XCTAssertLessThan(t, 2.0)
    }
}

// MARK: - Integration

@MainActor
final class AIParityIntegrationTests: XCTestCase {

    func testEngineAppliesNarratorReplyAndLabelsSource() async {
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration, backend: .novaGateway)])
        let engine = makeEngine(narrator)
        engine.startNewGame()
        await settle(engine)
        XCTAssertEqual(engine.lastNarrationSource, .ai(.novaGateway))
        XCTAssertEqual(engine.currentActions, ["Talk to Orrin", "Go north", "Look around"])
        XCTAssertTrue(engine.messages.contains { $0.text.contains("sunlit clearing") })
        XCTAssertFalse(engine.storyIsScripted)
    }

    func testManagerAndEngineEndToEndThroughStubTransport() async {
        let stub = StubTransport { _ in (200, StubTransport.ollamaReply(AIFixtures.narration)) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.ollamaServerURL = "http://studio.lan:11434"
        m.isOllamaAvailable = true
        let engine = makeEngine(m)
        engine.selectedModel = "qwen3:8b"
        engine.startNewGame()
        await settle(engine)
        XCTAssertEqual(engine.lastNarrationSource, .ai(.ollama))
        let req = stub.requests.first
        XCTAssertEqual(req?.url?.absoluteString, "http://studio.lan:11434/api/chat", "story path honours the configured Ollama URL")
        let body = (try? JSONSerialization.jsonObject(with: req?.httpBody ?? Data())) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "qwen3:8b")
    }

    func testPlayHistoryRecordsFallbackSource() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)])   // opening ok, turn fails
        let engine = makeEngine(narrator, logger: logger)
        engine.startNewGame()
        await settle(engine)
        await act(engine, "Talk to Orrin")
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        XCTAssertEqual(sink.eventKinds(s.id), ["start", "scene", "turn"])
        let turn = PlayFixtures.json(try XCTUnwrap(sink.events[s.id]?[2]).detailJSON)
        XCTAssertEqual(turn["source"] as? String, "fallback")
        XCTAssertNil(turn["failed"], "a fallback turn is a completed turn")
        let scene = PlayFixtures.json(try XCTUnwrap(sink.events[s.id]?[1]).detailJSON)
        XCTAssertEqual(scene["source"] as? String, "llm")
        XCTAssertEqual(PlayFixtures.json(s.summaryJSON)["fallbacks"] as? Int, 1)
        XCTAssertEqual(s.actions, 1)
    }

    func testPlayHistoryRecordsScriptedSourceWhenAIOff() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = makeEngine(StubNarrator(aiEnabled: false), logger: logger)
        engine.startNewGame()
        await settle(engine)
        await act(engine, "Go north")
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        let start = PlayFixtures.json(try XCTUnwrap(sink.events[s.id]?[0]).detailJSON)
        XCTAssertEqual(start["ai_enabled"] as? Bool, false)
        let turn = PlayFixtures.json(try XCTUnwrap(sink.events[s.id]?[2]).detailJSON)
        XCTAssertEqual(turn["source"] as? String, "scripted")
    }
}

// MARK: - Functional

@MainActor
final class AIParityFunctionalTests: XCTestCase {

    func testFailedAICallNeverLosesTheTurn() async {
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)])
        let engine = makeEngine(narrator)
        engine.startNewGame()
        await settle(engine)
        let before = engine.messages.count
        await act(engine, "Go north")
        XCTAssertFalse(engine.isLoading)
        XCTAssertEqual(engine.lastNarrationSource, .fallback)
        XCTAssertGreaterThan(engine.messages.count, before + 2, "the turn produced narration")
        XCTAssertFalse(engine.messages.contains { $0.text.contains("ERROR") })
        XCTAssertEqual(engine.currentActions, ["Talk to Orrin", "Go north", "Look around"], "previous actions kept for a retry")
        XCTAssertEqual(engine.fallbackTurns, 1)
    }

    func testAIOffGameIsFullyPlayable() async {
        let narrator = StubNarrator(aiEnabled: false)
        let engine = makeEngine(narrator)
        engine.startNewGame()
        await settle(engine)
        XCTAssertEqual(engine.lastNarrationSource, .scripted)
        XCTAssertTrue(engine.currentActions.contains("Take the brass compass"))
        await act(engine, "Take the brass compass")
        XCTAssertTrue(engine.inventory.contains { $0.contains("brass compass") })
        await act(engine, "Go north")
        XCTAssertEqual(engine.scripted.location, "tower")
        XCTAssertTrue(engine.locationHistory.contains { $0.contains("Bell Tower") })
        await act(engine, "Talk to Pim")
        XCTAssertTrue(engine.metNPCs.contains("Pim"))
        await act(engine, "Go up")
        await act(engine, "Take the silver bell clapper")
        XCTAssertEqual(engine.scripted.taken, ["brass compass", "silver bell clapper"])
        XCTAssertEqual(narrator.calls, 0, "AI off never calls the narrator")
        XCTAssertTrue(engine.achievements.first { $0.id == "first_step" }?.isUnlocked == true)
    }

    func testOpeningFailureStartsScriptedStory() async {
        let engine = makeEngine(StubNarrator.failing())
        engine.startNewGame()
        await settle(engine)
        XCTAssertTrue(engine.storyIsScripted)
        XCTAssertEqual(engine.lastNarrationSource, .fallback)
        XCTAssertTrue(engine.messages.contains { $0.text.contains("This is Blompie") })
        await act(engine, "Go east")
        XCTAssertEqual(engine.scripted.location, "market", "a scripted story keeps using the scripted world")
    }

    func testModelActionsAreSanitized() async {
        let reply = "A hall of doors.\nACTIONS: a | b | B | c | d | e | f | g | " + String(repeating: "z", count: 120)
        let engine = makeEngine(StubNarrator(replies: [StubNarrator.ok(reply)]))
        engine.startNewGame()
        await settle(engine)
        XCTAssertEqual(engine.currentActions, ["a", "b", "c", "d", "e", "f"])
    }

    func testPromptEchoFromModelIsRejectedAndScriptedAnswers() async {
        let echo = "You are the game master. Your role is to: CRITICAL FORMAT REQUIREMENT ... PROGRESS IS MANDATORY"
        let stub = StubTransport { _ in (200, StubTransport.ollamaReply(echo)) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.isOllamaAvailable = true
        let engine = makeEngine(m)
        engine.startNewGame()
        await settle(engine)
        XCTAssertEqual(engine.lastNarrationSource, .fallback)
        XCTAssertFalse(engine.messages.contains { $0.text.contains("CRITICAL FORMAT") })
    }

    func testScriptedWorldIsConnected() {
        let ids = Set(ScriptedNarrator.places.map(\.id))
        var seen: Set<String> = ["meadow"]
        var queue = ["meadow"]
        while let id = queue.popLast() {
            let place = ScriptedNarrator.places.first { $0.id == id }!
            for exit in place.exits {
                XCTAssertTrue(ids.contains(exit.to), "\(id) -> \(exit.to)")
                if seen.insert(exit.to).inserted { queue.append(exit.to) }
            }
        }
        XCTAssertEqual(seen, ids, "every place is reachable from the meadow")
    }

    func testScriptedNarratorIsDeterministic() {
        let a = ScriptedNarrator(), b = ScriptedNarrator()
        XCTAssertEqual(a.opening(), b.opening())
        for action in ["Go west", "Talk to Tansy", "Talk to Tansy", "sing", "Go north", "Take the glass key", "Take it again"] {
            XCTAssertEqual(a.respond(to: action), b.respond(to: action), action)
        }
        XCTAssertEqual(a.taken, ["glass key"])
    }

    func testEveryScriptedReplyParsesToActions() {
        let n = ScriptedNarrator()
        for text in [n.opening(), n.respond(to: "Go north"), n.respond(to: "nonsense"), n.awayLine(keeping: [])] {
            let last = text.components(separatedBy: "\n").last ?? ""
            XCTAssertTrue(last.hasPrefix("ACTIONS: "), text)
            XCTAssertNotNil(NarrationValidator.clean(text))
        }
    }
}

// MARK: - Frame

final class AIParityFrameTests: XCTestCase {

    func testSharedManagerIsIsolatedUnderTests() {
        let shared = AIBackendManager.shared
        XCTAssertTrue(AIBackendManager.isRunningTests)
        XCTAssertEqual(shared.keychainService, "com.jordankoch.Blompie.tests")
        XCTAssertEqual(shared.openRouterKeychain.service, "com.jordankoch.Blompie.tests.openrouter")
        XCTAssertFalse(shared.defaults === UserDefaults.standard)
    }

    func testFreshManagerDefaults() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        XCTAssertTrue(m.aiEnabled)
        XCTAssertEqual(m.activeBackend, .auto)
        XCTAssertFalse(m.isBalancingEnabled)
        XCTAssertEqual(m.retryPolicy.maxAttempts, 2)
        XCTAssertEqual(m.localRequestTimeout, 180)
        XCTAssertEqual(m.cloudRequestTimeout, 60)
        XCTAssertEqual(m.probeTimeout, 3)
        XCTAssertEqual(m.balancerPolicy, .leastBusy)
    }

    @MainActor
    func testGameEngineDefaultsToSharedNarrator() {
        let engine = GameEngine()
        XCTAssertTrue(engine.narrator === AIBackendManager.shared)
        XCTAssertNil(engine.lastNarrationSource)
        XCTAssertFalse(engine.storyIsScripted)
    }

    func testSettingsPersistRoundTrip() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.aiEnabled = false
        m.activeBackend = .openWebUI
        m.openWebUIServerURL = "http://webui.lan:3000"
        m.selectedOpenAIModel = "gpt-4.1-mini"
        m.saveConfiguration()
        m.aiEnabled = true; m.activeBackend = .auto; m.openWebUIServerURL = ""; m.selectedOpenAIModel = ""
        m.loadConfiguration()
        XCTAssertFalse(m.aiEnabled)
        XCTAssertEqual(m.activeBackend, .openWebUI)
        XCTAssertEqual(m.openWebUIServerURL, "http://webui.lan:3000")
        XCTAssertEqual(m.selectedOpenAIModel, "gpt-4.1-mini")
        XCTAssertEqual(m.defaults.string(forKey: "AIBackend_Active"), "openwebui", "stable lowercase id is persisted")
    }

    func testOpenRouterProviderConstants() {
        XCTAssertTrue(OpenRouterProvider.baseURL.hasPrefix("https://"))
        XCTAssertEqual(OpenRouterProvider.title, "Blompie")
        XCTAssertFalse(OpenRouterProvider.referer.contains("AIStudio"))
        XCTAssertEqual(OpenRouterProvider.legacyKeychainService, "com.jkoch.aistudio.openrouter")
    }
}
