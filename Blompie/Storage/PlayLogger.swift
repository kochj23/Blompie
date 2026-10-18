//
//  PlayLogger.swift
//  Blompie
//
//  Play-session logging to the Nova Games DB (schema `play`, contract: NovaGames deploy/db/play.sql), so Nova
//  can write about what was played. One session per sitting (new adventure or loaded save), one event per turn.
//
//  Never blocks or breaks a turn: every call only appends to a small in-memory queue under a lock; a background
//  task drains the queue to Postgres. If the DB is unreachable the queue waits and retries with backoff
//  (5 s, 10 s, 20 s ... 5 min). Rejected rows are dropped, never retried. Disabled under XCTest.
//
//  Created by Jordan Koch on 2026-10-18.
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation
import Security
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Rows

struct PlaySessionRow: Equatable, Sendable {
    let id: UUID
    let game: String
    let client: String
    let player: String
    var startedAt: Date
    var lastSeenAt: Date
    var endedAt: Date?
    var outcome: String?
    var score: Double?
    var actions: Int
    /// Compact JSON object, already capped by `PlayJSON`.
    var summaryJSON: String
}

struct PlayEventRow: Equatable, Sendable {
    let sessionID: UUID
    let seq: Int
    let ts: Date
    let kind: String
    let detailJSON: String
}

enum PlayOp: Equatable, Sendable {
    case session(PlaySessionRow)
    case event(PlayEventRow)

    var isEvent: Bool { if case .event = self { return true } else { return false } }
}

enum PlayLogError: Error, Equatable, CustomStringConvertible {
    /// No credentials / CA yet. Retried later (after setup) with backoff.
    case notConfigured(String)
    /// Network, TLS or server down. Retried with backoff.
    case unreachable(String)
    /// The DB rejected the row. Dropped, never retried.
    case invalid(String)

    var description: String {
        switch self {
        case .notConfigured(let s): return "not configured: \(s)"
        case .unreachable(let s): return "unreachable: \(s)"
        case .invalid(let s): return "invalid: \(s)"
        }
    }
}

/// Where rows go. Production: `PostgresPlaySink`. Tests: an in-memory fake.
protocol PlaySink: AnyObject, Sendable {
    func write(_ op: PlayOp) async throws
}

// MARK: - JSON (capped, control-character free)

enum PlayJSON {
    static let maxDetailBytes = 4096
    static let maxSummaryBytes = 65536
    /// Postgres prints jsonb with extra spaces (`": "`, `", "`), so keep a margin under the column CHECKs.
    static let budgetFactor = 0.8

    /// Control characters become spaces, runs of whitespace collapse, then cap at `max` characters.
    static func clean(_ s: String, max: Int) -> String {
        let scalars = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let collapsed = String(scalars).split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return String(collapsed.prefix(max))
    }

    static func cap(_ list: [String], count: Int, length: Int = 80) -> [String] {
        list.suffix(count).map { clean($0, max: length) }.filter { !$0.isEmpty }
    }

    /// Encode an object to compact JSON that fits `maxBytes` (after Postgres' reformatting). If it doesn't fit,
    /// the largest values are dropped one by one and `"truncated": true` is set. Anything not JSON-able gives `{}`.
    static func encode(_ object: [String: Any], maxBytes: Int) -> String {
        let budget = Int(Double(maxBytes) * budgetFactor)
        var obj = object
        while true {
            guard JSONSerialization.isValidJSONObject(obj),
                  let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return "{}" }
            if data.count <= budget { return String(decoding: data, as: UTF8.self) }
            let candidates = obj.keys.filter { $0 != "truncated" }
            guard let biggest = candidates.max(by: { size(obj[$0]) < size(obj[$1]) }) else { return "{}" }
            obj.removeValue(forKey: biggest)
            obj["truncated"] = true
        }
    }

    private static func size(_ v: Any?) -> Int {
        guard let v else { return 0 }
        if let d = try? JSONSerialization.data(withJSONObject: [v], options: []) { return d.count }
        return 0
    }
}

// MARK: - Logger

final class PlayLogger: ObservableObject, @unchecked Sendable {

    enum Status: Equatable {
        case disabled(String)
        case needsSetup(String)
        case pending(Int)
        case online

        var text: String {
            switch self {
            case .disabled(let why): return "Off (\(why))"
            case .needsSetup(let why): return "Not connected: \(why)"
            case .pending(let n): return n > 0 ? "Offline, \(n) row(s) waiting" : "Waiting to connect"
            case .online: return "Connected to the Games DB"
            }
        }
    }

    static let game = "blompie-mac"
    static let client = "mac"
    static let player = "default"
    static let maxQueue = 500

    /// The app's logger. Under XCTest it never has a sink (no DB writes from tests).
    static let shared: PlayLogger = makeDefault()

    static var isTestRun: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func makeDefault() -> PlayLogger {
        if isTestRun { return PlayLogger(sink: nil, disabledReason: "test run") }
        guard let ca = PlayDBCA.pem() else { return PlayLogger(sink: nil, disabledReason: "no games-pg CA in the app bundle") }
        let creds = KeychainPlayCredentials()
        return PlayLogger(sink: PostgresPlaySink(config: .defaults, credentials: creds, caPEM: ca), credentials: creds)
    }

    /// Backoff between drain attempts while the DB is down: 5 s, 10 s, 20 s ... capped at 5 min.
    static func backoff(failures: Int) -> TimeInterval {
        min(300, 5 * pow(2, Double(max(0, failures - 1))))
    }

    @Published private(set) var status: Status

    private let sink: PlaySink?
    private let credentials: KeychainPlayCredentials?
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var queue: [PlayOp] = []
    private var current: PlaySessionRow?
    private var nextSeq = 0
    private var draining = false
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var activated = false
    /// Drain in the background after every write (production). Tests turn it off and call `drainNow()`.
    private let autoDrain: Bool

    init(sink: PlaySink?, disabledReason: String = "no Games DB", credentials: KeychainPlayCredentials? = nil,
         autoDrain: Bool = true,
         sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.credentials = credentials
        self.autoDrain = autoDrain
        self.sleeper = sleeper
        self.now = now
        self.status = sink == nil ? .disabled(disabledReason) : .pending(0)
    }

    var isEnabled: Bool { sink != nil }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return queue.count }
    var pendingOps: [PlayOp] { lock.lock(); defer { lock.unlock() }; return queue }
    var currentSession: PlaySessionRow? { lock.lock(); defer { lock.unlock() }; return current }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }

    // MARK: Session API (cheap, synchronous, safe from any thread)

    /// Start a new session (ending the open one as `completed`) and log its `start` event.
    func beginSession(start: [String: Any], summary: [String: Any]) {
        guard isEnabled else { return }
        let t = now()
        lock.lock()
        closeLocked(outcome: "completed", summary: nil, at: t)
        let row = PlaySessionRow(id: UUID(), game: Self.game, client: Self.client, player: Self.player,
                                 startedAt: t, lastSeenAt: t, endedAt: nil, outcome: nil, score: nil, actions: 0,
                                 summaryJSON: PlayJSON.encode(summary, maxBytes: PlayJSON.maxSummaryBytes))
        current = row
        nextSeq = 0
        enqueueLocked(.session(row))
        appendEventLocked(kind: "start", detail: start, at: t)
        lock.unlock()
        requestDrain()
    }

    /// Log an event in the open session; `action` bumps the session's action count. Also refreshes
    /// `last_seen_at` and the running summary. No-op without an open session.
    func record(kind: String, detail: [String: Any], action: Bool, summary: [String: Any]?) {
        guard isEnabled else { return }
        let t = now()
        lock.lock()
        guard var row = current else { lock.unlock(); return }
        appendEventLocked(kind: kind, detail: detail, at: t)
        if action { row.actions = min(row.actions + 1, 10_000_000) }
        row.lastSeenAt = max(t, row.startedAt)
        if let summary { row.summaryJSON = PlayJSON.encode(summary, maxBytes: PlayJSON.maxSummaryBytes) }
        current = row
        enqueueLocked(.session(row))
        lock.unlock()
        requestDrain()
    }

    /// End the open session (`completed`, `quit`, ...). `summary` nil keeps the last one sent.
    func endSession(outcome: String, summary: [String: Any]? = nil) {
        guard isEnabled else { return }
        lock.lock()
        closeLocked(outcome: outcome, summary: summary, at: now())
        lock.unlock()
        requestDrain()
    }

    /// App quit: end the session as `quit` and give the queue up to `timeout` to drain. Best effort.
    func appWillTerminate(timeout: TimeInterval = 2) {
        guard isEnabled else { return }
        endSession(outcome: "quit")
        retryNow()
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func closeLocked(outcome: String, summary: [String: Any]?, at t: Date) {
        guard var row = current else { return }
        row.endedAt = max(t, row.startedAt)
        row.lastSeenAt = max(t, row.startedAt)
        row.outcome = PlayJSON.clean(outcome, max: 64)
        if let summary { row.summaryJSON = PlayJSON.encode(summary, maxBytes: PlayJSON.maxSummaryBytes) }
        current = nil
        enqueueLocked(.session(row))
    }

    private func appendEventLocked(kind: String, detail: [String: Any], at t: Date) {
        guard let row = current else { return }
        let ev = PlayEventRow(sessionID: row.id, seq: nextSeq, ts: t, kind: kind,
                              detailJSON: PlayJSON.encode(detail, maxBytes: PlayJSON.maxDetailBytes))
        nextSeq += 1
        enqueueLocked(.event(ev))
    }

    /// Session upserts coalesce (the newest row replaces a queued one in place, so it still precedes its events).
    /// Over `maxQueue`, the oldest events are dropped first; session rows are kept.
    private func enqueueLocked(_ op: PlayOp) {
        if case .session(let row) = op,
           let i = queue.firstIndex(where: { if case .session(let r) = $0 { return r.id == row.id } else { return false } }) {
            queue[i] = op
        } else {
            queue.append(op)
        }
        while queue.count > Self.maxQueue {
            if let i = queue.firstIndex(where: \.isEvent) { queue.remove(at: i) } else { queue.removeFirst() }
        }
    }

    // MARK: Draining

    /// Start a background drain unless one is running or a backoff wait is pending.
    func requestDrain() {
        guard sink != nil, autoDrain else { return }
        lock.lock()
        guard !draining, retryTask == nil, !queue.isEmpty else { lock.unlock(); return }
        draining = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in await drainLoop() }
    }

    /// Skip any backoff wait and drain now (after credentials were set up, or at quit).
    func retryNow() {
        lock.lock()
        retryTask?.cancel()
        retryTask = nil
        lock.unlock()
        requestDrain()
    }

    /// Drain until the queue is empty or a write fails. Returns true when everything reached the DB. For tests.
    @discardableResult
    func drainNow() async -> Bool {
        let busy: Bool = lock.withLock {
            retryTask?.cancel(); retryTask = nil
            let b = draining
            if !b { draining = true }
            return b
        }
        if busy {
            while true {
                let d = lock.withLock { draining }
                if !d { break }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return pendingCount == 0
        }
        await drainLoop()
        return pendingCount == 0
    }

    private func drainLoop() async {
        let error = await drainOnce()
        if let error {
            let pending: Int = lock.withLock {
                draining = false
                failures += 1
                let delay = Self.backoff(failures: failures), sleep = sleeper
                retryTask = Task.detached(priority: .utility) { [weak self] in
                    await sleep(delay)
                    guard !Task.isCancelled, let self else { return }
                    self.lock.withLock { self.retryTask = nil }
                    self.requestDrain()
                }
                return queue.count
            }
            if case .notConfigured(let why) = error { publish(.needsSetup(why)) } else { publish(.pending(pending)) }
        } else {
            let more: Bool = lock.withLock {
                draining = false
                failures = 0
                return !queue.isEmpty
            }
            publish(.online)
            if more { requestDrain() }
        }
    }

    private func drainOnce() async -> PlayLogError? {
        guard let sink else { return .notConfigured("no sink") }
        while true {
            guard let op = lock.withLock({ queue.first }) else { return nil }
            do {
                try await sink.write(op)
                removeIfFirst(op)
            } catch {
                let e = (error as? PlayLogError) ?? .unreachable(String(describing: type(of: error)))
                if case .invalid = e {
                    print("[PlayLogger] dropping a row the DB rejected: \(e)")
                    removeIfFirst(op)
                    continue
                }
                return e
            }
        }
    }

    /// Remove `op` if it is still at the head (a coalesced newer session row may have replaced it meanwhile).
    private func removeIfFirst(_ op: PlayOp) {
        lock.withLock { if queue.first == op { queue.removeFirst() } }
    }

    private func publish(_ s: Status) {
        DispatchQueue.main.async { if self.status != s { self.status = s } }
    }

    // MARK: App lifecycle + one-time setup

    /// Called once at launch (not in tests): end the session on quit, and fetch the DB password from core3
    /// over SSH (BatchMode, never prompts) if this Mac has none yet.
    func activate() {
        guard isEnabled else { return }
        lock.lock()
        guard !activated else { lock.unlock(); return }
        activated = true
        lock.unlock()
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.appWillTerminate()
        }
        #endif
        if credentials?.password() == nil { runSetup() }
    }

    /// Fetch the `blompie_mac` password from core3 into the Keychain, then drain. Off the main thread.
    func runSetup(completion: (@Sendable (String) -> Void)? = nil) {
        guard let credentials else { completion?("not available in this build"); return }
        Task.detached(priority: .utility) { [self] in
            do {
                try PlayDBSetup.fetchFromCore3(credentials: credentials)
                retryNow()
                completion?("Password stored in the Keychain")
            } catch {
                let msg = (error as? PlayLogError)?.description ?? "setup failed"
                publish(.needsSetup(msg))
                completion?(msg)
            }
        }
    }
}

// MARK: - DB configuration (non-secret)

struct PlayDBConfig: Equatable, Sendable {
    var host: String
    var port: Int
    /// Name the server certificate is verified against (verify-full); SANs: games-pg, nova-core3, localhost, IPs.
    var tlsServerName: String
    var database: String
    var user: String

    static let defaults = PlayDBConfig(host: "192.168.1.5", port: 5433, tlsServerName: "nova-core3",
                                       database: "games", user: "blompie_mac")

    func validate() throws {
        let hostOK = { (h: String) in
            !h.isEmpty && h.count <= 253 && h.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        }
        guard hostOK(host), hostOK(tlsServerName) else { throw PlayLogError.notConfigured("invalid host name") }
        guard (1...65535).contains(port) else { throw PlayLogError.notConfigured("invalid port") }
        guard database == "games", user == "blompie_mac" else { throw PlayLogError.notConfigured("invalid database/role") }
    }
}

enum PlayDBCA {
    /// The games-pg CA (public certificate) bundled with the app.
    static func pem(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "games-pg-ca", withExtension: "crt"),
              let d = try? Data(contentsOf: url), d.count < 64 * 1024,
              String(decoding: d, as: UTF8.self).contains("-----BEGIN CERTIFICATE-----") else { return nil }
        return d
    }
}

// MARK: - Credentials (Keychain only)

/// The `blompie_mac` password in Blompie's own Data Protection keychain (service `nova-games-pg`,
/// account `blompie_mac`), bound to the team-signed app. Never UserDefaults, files or logs.
struct KeychainPlayCredentials: Sendable {
    static let service = "nova-games-pg"
    static let account = "blompie_mac"
    let service: String
    let account: String

    init(service: String = KeychainPlayCredentials.service, account: String = KeychainPlayCredentials.account) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func password() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let pw = String(data: data, encoding: .utf8), !pw.isEmpty else { return nil }
        return pw
    }

    /// Store (or replace) the password. Errors carry the OSStatus, never the value.
    func store(_ password: String) throws {
        guard PlayDBSetup.isPlausiblePassword(password) else { throw PlayLogError.invalid("password format") }
        let data = Data(password.utf8)
        var st = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Blompie Games DB (\(account))"
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else {
            throw PlayLogError.notConfigured(st == errSecMissingEntitlement
                ? "this build has no keychain entitlement (unsigned build)" : "Keychain error \(st)")
        }
    }
}

/// One-time hand-off: `ssh -o BatchMode=yes kochj@192.168.1.5 sudo bash /srv/games/repo/deploy/remote.sh getpw blompie_mac`.
/// The password is read from stdout straight into the Keychain; nothing is printed, logged or put in argv.
enum PlayDBSetup {
    static let sshTarget = "kochj@192.168.1.5"
    static let remoteCommand = "sudo bash /srv/games/repo/deploy/remote.sh getpw blompie_mac"

    /// One line, printable ASCII, no spaces, 8...256 chars.
    static func isPlausiblePassword(_ s: String) -> Bool {
        (8...256).contains(s.count) && s.allSatisfy { $0.isASCII && !$0.isWhitespace && ($0.asciiValue ?? 0) >= 0x21 && $0 != "\u{7F}" }
    }

    static var sshArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", sshTarget, remoteCommand]
    }

    static func fetchFromCore3(credentials: KeychainPlayCredentials, timeout: TimeInterval = 20) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshArguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw PlayLogError.unreachable("ssh to core3 timed out") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0, data.count <= 1024 else {
            throw PlayLogError.notConfigured("ssh getpw failed (exit \(p.terminationStatus))")
        }
        let pw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausiblePassword(pw) else { throw PlayLogError.notConfigured("getpw returned no usable password") }
        try credentials.store(pw)
    }
}
