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
import NovaAIKit
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
        XCTAssertLessThan(t, 4.0, "2k validations took \(t)s")
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

// MARK: - Spectator mode ("Watch AI Play")

/// Wait (bounded) until `done` is true.
@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
}

/// A spectator engine that plays fast: no delay, a small turn cap.
@MainActor
private func spectator(_ narrator: StoryNarrating, logger: PlayLogger? = nil, maxTurns: Int = 6) -> GameEngine {
    let engine = makeEngine(narrator, logger: logger)
    engine.spectatorDelay = 0
    engine.spectatorMaxTurns = maxTurns
    return engine
}

final class SpectatorUnitTests: XCTestCase {

    func testValidateTakesTheCommandLine() {
        XCTAssertEqual(PlayerCommand.validate("I think exploring is best.\nCOMMAND: Go north."), "Go north")
        XCTAssertEqual(PlayerCommand.validate("**COMMAND:** `Talk to Pim`"), "Talk to Pim")
        XCTAssertEqual(PlayerCommand.validate("> look around"), "look around")
    }

    func testValidateRejectsUnusableReplies() {
        XCTAssertNil(PlayerCommand.validate(""))
        XCTAssertNil(PlayerCommand.validate("COMMAND: ???"))
        XCTAssertNil(PlayerCommand.validate("COMMAND: " + String(repeating: "a", count: 600)), "longer than the 500-char limit")
    }

    func testPickPrefersUntriedThenTakeTalkMove() {
        let actions = ["Look around", "Go north", "Talk to Pim", "Take the lamp"]
        let k = { Adventurer.key($0, in: actions) }
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [:]), "Take the lamp")
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [k("Take the lamp"): 1]), "Talk to Pim")
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [k("Take the lamp"): 1, k("Talk to Pim"): 1]), "Go north")
        XCTAssertEqual(Adventurer.pick(from: actions, tried: ["take the lamp@other scene": 5]), "Take the lamp",
                       "counts are per scene")
        XCTAssertEqual(Adventurer.pick(from: [], tried: [:]), "Look around", "never stalls on an empty list")
    }

    func testLoopAndEndDetection() {
        XCTAssertTrue(Adventurer.isLooping(Array(repeating: ["go north", "go south"], count: 4).flatMap { $0 }))
        XCTAssertFalse(Adventurer.isLooping(["go north", "go south", "go north"]), "too short to judge")
        XCTAssertFalse(Adventurer.isLooping(["a", "b", "c", "a", "b", "c", "a", "b"]))
        XCTAssertTrue(Adventurer.storyEnded("And so the bell rang. THE END"))
        XCTAssertTrue(Adventurer.storyEnded("Game Over."))
        XCTAssertFalse(Adventurer.storyEnded("You reach the end of the hall."))
    }

    func testPromptCarriesStoryActionsAndRecentCommands() {
        let p = Adventurer.prompt(story: ["You are in a hall."], actions: ["Go north", "Look around"], recent: ["look around"])
        XCTAssertEqual(p.map(\.role), ["system", "user"])
        XCTAssertTrue(p[0].content.contains("COMMAND:"))
        XCTAssertTrue(p[1].content.contains("Go north | Look around"))
        XCTAssertTrue(p[1].content.contains("look around"))
    }
}

final class SpectatorSecurityTests: XCTestCase {

    func testValidateStripsControlAndBidiCharacters() {
        XCTAssertEqual(PlayerCommand.validate("COMMAND: Go\u{202E} no\u{200B}rth\u{0007}"), "Go north")
    }

    func testPromptBoundsUntrustedStoryText() {
        let huge = String(repeating: "x", count: 50_000)
        let p = Adventurer.prompt(story: Array(repeating: huge, count: 12), actions: [], recent: [])
        XCTAssertLessThan(p[1].content.count, 12 * 401 + 200)
    }

    /// Watch contract v2: a watch game is recorded as player "AI vs AI" with summary.spectator, never as a human.
    @MainActor
    func testWatchSessionIsRecordedAsAIvsAINeverAsTheHuman() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = spectator(StubNarrator(aiEnabled: false), logger: logger, maxTurns: 4)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        XCTAssertEqual(sink.allSessions.count, 1)
        XCTAssertEqual(s.player, "AI vs AI")
        XCTAssertNotEqual(s.player, PlayLogger.player)
        XCTAssertEqual(s.outcome, "turn_limit")
        XCTAssertEqual(s.actions, 4)
        XCTAssertEqual(sink.eventKinds(s.id), ["start", "scene", "turn", "turn", "turn", "turn"])
        let summary = PlayFixtures.json(s.summaryJSON)
        XCTAssertEqual(summary["spectator"] as? Bool, true)
        XCTAssertEqual(summary["started_from"] as? String, "watch")
    }
}

final class SpectatorRetryTests: XCTestCase {

    @MainActor
    func testFailedAIAdventurerFallsBackToHeuristic() async {
        // opening narrated by AI, then every call (adventurer and narrator) fails
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)])
        let engine = spectator(narrator, maxTurns: 2)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.spectatorTurns, 2, "never stalls")
        XCTAssertEqual(engine.lastAdventurerSource, .fallback)
        XCTAssertEqual(engine.adventurerFallbacks, 2)
        XCTAssertEqual(engine.actionHistory.first, "Talk to Orrin", "heuristic picked from the suggested actions")
    }

    @MainActor
    func testInvalidAIReplyFallsBackToHeuristic() async {
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration), StubNarrator.ok("COMMAND: ####")])
        let engine = spectator(narrator, maxTurns: 1)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.actionHistory, ["Talk to Orrin"])
        XCTAssertEqual(engine.lastAdventurerSource, .fallback)
    }
}

final class SpectatorPerformanceTests: XCTestCase {

    func testPickAndValidateAreCheap() {
        let actions = ["Take the lamp", "Talk to Pim", "Go north", "Go east", "Look around", "Dance"]
        let start = CFAbsoluteTimeGetCurrent()
        var tried: [String: Int] = [:]
        for _ in 0..<20_000 {
            let a = Adventurer.pick(from: actions, tried: tried)
            tried[Adventurer.key(a, in: actions), default: 0] += 1
            _ = PlayerCommand.validate("Thinking.\nCOMMAND: \(a)")
        }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 3.0)
    }
}

@MainActor
final class SpectatorIntegrationTests: XCTestCase {

    func testAIAdventurerCommandReachesTheNarrator() async {
        let narrator = StubNarrator(replies: [
            StubNarrator.ok(AIFixtures.narration),                         // opening
            StubNarrator.ok("COMMAND: Talk to Orrin", backend: .novaGateway), // adventurer
            StubNarrator.ok(AIFixtures.narration)                          // narrator's reply
        ])
        let engine = spectator(narrator, maxTurns: 1)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.actionHistory, ["Talk to Orrin"])
        XCTAssertEqual(engine.lastAdventurerSource, .ai(.novaGateway))
        XCTAssertEqual(engine.lastNarrationSource, .ai(.ollama))
        XCTAssertTrue(engine.messages.contains { $0.text == "> Talk to Orrin" })
    }

    func testPlayerSessionIsClosedAndWatchSessionCarriesMatchup() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = spectator(StubNarrator(aiEnabled: false), logger: logger, maxTurns: 3)
        engine.startNewGame()                         // the player's own game
        await settle(engine)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        _ = await logger.drainNow()
        let human = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.player })
        XCTAssertEqual(sink.eventKinds(human.id), ["start", "scene"], "no watch turns in the player's session")
        XCTAssertEqual(human.outcome, "completed")
        XCTAssertNil(PlayFixtures.json(human.summaryJSON)["spectator"])
        let watch = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.watchPlayer })
        let summary = PlayFixtures.json(watch.summaryJSON)
        let sides = try XCTUnwrap((summary["matchup"] as? [String: Any])?["sides"] as? [[String: Any]])
        XCTAssertEqual(sides.map { $0["side"] as? String }, ["adventurer", "narrator"])
        XCTAssertEqual(sides.map { $0["kind"] as? String }, ["engine", "engine"], "AI off: both sides are the built-in AI")
        XCTAssertEqual(sides.first?["label"] as? String, "Heuristic adventurer")
        XCTAssertEqual(summary["fallbacks"] as? [String: Int], ["adventurer": 0, "narrator": 0])
    }

    func testTakeOverEndsWatchAsTakenOverAndStartsAHumanSession() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = spectator(StubNarrator(aiEnabled: false), logger: logger, maxTurns: 50)
        engine.spectatorDelay = 0.3
        engine.startSpectating()
        await waitUntil { engine.spectatorTurns >= 2 }
        await waitUntil { !engine.isLoading }
        engine.takeOver()
        engine.performAction("Look around")
        await waitUntil { !engine.isLoading }
        _ = await logger.drainNow()
        let watch = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.watchPlayer })
        XCTAssertEqual(watch.outcome, "taken_over")
        XCTAssertNotNil(watch.endedAt)
        XCTAssertEqual(watch.actions, engine.spectatorTurns, "everything before the take-over stays in the watch record")
        let human = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.player })
        XCTAssertNil(human.endedAt)
        XCTAssertEqual(human.actions, 1)
        XCTAssertEqual(sink.eventKinds(human.id), ["start", "turn"])
        let summary = PlayFixtures.json(human.summaryJSON)
        XCTAssertNil(summary["spectator"])
        XCTAssertEqual(summary["started_from"] as? String, "takeover")
    }
}

@MainActor
final class SpectatorFunctionalTests: XCTestCase {

    func testHeuristicExploresTheWholeScriptedWorldWithoutLooping() {
        let world = ScriptedNarrator()
        var tried: [String: Int] = [:], recent: [String] = [], visited: Set<String> = [world.location]
        for _ in 0..<Adventurer.maxTurns {
            let actions = world.actions(for: world.currentPlace)
            let command = Adventurer.pick(from: actions, tried: tried)
            tried[Adventurer.key(command, in: actions), default: 0] += 1
            recent = Array((recent + [command.lowercased()]).suffix(Adventurer.loopWindow))
            XCTAssertFalse(Adventurer.isLooping(recent), "looping at \(command)")
            _ = world.respond(to: command)
            visited.insert(world.location)
        }
        XCTAssertEqual(visited, Set(ScriptedNarrator.places.map(\.id)))
        XCTAssertEqual(world.taken.count, 4, "every item collected")
    }

    func testTurnCapStopsSpectating() async {
        let engine = spectator(StubNarrator(aiEnabled: false), maxTurns: 5)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.spectatorTurns, 5)
        XCTAssertEqual(engine.lastAdventurerSource, .scripted)
        XCTAssertTrue(engine.messages.contains { $0.text.contains("5-turn limit") })
    }

    func testStoryEndStopsSpectating() async {
        let ending = "The bell rings and the meadow sings. THE END\nACTIONS: Look around"
        let engine = spectator(StubNarrator(replies: [StubNarrator.ok(ending)]))
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.spectatorTurns, 0)
        XCTAssertTrue(engine.messages.contains { $0.text.contains("the story ended") })
    }

    func testPauseHoldsAndResumeContinues() async {
        let engine = spectator(StubNarrator(aiEnabled: false), maxTurns: 50)
        engine.startSpectating()
        engine.spectatorPaused = true
        defer { engine.stopSpectating(reason: nil) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(engine.spectatorTurns, 0, "paused: no turns")
        engine.spectatorPaused = false
        await waitUntil { engine.spectatorTurns >= 2 }
        XCTAssertGreaterThanOrEqual(engine.spectatorTurns, 2)
    }

    func testTakeOverStopsTheAdventurerAndKeepsTheStory() async {
        let engine = spectator(StubNarrator(aiEnabled: false), maxTurns: 50)
        engine.spectatorDelay = 0.3
        engine.startSpectating()
        await waitUntil { engine.spectatorTurns >= 1 }
        engine.takeOver()
        await waitUntil { !engine.isLoading }
        let turns = engine.spectatorTurns, story = engine.messages.count
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(engine.isSpectating)
        XCTAssertEqual(engine.spectatorTurns, turns, "no turns after take-over")
        XCTAssertTrue(engine.messages.contains { $0.text.contains("you took over") })
        XCTAssertEqual(engine.messages.count, story)
        XCTAssertFalse(engine.watchSession, "after a take-over the player's session is a normal one")
    }

    func testAfterTheWatchStopsTheNextActionStartsAHumanSession() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = spectator(StubNarrator(aiEnabled: false), logger: logger, maxTurns: 2)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        await waitUntil { !engine.isLoading }
        engine.performAction("Look around")
        await waitUntil { !engine.isLoading }
        _ = await logger.drainNow()
        XCTAssertEqual(sink.allSessions.first { $0.player == PlayLogger.watchPlayer }?.outcome, "turn_limit")
        let human = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.player })
        XCTAssertEqual(PlayFixtures.json(human.summaryJSON)["started_from"] as? String, "after_watch")
        XCTAssertEqual(human.actions, 1)
    }

    func testMatchupWithAIOnNamesTheModel() {
        let engine = makeEngine(StubNarrator(aiEnabled: true))
        engine.selectedModel = "qwen3:8b"
        let sides = engine.watchMatchup()["sides"] as? [[String: Any]] ?? []
        XCTAssertEqual(sides.count, 2)
        XCTAssertEqual(sides.map { $0["kind"] as? String }, ["model", "model"])
        XCTAssertEqual(sides.first?["model"] as? String, "qwen3:8b")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(engine.watchMatchup()))
    }

    func testSpectatingEarnsNoAchievements() async {
        let engine = spectator(StubNarrator(aiEnabled: false), maxTurns: 6)
        let before = engine.achievements.filter(\.isUnlocked).count
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(engine.achievements.filter(\.isUnlocked).count, before)
    }
}

/// UI state behind the SPECTATING bar and the Watch AI Play button.
@MainActor
final class SpectatorFrameTests: XCTestCase {

    func testDefaults() {
        let engine = makeEngine(StubNarrator(aiEnabled: false))
        XCTAssertFalse(engine.isSpectating)
        XCTAssertFalse(engine.spectatorPaused)
        XCTAssertEqual(engine.spectatorDelay, 3)
        XCTAssertEqual(engine.spectatorMaxTurns, Adventurer.maxTurns)
        XCTAssertEqual(engine.spectatorTurns, 0)
        XCTAssertNil(engine.lastAdventurerSource)
        XCTAssertFalse(engine.watchSession)
    }

    func testStartShowsIndicatorAndNewGameClearsIt() async {
        let engine = spectator(StubNarrator(aiEnabled: false), maxTurns: 50)
        engine.spectatorDelay = 5
        engine.startSpectating()
        XCTAssertTrue(engine.isSpectating)
        XCTAssertTrue(engine.watchSession)
        XCTAssertTrue(engine.messages.contains { $0.text.hasPrefix("[SPECTATING") })
        engine.startNewGame()
        XCTAssertFalse(engine.isSpectating)
        XCTAssertFalse(engine.watchSession)
        await settle(engine)
    }

    func testLoadGameEndsSpectatingAndRecordsAgain() {
        let engine = spectator(StubNarrator(aiEnabled: false))
        let slot = "spectator-test-\(UUID().uuidString)"
        engine.saveGame(toSlot: slot)
        defer { engine.deleteSaveSlot(slot) }
        engine.spectatorDelay = 5
        engine.startSpectating()
        XCTAssertTrue(engine.isSpectating)
        engine.loadGame(fromSlot: slot)
        XCTAssertFalse(engine.isSpectating)
        XCTAssertFalse(engine.watchSession)
    }
}

// MARK: - Model vs model (NovaAIKit sides)

/// Stub for an overridden side: answers in order, records each request.
@MainActor
final class StubSideAI: SideAI {
    var replies: [Result<String, Error>]
    private(set) var requests: [(side: WatchSide, messages: [OllamaMessage])] = []

    init(_ replies: [Result<String, Error>] = []) { self.replies = replies }

    func complete(messages: [OllamaMessage], side: WatchSide, temperature: Double, maxTokens: Int) async throws -> SideReply {
        requests.append((side, messages))
        guard !replies.isEmpty else { throw LLMError.noBackendAvailable }
        return SideReply(text: try replies.removeFirst().get(), backend: side.backend.rawValue, model: side.model, latency: 0.012)
    }
}

/// A watch engine whose sides can be overridden.
@MainActor
private func duel(_ narrator: StoryNarrating, sides: StubSideAI, logger: PlayLogger? = nil, maxTurns: Int = 1,
                  adventurer: WatchSide = WatchSide(), narratorSide: WatchSide = WatchSide()) -> GameEngine {
    let engine = GameEngine(playLogger: logger, narrator: narrator, sideAI: sides)
    engine.autoSaveEnabled = false
    engine.streamingEnabled = false
    engine.spectatorDelay = 0
    engine.spectatorMaxTurns = maxTurns
    engine.adventurerSide = adventurer
    engine.narratorSide = narratorSide
    return engine
}

private let claude = WatchSide(backend: .anthropic, model: "claude-sonnet-5-5")
private let gpt = WatchSide(backend: .openAI, model: "gpt-5.1")

final class ModelVsModelUnitTests: XCTestCase {

    func testWatchSideDefaultsAndRoundTrip() throws {
        XCTAssertEqual(WatchSide().backend, .auto)
        XCTAssertFalse(WatchSide().isOverride)
        XCTAssertTrue(claude.isOverride)
        let suite = "com.jordankoch.Blompie.tests.sides.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        claude.save("k", defaults: defaults)
        XCTAssertEqual(WatchSide.load("k", defaults: defaults), claude)
        XCTAssertEqual(WatchSide.load("missing", defaults: defaults), WatchSide())
    }

    func testModelSourceLabels() {
        let s = NarrationSource.model("Anthropic Claude claude-sonnet-5-5")
        XCTAssertTrue(s.isAI)
        XCTAssertEqual(s.playValue, "llm")
        XCTAssertEqual(s.label, "AI via Anthropic Claude claude-sonnet-5-5")
    }

    func testReaskLimitIsTwo() {
        XCTAssertEqual(GameEngine.maxReasks, 2)
    }
}

final class ModelVsModelSecurityTests: XCTestCase {

    func testAllowNovaOffKeepsNovaOutOfEveryPath() {
        let (m, done) = AIFixtures.manager(StubTransport { _ in (200, Data()) }); defer { done() }
        m.isOllamaAvailable = true; m.isNovaGatewayAvailable = true
        XCTAssertTrue(m.autoChain().contains(.novaGateway))
        m.allowNova = false
        XCTAssertFalse(m.autoChain().contains(.novaGateway), "Auto skips Nova")
        m.useNovaGateway = true
        XCTAssertFalse(m.isBalancingEnabled, "Nova alone cannot enable the balanced pool")
        m.saveConfiguration(); m.allowNova = true; m.loadConfiguration()
        XCTAssertFalse(m.allowNova, "persisted")
    }

    func testExplicitNovaWithAllowNovaOffSendsNothing() async {
        let stub = StubTransport { _ in (200, StubTransport.ollamaReply(AIFixtures.narration)) }
        let (m, done) = AIFixtures.manager(stub); defer { done() }
        m.activeBackend = .novaGateway
        m.allowNova = false
        _ = try? await m.narrate(messages: AIFixtures.messages, model: "m", temperature: 0.5, onChunk: nil)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    @MainActor
    func testKitInstanceIsIsolatedUnderTests() {
        XCTAssertFalse(BlompieAI.shared.hasAPIKey(for: .anthropic), "tests never see the player's Keychain")
        XCTAssertEqual(BlompieAI.shared.configuration.appID, NovaAIConfiguration.normalizedID("Blompie"))
    }

    @MainActor
    func testModelReplyEventIsBounded() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = duel(StubNarrator(aiEnabled: false), sides: StubSideAI(), logger: logger)
        engine.spectatorDelay = 5
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        engine.recordModelReply(side: "adventurer", backend: "anthropic", model: String(repeating: "m", count: 500),
                                text: String(repeating: "x", count: 5000), latency: 1.5, valid: false, attempt: 3,
                                error: String(repeating: "e", count: 900))
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        let e = try XCTUnwrap(sink.events[s.id]?.values.first { $0.kind == "model_reply" })
        let d = PlayFixtures.json(e.detailJSON)
        XCTAssertEqual((d["excerpt"] as? String)?.count, 120)
        XCTAssertEqual((d["model"] as? String)?.count, 64)
        XCTAssertEqual((d["error"] as? String)?.count, 160)
        XCTAssertEqual(d["latency_ms"] as? Int, 1500)
    }
}

@MainActor
final class ModelVsModelRetryTests: XCTestCase {

    func testInvalidCommandIsReaskedThenAccepted() async {
        let sides = StubSideAI([.success("???"), .success("42"), .success("COMMAND: Talk to Orrin")])
        let engine = duel(StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration), StubNarrator.ok(AIFixtures.narration)]),
                          sides: sides, adventurer: claude)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(sides.requests.count, 3, "asked once, re-asked twice")
        XCTAssertTrue(sides.requests[1].messages.last?.content.contains("rejected") == true, "the error is fed back")
        XCTAssertEqual(engine.actionHistory, ["Talk to Orrin"])
        XCTAssertEqual(engine.adventurerFallbacks, 0)
        XCTAssertEqual(engine.lastAdventurerSource, .model("Anthropic Claude claude-sonnet-5-5"))
    }

    func testThreeInvalidCommandsFallBackAndCount() async {
        let sides = StubSideAI([.success("???"), .success("!!!"), .success("..."), .success("COMMAND: never asked")])
        let engine = duel(StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)]), sides: sides, adventurer: claude)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(sides.requests.count, 3, "re-asked at most 2 times")
        XCTAssertEqual(engine.actionHistory, ["Talk to Orrin"], "the heuristic played the turn")
        XCTAssertEqual(engine.adventurerFallbacks, 1)
        XCTAssertEqual(engine.lastAdventurerSource, .fallback)
    }

    func testInvalidNarrationIsReaskedThenScriptedNarratorAnswers() async {
        // narrator side: opening ok, then three unusable replies for the turn
        let sides = StubSideAI([.success(AIFixtures.narration), .success("ok"), .success("..."), .success("hm")])
        let engine = duel(StubNarrator(aiEnabled: true), sides: sides, narratorSide: gpt)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(sides.requests.count, 4, "opening + 1 ask + 2 re-asks")
        XCTAssertEqual(engine.lastNarrationSource, .fallback)
        XCTAssertEqual(engine.fallbackTurns, 1)
    }
}

final class ModelVsModelPerformanceTests: XCTestCase {

    @MainActor
    func testRecordingModelRepliesIsCheap() {
        let logger = PlayFixtures.logger(MemoryPlaySink())
        let engine = duel(StubNarrator(aiEnabled: false), sides: StubSideAI(), logger: logger)
        engine.spectatorDelay = 60
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<300 {
            engine.recordModelReply(side: "adventurer", backend: "ollama", model: "qwen3:8b",
                                    text: "COMMAND: Go north \(i)", latency: 0.2, valid: true, attempt: 1)
        }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 2.0)
    }
}

@MainActor
final class ModelVsModelIntegrationTests: XCTestCase {

    func testEachSideUsesItsOwnBackendAndEveryReplyIsRecorded() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let sides = StubSideAI([.success(AIFixtures.narration),        // narrator (gpt): opening
                                .success("COMMAND: Go north"),          // adventurer (claude)
                                .success(AIFixtures.narration)])        // narrator (gpt): the turn
        let narrator = StubNarrator(aiEnabled: true)                   // settings path: must not be used
        let engine = duel(narrator, sides: sides, logger: logger, adventurer: claude, narratorSide: gpt)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        _ = await logger.drainNow()
        XCTAssertEqual(narrator.calls, 0)
        XCTAssertEqual(sides.requests.map(\.side.backend), [.openAI, .anthropic, .openAI])
        XCTAssertEqual(engine.lastNarrationSource, .model("OpenAI (ChatGPT) gpt-5.1"))

        let s = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.watchPlayer })
        let summary = PlayFixtures.json(s.summaryJSON)
        let matchup = try XCTUnwrap((summary["matchup"] as? [String: Any])?["sides"] as? [[String: Any]])
        XCTAssertEqual(matchup.map { $0["backend"] as? String }, ["anthropic", "openai"])
        XCTAssertEqual(matchup.map { $0["model"] as? String }, ["claude-sonnet-5-5", "gpt-5.1"])

        let replies = (sink.events[s.id] ?? [:]).sorted { $0.key < $1.key }.map(\.value).filter { $0.kind == "model_reply" }
            .map { PlayFixtures.json($0.detailJSON) }
        XCTAssertEqual(replies.map { $0["side"] as? String }, ["narrator", "adventurer", "narrator"])
        XCTAssertEqual(replies.map { $0["valid"] as? Bool }, [true, true, true])
        XCTAssertEqual(replies[1]["backend"] as? String, "anthropic")
        XCTAssertEqual(replies[1]["latency_ms"] as? Int, 12)
        XCTAssertEqual(sink.eventKinds(s.id).filter { $0 == "turn" }.count, 1)
    }
}

@MainActor
final class ModelVsModelFunctionalTests: XCTestCase {

    func testOverridesNeedTheKitPath() async {
        // No sideAI (Nova API sessions): an override falls back to the AI Narrator settings.
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration), StubNarrator.ok("COMMAND: Go north"),
                                              StubNarrator.ok(AIFixtures.narration)])
        let engine = spectator(narrator, maxTurns: 1)
        engine.adventurerSide = claude
        engine.narratorSide = gpt
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertEqual(narrator.calls, 3)
        XCTAssertEqual(engine.actionHistory, ["Go north"])
    }

    func testAfterTakeOverTheNarratorReturnsToSettings() async {
        let sides = StubSideAI([.success(AIFixtures.narration)])        // narrator side: opening only
        let narrator = StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)])
        let engine = duel(narrator, sides: sides, maxTurns: 50, narratorSide: gpt)
        engine.spectatorDelay = 5
        engine.startSpectating()
        await waitUntil { engine.lastNarrationSource != nil }
        engine.takeOver()
        engine.performAction("Go north")
        await waitUntil { !engine.isLoading }
        XCTAssertEqual(sides.requests.count, 1, "the player's turn is not narrated by the watch side")
        XCTAssertEqual(narrator.calls, 1)
        XCTAssertEqual(engine.lastNarrationSource, .ai(.ollama))
    }

    func testAIOffIgnoresOverrides() async {
        let sides = StubSideAI([.success("COMMAND: Go north")])
        let engine = duel(StubNarrator(aiEnabled: false), sides: sides, maxTurns: 2, adventurer: claude, narratorSide: gpt)
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        XCTAssertTrue(sides.requests.isEmpty, "AI off: nothing is sent")
        XCTAssertEqual(engine.lastAdventurerSource, .scripted)
    }
}

@MainActor
final class ModelVsModelFrameTests: XCTestCase {

    func testSidesDefaultToSettingsAndAreNotPersistedByTests() {
        let engine = makeEngine(StubNarrator(aiEnabled: false))
        XCTAssertEqual(engine.adventurerSide, WatchSide())
        XCTAssertEqual(engine.narratorSide, WatchSide())
        let before = UserDefaults.standard.data(forKey: GameEngine.adventurerSideKey)
        engine.adventurerSide = claude
        XCTAssertEqual(UserDefaults.standard.data(forKey: GameEngine.adventurerSideKey), before)
    }

    func testMatchupLabelsAnOverriddenSide() {
        let engine = duel(StubNarrator(aiEnabled: true), sides: StubSideAI(), adventurer: claude)
        let sides = engine.watchMatchup()["sides"] as? [[String: Any]] ?? []
        XCTAssertEqual(sides.first?["label"] as? String, "Anthropic Claude claude-sonnet-5-5")
        XCTAssertEqual(sides.last?["kind"] as? String, "model")
        XCTAssertNotEqual(sides.last?["backend"] as? String, "anthropic", "the narrator stays on settings")
    }
}

// MARK: - id Software learnings (seeded RNG, one command type, personality as data, the record)

final class IdLearningsUnitTests: XCTestCase {

    func testSplitMix64IsDeterministicAndMatchesTheReference() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        XCTAssertEqual(a.next(), 13679457532755275413)
        XCTAssertEqual(a.next(), 2949826092126892291)
        _ = b.next(); _ = b.next()
        XCTAssertEqual(a.next(), b.next())
    }

    func testBundledPersonalitiesAndFallback() {
        XCTAssertEqual(AdventurerPersonality.all.map(\.id), ["balanced", "explorer", "collector", "chatterbox", "cautious"])
        XCTAssertEqual(AdventurerPersonality.named("nope"), .fallback)
        XCTAssertEqual(AdventurerPersonality.parse(nil), [.fallback])
        XCTAssertEqual(AdventurerPersonality.named("balanced").priorities, AdventurerPersonality.fallback.priorities)
    }

    func testPersonalityDrivesTheHeuristicAndThePrompt() {
        let actions = ["Look around", "Go north", "Talk to Pim", "Take the lamp"]
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [:], personality: .named("chatterbox")), "Talk to Pim")
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [:], personality: .named("explorer")), "Go north")
        XCTAssertEqual(Adventurer.pick(from: actions, tried: [:], personality: .named("cautious")), "Look around")
        let p = Adventurer.prompt(story: [], actions: actions, recent: [], personality: .named("collector"))
        XCTAssertTrue(p[0].content.contains("magpie"))
    }

    func testCategories() {
        XCTAssertEqual(["Take the key", "Ask Pim", "Climb up", "Examine door", "Dance"].map(Adventurer.category),
                       ["take", "talk", "move", "look", "other"])
    }
}

final class IdLearningsSecurityTests: XCTestCase {

    func testHostilePersonalityTableIsFiltered() {
        let json = """
        {"personalities": [
          {"id": "evil", "name": "x", "style": "\(String(repeating: "a", count: 400))", "priorities": ["take"], "temperature": 0.5},
          {"id": "odd", "name": "x", "style": "ok", "priorities": ["rm -rf"], "temperature": 0.5},
          {"id": "hot", "name": "x", "style": "ok", "priorities": ["take"], "temperature": 9},
          {"id": "fine", "name": "Fine", "style": "ok", "priorities": ["talk"], "temperature": 0.5}
        ]}
        """
        XCTAssertEqual(AdventurerPersonality.parse(Data(json.utf8)).map(\.id), ["balanced", "fine"])
        XCTAssertEqual(AdventurerPersonality.parse(Data("not json".utf8)), [.fallback])
    }

    func testOneValidatorForEveryDriver() {
        XCTAssertEqual(PlayerCommand.validate("Talk to Pim"), "Talk to Pim", "a suggested action passes unchanged")
        XCTAssertEqual(PlayerCommand.validate(String(repeating: "a", count: 500))?.count, 500, "the API limit")
        XCTAssertNil(PlayerCommand.validate("COMMAND: " + String(repeating: "a", count: 81),
                                            maxChars: NarrationValidator.maxActionChars), "models get the action limit")
        XCTAssertNil(PlayerCommand.validate("\u{0007}\u{202E}"))
    }

    @MainActor
    func testEmptyOrJunkCommandsNeverStartATurn() {
        let engine = makeEngine(StubNarrator(aiEnabled: false))
        engine.performAction("   ")
        engine.performAction("???")
        XCTAssertTrue(engine.actionHistory.isEmpty)
        XCTAssertFalse(engine.isLoading)
    }
}

@MainActor
final class IdLearningsFunctionalTests: XCTestCase {

    func testSameSeedSameRandomModelSwitches() {
        func run() -> [String] {
            let engine = makeEngine(StubNarrator(aiEnabled: false))
            engine.availableModels = ["a", "b", "c", "d", "e"]
            engine.selectedModel = "a"
            engine.startNewGame(seed: 7)
            engine.randomModelMode = true
            engine.actionsUntilModelSwitch = 1
            var picked: [String] = []
            for _ in 0..<6 { engine.performAction("Look around"); picked.append(engine.selectedModel) }
            engine.randomModelMode = false
            return picked
        }
        XCTAssertEqual(run(), run(), "gameplay randomness replays from the stored seed")
    }

    func testCosmeticRandomnessDoesNotMoveTheGameplayStream() {
        var a = SplitMix64(seed: 1), b = SplitMix64(seed: 1)
        _ = Double.random(in: 0...1)                      // cosmetic: system generator
        XCTAssertEqual(a.next(), b.next())
    }
}

@MainActor
final class IdLearningsIntegrationTests: XCTestCase {

    func testTheRecordCarriesSeedDriverPersonalityAndFallbacks() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        // AI on, but the adventurer never gets an answer: the heuristic plays and a fallback event is written
        let engine = spectator(StubNarrator(replies: [StubNarrator.ok(AIFixtures.narration)]), logger: logger, maxTurns: 1)
        engine.adventurerPersonality = "chatterbox"
        engine.startSpectating()
        defer { engine.stopSpectating(reason: nil) }
        await waitUntil { !engine.isSpectating }
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first { $0.player == PlayLogger.watchPlayer })
        let summary = PlayFixtures.json(s.summaryJSON)
        XCTAssertEqual(summary["seed"] as? String, String(engine.gameSeed))
        let sides = try XCTUnwrap((summary["matchup"] as? [String: Any])?["sides"] as? [[String: Any]])
        XCTAssertEqual(sides.first?["personality"] as? String, "chatterbox")
        let events = (sink.events[s.id] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        XCTAssertTrue(events.contains { $0.kind == "fallback" && PlayFixtures.json($0.detailJSON)["side"] as? String == "adventurer" })
        let turn = try XCTUnwrap(events.first { $0.kind == "turn" })
        XCTAssertEqual(PlayFixtures.json(turn.detailJSON)["driver"] as? String, "heuristic")
    }

    func testHumanTurnsAreTaggedHuman() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = makeEngine(StubNarrator(aiEnabled: false), logger: logger)
        engine.startNewGame()
        await settle(engine)
        await act(engine, "Go north")
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        let turn = try XCTUnwrap(sink.events[s.id]?.values.first { $0.kind == "turn" })
        XCTAssertEqual(PlayFixtures.json(turn.detailJSON)["driver"] as? String, "human")
    }
}
