//
//  PlayLoggerTests.swift
//  BlompieTests
//
//  Play-history logging (Nova Games DB, schema `play`) in all 7 categories. Every test uses an in-memory sink;
//  nothing here touches the real Games DB (PlayLogger.shared has no sink under XCTest).
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

// MARK: - Fixtures

/// In-memory stand-in for Postgres: applies the same upsert / immutable-after-end / FK / idempotency rules.
final class MemoryPlaySink: PlaySink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sessions: [UUID: PlaySessionRow] = [:]
    private(set) var events: [UUID: [Int: PlayEventRow]] = [:]
    private(set) var writes = 0
    /// Errors to throw on the next writes, in order.
    var failures: [PlayLogError] = []

    func write(_ op: PlayOp) async throws {
        try lock.withLock { try apply(op) }
    }

    private func apply(_ op: PlayOp) throws {
        writes += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        switch op {
        case .session(let s):
            if let old = sessions[s.id] {
                guard old.endedAt == nil else { return }
                var n = s
                n.lastSeenAt = max(old.lastSeenAt, s.lastSeenAt)
                n.actions = max(old.actions, s.actions)
                sessions[s.id] = n
            } else { sessions[s.id] = s }
        case .event(let e):
            guard sessions[e.sessionID] != nil else { throw PlayLogError.invalid("23503") }
            if events[e.sessionID]?[e.seq] == nil { events[e.sessionID, default: [:]][e.seq] = e }
        }
    }

    func eventKinds(_ id: UUID) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (events[id] ?? [:]).sorted { $0.key < $1.key }.map(\.value.kind)
    }
    var allSessions: [PlaySessionRow] { lock.lock(); defer { lock.unlock() }; return Array(sessions.values) }
}

enum PlayFixtures {
    static func logger(_ sink: MemoryPlaySink = MemoryPlaySink(), slept: SleepLog? = nil, autoDrain: Bool = false) -> PlayLogger {
        PlayLogger(sink: sink, autoDrain: autoDrain, sleeper: { d in slept?.add(d) })
    }
    static func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

// MARK: - Unit

final class PlayLoggerUnitTests: XCTestCase {

    func testCleanStripsControlCharactersAndCaps() {
        XCTAssertEqual(PlayJSON.clean("a\u{0}b\nc\t\td", max: 100), "a b c d")
        XCTAssertEqual(PlayJSON.clean(String(repeating: "x", count: 500), max: 200).count, 200)
    }

    func testCapKeepsMostRecentItems() {
        let list = (1...100).map { "item \($0)" }
        let capped = PlayJSON.cap(list, count: 40)
        XCTAssertEqual(capped.count, 40)
        XCTAssertEqual(capped.last, "item 100")
    }

    func testEncodeIsCompactSortedJSON() {
        XCTAssertEqual(PlayJSON.encode(["b": 1, "a": "x/y"], maxBytes: 4096), #"{"a":"x/y","b":1}"#)
    }

    func testEncodeDropsLargestValueWhenOverBudget() {
        let big = String(repeating: "z", count: 5000)
        let out = PlayJSON.encode(["turn": 3, "narration": big], maxBytes: PlayJSON.maxDetailBytes)
        let obj = PlayFixtures.json(out)
        XCTAssertEqual(obj["turn"] as? Int, 3)
        XCTAssertNil(obj["narration"])
        XCTAssertEqual(obj["truncated"] as? Bool, true)
    }

    func testEncodeInvalidObjectGivesEmptyObject() {
        XCTAssertEqual(PlayJSON.encode(["date": Date()], maxBytes: 4096), "{}")
    }

    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(PlayLogger.backoff(failures: 1), 5)
        XCTAssertEqual(PlayLogger.backoff(failures: 2), 10)
        XCTAssertEqual(PlayLogger.backoff(failures: 3), 20)
        XCTAssertEqual(PlayLogger.backoff(failures: 20), 300)
    }

    func testPlausiblePassword() {
        XCTAssertTrue(PlayDBSetup.isPlausiblePassword(String(repeating: "a1", count: 24)))
        XCTAssertFalse(PlayDBSetup.isPlausiblePassword("short"))
        XCTAssertFalse(PlayDBSetup.isPlausiblePassword("has space in it ok"))
        XCTAssertFalse(PlayDBSetup.isPlausiblePassword("abcdefgh\n"))
    }

    func testSessionRowsUseContractIdentity() {
        let logger = PlayFixtures.logger()
        logger.beginSession(start: [:], summary: [:])
        let row = logger.currentSession
        XCTAssertEqual(row?.game, "blompie-mac")
        XCTAssertEqual(row?.client, "mac")
        XCTAssertEqual(row?.player, "default")
        XCTAssertEqual(row?.actions, 0)
        XCTAssertNil(row?.endedAt)
    }

    func testRecordWithoutSessionIsNoOp() {
        let logger = PlayFixtures.logger()
        logger.record(kind: "turn", detail: [:], action: true, summary: nil)
        XCTAssertEqual(logger.pendingCount, 0)
    }

    func testSessionUpsertsCoalesce() {
        let sink = MemoryPlaySink()
        sink.failures = Array(repeating: .unreachable("down"), count: 1)
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        for _ in 0..<5 { logger.record(kind: "turn", detail: [:], action: true, summary: nil) }
        let sessionOps = logger.pendingOps.filter { !$0.isEvent }
        XCTAssertLessThanOrEqual(sessionOps.count, 1, "one queued session row per session")
    }
}

// MARK: - Security

final class PlayLoggerSecurityTests: XCTestCase {

    func testSharedLoggerHasNoSinkUnderXCTest() {
        XCTAssertTrue(PlayLogger.isTestRun)
        XCTAssertFalse(PlayLogger.shared.isEnabled, "tests must never write to the real Games DB")
        PlayLogger.shared.beginSession(start: [:], summary: [:])
        XCTAssertEqual(PlayLogger.shared.pendingCount, 0)
    }

    func testConfigTargetsGamesDBRoleOnly() throws {
        let c = PlayDBConfig.defaults
        XCTAssertEqual(c.database, "games")
        XCTAssertEqual(c.user, "blompie_mac")
        XCTAssertEqual(c.port, 5433)
        XCTAssertNoThrow(try c.validate())
        var bad = c; bad.database = "nova_ops"
        XCTAssertThrowsError(try bad.validate())
        bad = c; bad.host = "evil;host"
        XCTAssertThrowsError(try bad.validate())
        bad = c; bad.user = "postgres"
        XCTAssertThrowsError(try bad.validate())
    }

    func testCredentialsUseDataProtectionKeychainService() {
        XCTAssertEqual(KeychainPlayCredentials.service, "nova-games-pg")
        XCTAssertEqual(KeychainPlayCredentials.account, "blompie_mac")
    }

    func testSSHHandOffNeverPromptsAndPassesNoSecret() {
        let args = PlayDBSetup.sshArguments
        XCTAssertEqual(Array(args.prefix(2)), ["-o", "BatchMode=yes"])
        XCTAssertEqual(args.last, "sudo bash /srv/games/repo/deploy/remote.sh getpw blompie_mac")
        XCTAssertFalse(args.joined(separator: " ").lowercased().contains("password="))
    }

    func testSourcesHaveNoHardcodedSecretsAndUseVerifyFull() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sink = try String(contentsOf: root.appendingPathComponent("Blompie/Storage/PostgresPlaySink.swift"), encoding: .utf8)
        let logger = try String(contentsOf: root.appendingPathComponent("Blompie/Storage/PlayLogger.swift"), encoding: .utf8)
        XCTAssertTrue(sink.contains(".fullVerification"))
        XCTAssertTrue(sink.contains(".require(context)"))
        XCTAssertTrue(sink.contains("logLevel = .critical"))
        XCTAssertFalse(sink.contains("unsafeSQL"), "all values must be bound parameters")
        XCTAssertTrue(logger.contains("kSecUseDataProtectionKeychain"))
        for src in [sink, logger] {
            XCTAssertNil(src.range(of: #"password\s*[:=]\s*"[^"]+""#, options: .regularExpression))
        }
    }

    func testCABundledAsPublicCertificateOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pem = try String(contentsOf: root.appendingPathComponent("Blompie/Storage/games-pg-ca.crt"), encoding: .utf8)
        XCTAssertTrue(pem.contains("BEGIN CERTIFICATE"))
        XCTAssertFalse(pem.contains("PRIVATE KEY"))
    }

    func testHostileTextIsSanitizedAndBounded() {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        let hostile = "'); DROP TABLE play.sessions; --\u{0}\u{1B}[31m" + String(repeating: "A", count: 10_000)
        logger.record(kind: "turn", detail: ["action": PlayJSON.clean(hostile, max: 200)], action: true, summary: nil)
        guard case .event(let e) = logger.pendingOps.last(where: \.isEvent) else { return XCTFail("no event") }
        XCTAssertLessThanOrEqual(e.detailJSON.utf8.count, PlayJSON.maxDetailBytes)
        XCTAssertFalse(e.detailJSON.contains("\\u0000"))
    }

    func testSinkMapsConstraintViolationsToInvalid() {
        XCTAssertEqual(PostgresPlaySink.map(PlayLogError.invalid("x")), .invalid("x"))
        if case .unreachable = PostgresPlaySink.map(URLError(.timedOut)) {} else { XCTFail("unknown errors are retryable") }
    }
}

// MARK: - Retry

final class PlayLoggerRetryTests: XCTestCase {

    func testOfflineKeepsQueueAndBacksOff() async {
        let sink = MemoryPlaySink()
        sink.failures = [.unreachable("down")]
        let slept = SleepLog()
        let logger = PlayFixtures.logger(sink, slept: slept)
        logger.beginSession(start: [:], summary: [:])
        let ok = await logger.drainNow()
        XCTAssertFalse(ok)
        XCTAssertEqual(logger.pendingCount, 2, "session + start event wait for the DB")
        XCTAssertEqual(logger.failureCount, 1)
    }

    func testRecoversAfterOutageWithoutDuplicates() async {
        let sink = MemoryPlaySink()
        sink.failures = [.unreachable("down"), .unreachable("down")]
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        logger.record(kind: "turn", detail: ["turn": 1], action: true, summary: nil)
        _ = await logger.drainNow()
        _ = await logger.drainNow()
        let ok = await logger.drainNow()
        XCTAssertTrue(ok)
        XCTAssertEqual(logger.pendingCount, 0)
        XCTAssertEqual(logger.failureCount, 0, "a successful drain resets the backoff")
        let id = sink.allSessions.first!.id
        XCTAssertEqual(sink.eventKinds(id), ["start", "turn"])
        XCTAssertEqual(sink.allSessions.first?.actions, 1)
    }

    func testBackgroundDrainRetriesAfterBackoff() async {
        let sink = MemoryPlaySink()
        sink.failures = [.unreachable("down")]
        let slept = SleepLog()
        let logger = PlayFixtures.logger(sink, slept: slept, autoDrain: true)
        logger.beginSession(start: [:], summary: [:])
        let deadline = Date().addingTimeInterval(5)
        while logger.pendingCount > 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(logger.pendingCount, 0, "the retry after the backoff wait delivers the rows")
        XCTAssertEqual(slept.all.first, 5, "first backoff is 5 s")
    }

    func testRejectedRowIsDroppedNotRetried() async {
        let sink = MemoryPlaySink()
        sink.failures = [.invalid("22001")]
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        let ok = await logger.drainNow()
        XCTAssertTrue(ok, "invalid rows are dropped so the queue never jams")
        XCTAssertEqual(logger.pendingCount, 0)
    }

    func testNotConfiguredWaitsForSetup() async {
        let sink = MemoryPlaySink()
        sink.failures = [.notConfigured("no password")]
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        _ = await logger.drainNow()
        XCTAssertEqual(logger.pendingCount, 2)
        let ok = await logger.drainNow()   // e.g. after the hand-off stored the password
        XCTAssertTrue(ok)
    }

    func testQueueIsBoundedAndKeepsSessionRows() {
        let sink = MemoryPlaySink()
        sink.failures = Array(repeating: .unreachable("down"), count: 10)
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        for i in 0..<(PlayLogger.maxQueue + 100) {
            logger.record(kind: "turn", detail: ["turn": i], action: true, summary: nil)
        }
        XCTAssertLessThanOrEqual(logger.pendingCount, PlayLogger.maxQueue)
        XCTAssertTrue(logger.pendingOps.contains { !$0.isEvent }, "session row survives overflow")
    }
}

// MARK: - Performance

final class PlayLoggerPerformanceTests: XCTestCase {

    func testRecordingATurnIsCheap() {
        let sink = MemoryPlaySink()
        sink.failures = Array(repeating: .unreachable("down"), count: 1_000)
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        let summary: [String: Any] = ["places": (1...40).map { "Place \($0)" }, "turns": 10]
        let start = Date()
        for i in 0..<300 {
            logger.record(kind: "turn", detail: ["turn": i, "action": "look", "narration": String(repeating: "n", count: 400)],
                          action: true, summary: summary)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "300 turns must log in well under a second")
    }

    func testEncodingLargeSummaryStaysBounded() {
        let summary: [String: Any] = ["moments": (1...200).map { ["turn": $0, "narration": String(repeating: "x", count: 400)] }]
        measure {
            let out = PlayJSON.encode(summary, maxBytes: PlayJSON.maxSummaryBytes)
            XCTAssertLessThanOrEqual(out.utf8.count, PlayJSON.maxSummaryBytes)
        }
    }
}

// MARK: - Integration (GameEngine + PlayLogger + in-memory DB)

@MainActor
final class PlayLoggerIntegrationTests: XCTestCase {

    func testLoadOfSlotStartsSessionAndTurnReachesDB() async throws {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = GameEngine(playLogger: logger)
        engine.beginPlaySession(from: "load", slot: "castle", start: ["slot": "castle", "resumed": true])
        engine.performAction("open the gate")
        engine.recordPlayNarration("You open the gate. A wizard waves.", failed: false)
        let ok = await logger.drainNow()
        XCTAssertTrue(ok)
        let s = try XCTUnwrap(sink.allSessions.first)
        XCTAssertEqual(sink.eventKinds(s.id), ["start", "turn"])
        XCTAssertEqual(s.actions, 1)
        let summary = PlayFixtures.json(s.summaryJSON)
        XCTAssertEqual(summary["turns"] as? Int, 1)
        XCTAssertEqual(summary["slot"] as? String, "castle")
        XCTAssertEqual(summary["started_from"] as? String, "load")
    }

    func testEngineWithoutLoggerLogsNothing() {
        let engine = GameEngine()
        XCTAssertNil(engine.playLogger)
        engine.recordPlayNarration("text", failed: false)
        XCTAssertEqual(engine.playTurn, 0)
    }

    func testNewSessionEndsPreviousAsCompleted() async {
        let sink = MemoryPlaySink()
        let logger = PlayFixtures.logger(sink)
        let engine = GameEngine(playLogger: logger)
        engine.beginPlaySession(from: "new", slot: "", start: [:])
        engine.beginPlaySession(from: "load", slot: "autosave", start: [:])
        _ = await logger.drainNow()
        let rows = sink.allSessions
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.outcome == "completed" && $0.endedAt != nil }.count, 1)
        XCTAssertEqual(rows.filter { $0.endedAt == nil }.count, 1)
    }
}

// MARK: - Functional

@MainActor
final class PlayLoggerFunctionalTests: XCTestCase {

    private func engine(_ sink: MemoryPlaySink) -> (GameEngine, PlayLogger) {
        let logger = PlayFixtures.logger(sink)
        return (GameEngine(playLogger: logger), logger)
    }

    func testTurnEventCarriesCappedActionAndNarration() async throws {
        let sink = MemoryPlaySink()
        let (engine, logger) = engine(sink)
        engine.beginPlaySession(from: "new", slot: "", start: ["setting": "new adventure"])
        engine.performAction(String(repeating: "a", count: 500))
        engine.recordPlayNarration(String(repeating: "b", count: 2000), failed: false)
        _ = await logger.drainNow()
        let id = try XCTUnwrap(sink.allSessions.first?.id)
        let turn = try XCTUnwrap(sink.events[id]?[1])
        XCTAssertEqual(turn.kind, "turn")
        let d = PlayFixtures.json(turn.detailJSON)
        XCTAssertEqual(d["turn"] as? Int, 1)
        XCTAssertEqual((d["action"] as? String)?.count, 200)
        XCTAssertEqual((d["narration"] as? String)?.count, 400)
    }

    func testOpeningNarrationIsASceneNotATurn() async throws {
        let sink = MemoryPlaySink()
        let (engine, logger) = engine(sink)
        engine.beginPlaySession(from: "new", slot: "", start: [:])
        engine.recordPlayNarration("You wake in a meadow.", failed: false)
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        XCTAssertEqual(sink.eventKinds(s.id), ["start", "scene"])
        XCTAssertEqual(s.actions, 0)
    }

    func testFailedNarrationStillCountsTheTurn() async throws {
        let sink = MemoryPlaySink()
        let (engine, logger) = engine(sink)
        engine.beginPlaySession(from: "new", slot: "", start: [:])
        engine.performAction("go north")
        engine.recordPlayNarration("", failed: true)
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        let d = PlayFixtures.json(try XCTUnwrap(sink.events[s.id]?[1]).detailJSON)
        XCTAssertEqual(d["failed"] as? Bool, true)
        XCTAssertEqual(s.actions, 1)
    }

    func testQuitEndsSessionAsQuitWithSummary() async throws {
        let sink = MemoryPlaySink()
        let (engine, logger) = engine(sink)
        engine.beginPlaySession(from: "new", slot: "", start: [:])
        engine.performAction("look")
        engine.recordPlayNarration("A quiet room.", failed: false)
        logger.endSession(outcome: "quit")
        _ = await logger.drainNow()
        let s = try XCTUnwrap(sink.allSessions.first)
        XCTAssertEqual(s.outcome, "quit")
        XCTAssertNotNil(s.endedAt)
        XCTAssertEqual(PlayFixtures.json(s.summaryJSON)["last_scene"] as? String, "A quiet room.")
        XCTAssertNil(logger.currentSession)
    }

    func testEndedSessionIsImmutable() async throws {
        let sink = MemoryPlaySink()
        let (engine, logger) = engine(sink)
        engine.beginPlaySession(from: "new", slot: "", start: [:])
        logger.endSession(outcome: "quit")
        _ = await logger.drainNow()
        logger.record(kind: "turn", detail: [:], action: true, summary: nil)
        XCTAssertEqual(logger.pendingCount, 0, "no open session after quit")
        XCTAssertEqual(sink.allSessions.first?.outcome, "quit")
    }

    func testSummaryListsAreCapped() {
        let (engine, _) = engine(MemoryPlaySink())
        engine.locationHistory = (1...100).map { "Place \($0)" }
        engine.inventory = (1...100).map { "Item \($0)" }
        engine.metNPCs = (1...100).map { "Npc\($0)" }
        let s = engine.playSummary()
        XCTAssertEqual((s["places"] as? [String])?.count, 40)
        XCTAssertEqual((s["items"] as? [String])?.count, 40)
        XCTAssertEqual((s["npcs"] as? [String])?.count, 40)
        XCTAssertEqual(s["places_count"] as? Int, 100)
    }
}

// MARK: - Frame

final class PlayLoggerFrameTests: XCTestCase {

    func testContractConstants() {
        XCTAssertEqual(PlayLogger.game, "blompie-mac")
        XCTAssertNotNil(PlayLogger.game.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression))
        XCTAssertEqual(PlayLogger.client, "mac")
        XCTAssertEqual(PlayLogger.player, "default")
        XCTAssertEqual(PlayJSON.maxDetailBytes, 4096)
        XCTAssertEqual(PlayJSON.maxSummaryBytes, 65536)
    }

    func testDefaultTLSAndHost() {
        XCTAssertEqual(PlayDBConfig.defaults.host, "192.168.1.5")
        XCTAssertEqual(PlayDBConfig.defaults.tlsServerName, "nova-core3")
    }

    func testDisabledLoggerReportsStatus() {
        let logger = PlayLogger(sink: nil, disabledReason: "test run")
        XCTAssertFalse(logger.isEnabled)
        XCTAssertEqual(logger.status, .disabled("test run"))
        XCTAssertTrue(logger.status.text.contains("test run"))
    }

    func testSeqStartsAtZeroAndIncrements() {
        let sink = MemoryPlaySink()
        sink.failures = Array(repeating: .unreachable("down"), count: 100)
        let logger = PlayFixtures.logger(sink)
        logger.beginSession(start: [:], summary: [:])
        logger.record(kind: "turn", detail: [:], action: true, summary: nil)
        logger.record(kind: "turn", detail: [:], action: true, summary: nil)
        let seqs = logger.pendingOps.compactMap { op -> Int? in if case .event(let e) = op { return e.seq } else { return nil } }
        XCTAssertEqual(seqs.suffix(3), [0, 1, 2])
    }
}
