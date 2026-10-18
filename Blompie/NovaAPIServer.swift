//
//  NovaAPIServer.swift
//  Blompie
//
//  Nova/Claude API — port 37426
//
//  Adventure endpoints for AI agents (Nova, Herd, WOPR-style play):
//    GET  /api/status
//    GET  /api/ping
//    GET  /api/models                           — available Ollama models
//    POST /api/adventure/new                    — start a new adventure session
//    GET  /api/adventure/sessions               — list active sessions
//    GET  /api/adventure/:id/state              — current state (messages, inventory, actions)
//    POST /api/adventure/:id/action             — send a command, get the AI response
//    GET  /api/adventure/:id/history            — full message history
//    POST /api/adventure/:id/save               — save session to slot
//    GET  /api/adventure/:id/saves              — list save slots for session
//    POST /api/adventure/:id/undo               — undo last action
//    DELETE /api/adventure/:id                  — end/delete session
//
//  Action response is async — Ollama generates the reply.
//  Use polling on /state or /history to detect when the response arrives.
//
//  Security (2026-10): loopback only; every request needs
//    Authorization: Bearer <token>
//  where the token lives in the login Keychain (service "net.digitalnoise.blompie.api",
//  account "api-token"; created on first launch if missing). Read it with
//    security find-generic-password -s net.digitalnoise.blompie.api -a api-token -w
//  Browser requests are refused: any Origin header -> 403, Host must be 127.0.0.1/localhost
//  (DNS-rebinding guard), no CORS headers, no preflight. Requests are capped at 64 KB.
//
//  Created by Jordan Koch on 2026.
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation
import Network
import Security

/// Bearer token for the local API, kept in the login Keychain.
enum NovaAPIToken {
    static let service = "net.digitalnoise.blompie.api"
    static let account = "api-token"

    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let t = String(data: d, encoding: .utf8), t.count >= 32 else { return nil }
        return t
    }

    /// Existing token, or a new random 256-bit one saved to the Keychain. nil = Keychain unavailable (API stays off).
    static func loadOrCreate() -> String? {
        if let t = load() { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: account,
                                  kSecAttrLabel as String: "Blompie local API token",
                                  kSecValueData as String: Data(token.utf8)]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? token : nil
    }
}

/// Request gate for the local API. Pure, so it can be unit tested.
enum NovaAPIGate {
    static let maxRequestBytes = 65_536
    static let maxCommandChars = 500
    static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// nil = allowed, otherwise (status, message).
    static func check(method: String, headers: [String: String], token: String?, port: UInt16) -> (Int, String)? {
        if headers["origin"] != nil || headers["sec-fetch-site"] != nil {
            return (403, "browser requests are not allowed")
        }
        if method == "OPTIONS" { return (403, "no CORS") }
        guard allowedHosts.contains(hostname(headers["host"] ?? "")) else { return (403, "bad Host header") }
        guard let token, !token.isEmpty else { return (503, "API token unavailable (Keychain)") }
        let auth = headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), constantTimeEqual(String(auth.dropFirst(7)), token) else {
            return (401, "missing or bad bearer token")
        }
        return nil
    }

    /// "127.0.0.1:37426" -> "127.0.0.1", "[::1]:37426" -> "::1", "localhost" -> "localhost"
    static func hostname(_ host: String) -> String {
        let h = host.lowercased()
        if h.hasPrefix("[") { return String(h.dropFirst().prefix(while: { $0 != "]" })) }
        return h.split(separator: ":", maxSplits: 1).first.map(String.init) ?? h
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

@MainActor
class NovaAPIServer {
    static let shared = NovaAPIServer()
    let port: UInt16 = 37426
    private var listener: NWListener?
    private let startTime = Date()

    // Active adventure sessions keyed by UUID string
    // Each session has its own GameEngine instance
    private var sessions: [String: GameEngine] = [:]
    private var token: String?

    private init() {}

    func start() {
        token = NovaAPIToken.loadOrCreate()
        if token == nil { print("NovaAPI [Blompie]: no Keychain token; API disabled"); return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.handle(conn) } }
            listener?.stateUpdateHandler = { if case .ready = $0 { print("NovaAPI [Blompie]: port \(self.port)") } }
            listener?.start(queue: .main)
        } catch { print("NovaAPI [Blompie]: failed — \(error)") }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ c: NWConnection) { c.start(queue: .main); receive(c, Data()) }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, done, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var b = buf; if let d = data { b.append(d) }
                if b.count > NovaAPIGate.maxRequestBytes {
                    c.send(content: self.http(413, "request too large").data(using: .utf8),
                           completion: .contentProcessed { _ in c.cancel() })
                    return
                }
                if let req = NovaRequest(b) {
                    let resp = await self.route(req)
                    c.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
                } else if !done { self.receive(c, b) } else { c.cancel() }
            }
        }
    }

    // MARK: - Router

    private func route(_ req: NovaRequest) async -> String {
        if let (status, message) = NovaAPIGate.check(method: req.method, headers: req.headers, token: token, port: port) {
            return json(status, ["error": message] as [String: Any])
        }

        let parts = req.path.split(separator: "/").map(String.init)

        switch (req.method, req.path) {

        // ── Meta ──────────────────────────────────────────────────────────
        case ("GET", "/api/status"):
            return json(200, [
                "status": "running", "app": "Blompie", "version": "1.2",
                "port": "\(port)", "uptimeSeconds": Int(Date().timeIntervalSince(startTime)),
                "activeSessions": sessions.count
            ] as [String: Any])

        case ("GET", "/api/ping"):
            return json(200, ["pong": "true"] as [String: Any])

        // ── Models ─────────────────────────────────────────────────────────
        case ("GET", "/api/models"):
            // Ask Ollama directly for available models
            if let models = await fetchOllamaModels() {
                return json(200, ["models": models, "recommended": "qwen2.5:72b"] as [String: Any])
            }
            return json(200, ["models": [], "error": "Could not reach Ollama"] as [String: Any])

        // ── Session list ───────────────────────────────────────────────────
        case ("GET", "/api/adventure/sessions"):
            let list: [[String: Any]] = sessions.map { id, engine in [
                "sessionId": id,
                "model": engine.selectedModel,
                "messageCount": engine.messages.count,
                "inventory": engine.inventory,
                "isLoading": engine.isLoading
            ]}
            return jsonArray(200, list)

        // ── New adventure ──────────────────────────────────────────────────
        case ("POST", "/api/adventure/new"):
            let body = req.bodyJSON() ?? [:]
            let model      = body["model"]      as? String ?? "qwen2.5:72b"
            let toneStr    = body["tone"]        as? String ?? "balanced"
            let detailStr  = body["detail"]      as? String ?? "normal"

            let engine = GameEngine()
            engine.selectedModel = model

            engine.toneStyle = {
                switch toneStr.lowercased() {
                case "serious":  return .serious
                case "whimsical": return .whimsical
                default:         return .balanced
                }
            }()

            engine.detailLevel = {
                switch detailStr.lowercased() {
                case "brief":    return .brief
                case "detailed": return .detailed
                default:         return .normal
                }
            }()

            let sessionID = UUID().uuidString
            sessions[sessionID] = engine

            engine.startNewGame()

            // Brief wait for initial scene generation to begin
            try? await Task.sleep(nanoseconds: 200_000_000)

            return json(201, [
                "sessionId": sessionID,
                "model": model,
                "tone": toneStr,
                "detail": detailStr,
                "initialMessages": engine.messages.map { msgJSON($0) },
                "suggestedActions": engine.currentActions
            ] as [String: Any])

        default:
            break
        }

        // ── Session-specific routes: /api/adventure/:id/... ────────────────
        guard parts.count >= 3, parts[0] == "api", parts[1] == "adventure" else {
            return json(404, ["error": "Not found: \(req.method) \(req.path)"] as [String: Any])
        }

        let sessionID = parts[2]
        guard let engine = sessions[sessionID] else {
            return json(404, ["error": "Session not found: \(sessionID)"] as [String: Any])
        }

        let subpath = parts.count > 3 ? "/" + parts[3...].joined(separator: "/") : ""

        switch (req.method, subpath) {

        // GET state — call this to check if Ollama has responded yet
        case ("GET", "/state"), ("GET", ""):
            let lastMessages = engine.messages.suffix(10)
            return json(200, [
                "sessionId": sessionID,
                "model": engine.selectedModel,
                "isLoading": engine.isLoading,
                "messageCount": engine.messages.count,
                "recentMessages": lastMessages.map { msgJSON($0) },
                "suggestedActions": engine.currentActions,
                "inventory": engine.inventory,
                "locations": engine.locationHistory,
                "npcs": engine.metNPCs,
                "actionCount": engine.actionHistory.count
            ] as [String: Any])

        // GET full history
        case ("GET", "/history"):
            return json(200, [
                "sessionId": sessionID,
                "messages": engine.messages.map { msgJSON($0) },
                "actionHistory": engine.actionHistory,
                "inventory": engine.inventory,
                "locations": engine.locationHistory,
                "npcs": engine.metNPCs
            ] as [String: Any])

        // POST action — send a command to the adventure
        case ("POST", "/action"):
            guard let body = req.bodyJSON(),
                  let command = body["command"] as? String, !command.isEmpty,
                  command.count <= NovaAPIGate.maxCommandChars else {
                return json(400, ["error": "'command' string (1-\(NovaAPIGate.maxCommandChars) chars) required in body"] as [String: Any])
            }

            guard !engine.isLoading else {
                return json(429, ["error": "Adventure is still generating a response. Wait and retry."] as [String: Any])
            }

            let messageCountBefore = engine.messages.count
            engine.performAction(command)

            // Wait for Ollama to respond (poll up to 120s)
            let deadline = Date().addingTimeInterval(120)
            while engine.isLoading && Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let newMessages = Array(engine.messages.dropFirst(messageCountBefore))
            return json(200, [
                "sessionId": sessionID,
                "command": command,
                "response": newMessages.map { msgJSON($0) },
                "suggestedActions": engine.currentActions,
                "inventory": engine.inventory,
                "timedOut": engine.isLoading
            ] as [String: Any])

        // POST save
        case ("POST", "/save"):
            let slotName = req.bodyJSON()?["slotName"] as? String ?? "nova-\(sessionID.prefix(8))"
            engine.saveGame(toSlot: slotName)
            return json(200, ["saved": true, "slotName": slotName] as [String: Any])

        // GET saves
        case ("GET", "/saves"):
            let slots = engine.getSaveSlots().map { s in
                ["id": s.id, "name": s.name, "messageCount": s.messageCount,
                 "savedDate": ISO8601DateFormatter().string(from: s.savedDate)] as [String: Any]
            }
            return jsonArray(200, slots)

        // POST undo
        case ("POST", "/undo"):
            engine.undoLastAction()
            return json(200, [
                "undone": true,
                "messageCount": engine.messages.count,
                "recentMessages": engine.messages.suffix(5).map { msgJSON($0) }
            ] as [String: Any])

        // DELETE session
        case ("DELETE", ""):
            sessions.removeValue(forKey: sessionID)
            return json(200, ["deleted": true, "sessionId": sessionID] as [String: Any])

        default:
            return json(404, ["error": "Not found: \(req.method) \(req.path)"] as [String: Any])
        }
    }

    // MARK: - Helpers

    private func msgJSON(_ m: GameMessage) -> [String: Any] {
        ["id": m.id.uuidString, "text": m.text,
         "timestamp": ISO8601DateFormatter().string(from: m.timestamp)]
    }

    private func fetchOllamaModels() async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { $0["name"] as? String }
            }
        } catch {}
        return nil
    }

    // MARK: - HTTP helpers

    struct NovaRequest {
        let method: String; let path: String; let body: String; let headers: [String: String]
        func bodyJSON() -> [String: Any]? {
            guard let d = body.data(using: .utf8), !body.isEmpty else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        init?(_ data: Data) {
            guard let raw = String(data: data, encoding: .utf8), raw.contains("\r\n\r\n") else { return nil }
            let parts = raw.components(separatedBy: "\r\n\r\n")
            let lines = parts[0].components(separatedBy: "\r\n")
            guard let rl = lines.first else { return nil }
            let tokens = rl.components(separatedBy: " ")
            guard tokens.count >= 2 else { return nil }
            var hdrs: [String: String] = [:]
            for l in lines.dropFirst() {
                let kv = l.components(separatedBy: ": ")
                if kv.count >= 2 { hdrs[kv[0].lowercased()] = kv.dropFirst().joined(separator: ": ") }
            }
            let rawBody = parts.dropFirst().joined(separator: "\r\n\r\n")
            if let cl = hdrs["content-length"], let n = Int(cl), rawBody.utf8.count < n { return nil }
            method = tokens[0]
            path = tokens[1].components(separatedBy: "?").first ?? tokens[1]
            body = rawBody
            headers = hdrs
        }
    }

    private func json(_ s: Int, _ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
              let body = String(data: data, encoding: .utf8) else { return http(500, "") }
        return http(s, body, "application/json")
    }
    private func jsonArray(_ s: Int, _ a: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: a, options: .prettyPrinted),
              let body = String(data: data, encoding: .utf8) else { return http(500, "") }
        return http(s, body, "application/json")
    }
    private func http(_ s: Int, _ body: String, _ ct: String = "text/plain") -> String {
        let st = [200:"OK",201:"Created",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",
                  413:"Payload Too Large",429:"Too Many Requests",500:"Internal Server Error",503:"Service Unavailable"][s] ?? "Unknown"
        // No CORS headers on purpose: this API is for local agents, never for web pages.
        return "HTTP/1.1 \(s) \(st)\r\nContent-Type: \(ct); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
    }
}
