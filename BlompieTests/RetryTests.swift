//
//  RetryTests.swift
//  BlompieTests
//
//  Retry / failover tests: the balancer's `firstSuccess` dispatch loop (drop a
//  failing model, retry the next healthy one, rethrow only when all fail),
//  in-flight bookkeeping across failed attempts, and round-robin fairness
//  after a failover.
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

private struct InjectedFailure: Error, Equatable { let model: String }

final class RetryTests: XCTestCase {

    private func pool(_ names: [String]) -> [DiscoveredModel] {
        names.map { DiscoveredModel(modelName: $0, backend: .ollama, endpoint: "http://localhost:11434/api/chat") }
    }

    func testFirstAttemptSuccessDoesNotRetry() async throws {
        let lb = LoadBalancer()
        var tried: [String] = []
        let result = try await lb.firstSuccess(pool: pool(["a", "b", "c"]), policy: .roundRobin) { m -> String in
            tried.append(m.modelName); return "ok-\(m.modelName)"
        }
        XCTAssertEqual(result, "ok-a")
        XCTAssertEqual(tried, ["a"])
    }

    func testFailingModelIsDroppedAndNextIsTried() async throws {
        let lb = LoadBalancer()
        var tried: [String] = []
        let result = try await lb.firstSuccess(pool: pool(["a", "b", "c"]), policy: .leastBusy) { m -> String in
            tried.append(m.modelName)
            if m.modelName != "c" { throw InjectedFailure(model: m.modelName) }
            return "ok-c"
        }
        XCTAssertEqual(result, "ok-c")
        XCTAssertEqual(tried, ["a", "b", "c"], "each model tried exactly once, in order")
    }

    func testAllFailRethrowsLastError() async {
        let lb = LoadBalancer()
        var attempts = 0
        do {
            _ = try await lb.firstSuccess(pool: pool(["a", "b"]), policy: .leastBusy) { m -> String in
                attempts += 1; throw InjectedFailure(model: m.modelName)
            }
            XCTFail("expected rethrow")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, InjectedFailure(model: "b"))
        }
        XCTAssertEqual(attempts, 2, "bounded: no model retried twice")
    }

    func testUnhealthyModelsAreNeverAttempted() async throws {
        let lb = LoadBalancer()
        let p = pool(["a", "b", "c"])
        var tried: [String] = []
        let health = [p[0].id: false, p[1].id: false]
        let result = try await lb.firstSuccess(pool: p, health: health, policy: .roundRobin) { m -> String in
            tried.append(m.modelName); return m.modelName
        }
        XCTAssertEqual(result, "c")
        XCTAssertEqual(tried, ["c"])
    }

    func testNoHealthyModelReturnsNilWithoutAttempting() async throws {
        let lb = LoadBalancer()
        let p = pool(["a"])
        var attempts = 0
        let result = try await lb.firstSuccess(pool: p, health: [p[0].id: false], policy: .leastBusy) { _ -> String in
            attempts += 1; return "x"
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts, 0)
        let empty: String? = try await lb.firstSuccess(pool: [], policy: .roundRobin) { _ in "x" }
        XCTAssertNil(empty)
    }

    func testInFlightCountsReturnToZeroAfterFailures() async throws {
        let lb = LoadBalancer()
        _ = try? await lb.firstSuccess(pool: pool(["a", "b"]), policy: .leastBusy) { m -> String in
            throw InjectedFailure(model: m.modelName)
        }
        XCTAssertTrue(lb.inFlight.values.allSatisfy { $0 == 0 }, "failed attempts must be checked back in")
        _ = try await lb.firstSuccess(pool: pool(["a"]), policy: .leastBusy) { _ in "ok" }
        XCTAssertTrue(lb.inFlight.values.allSatisfy { $0 == 0 })
    }

    func testModelIsCheckedOutDuringAttempt() async throws {
        let lb = LoadBalancer()
        let p = pool(["a"])
        _ = try await lb.firstSuccess(pool: p, policy: .leastBusy) { m -> Int in
            XCTAssertEqual(lb.inFlight[m.id], 1)
            return 1
        }
        XCTAssertEqual(lb.inFlight[p[0].id], 0)
    }

    func testRoundRobinContinuesFairlyAfterFailover() async throws {
        let lb = LoadBalancer()
        let p = pool(["a", "b", "c"])
        var first: [String] = []
        // First call: "a" fails, "b" succeeds.
        _ = try await lb.firstSuccess(pool: p, policy: .roundRobin) { m -> String in
            first.append(m.modelName)
            if m.modelName == "a" { throw InjectedFailure(model: "a") }
            return m.modelName
        }
        XCTAssertEqual(first.count, 2)
        // Subsequent independent calls keep cycling the full pool (a failure is not permanent).
        var seen = Set<String>()
        for _ in 0..<3 {
            if let r = try await lb.firstSuccess(pool: p, policy: .roundRobin, attempt: { m in m.modelName }) { seen.insert(r) }
        }
        XCTAssertEqual(seen, ["a", "b", "c"])
    }

    func testBusyGatePreconditionStillAuthenticates() {
        // A client retrying after a 429 "still generating" must still pass the gate
        // on every attempt with the same token (no one-shot tokens).
        let token = String(repeating: "cd", count: 32)
        let h = ["host": "127.0.0.1:37426", "authorization": "Bearer \(token)"]
        for _ in 0..<5 { XCTAssertNil(NovaAPIGate.check(method: "POST", headers: h, token: token, port: 37426)) }
    }
}
