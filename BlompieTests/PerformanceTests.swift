//
//  PerformanceTests.swift
//  BlompieTests
//
//  Performance tests: XCTest `measure` baselines plus hard wall-clock budgets
//  for the hot, pure paths — local API request gate, constant-time token
//  compare, Ollama tag parsing, pool assembly, and balancer selection.
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

final class PerformanceTests: XCTestCase {

    private func elapsed(_ block: () -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent(); block(); return CFAbsoluteTimeGetCurrent() - start
    }

    private let token = String(repeating: "ef", count: 32)

    func testGateCheckIsFast() {
        let h = ["host": "127.0.0.1:37426", "authorization": "Bearer \(token)"]
        let t = elapsed { for _ in 0..<10_000 { _ = NovaAPIGate.check(method: "GET", headers: h, token: token, port: 37426) } }
        XCTAssertLessThan(t, 1.0, "10k gate checks took \(t)s")
    }

    func testGateCheckMeasure() {
        let h = ["host": "localhost:37426", "authorization": "Bearer \(token)"]
        measure { for _ in 0..<2_000 { _ = NovaAPIGate.check(method: "POST", headers: h, token: token, port: 37426) } }
    }

    func testConstantTimeCompareCostIndependentOfMismatchPosition() {
        let early = "00" + String(token.dropFirst(2))
        let late = String(token.dropLast(2)) + "00"
        let n = 20_000
        let tEarly = elapsed { for _ in 0..<n { _ = NovaAPIGate.constantTimeEqual(early, token) } }
        let tLate = elapsed { for _ in 0..<n { _ = NovaAPIGate.constantTimeEqual(late, token) } }
        XCTAssertLessThan(max(tEarly, tLate), 2.0)
        // Generous ratio bound: no early-exit means both should be the same order of magnitude.
        XCTAssertLessThan(max(tEarly, tLate) / max(min(tEarly, tLate), 1e-6), 5.0)
    }

    func testParseLargeOllamaTagListIsFast() {
        let models = (0..<2_000).map { #"{"name":"model-\#($0):latest","size":\#($0)}"# }.joined(separator: ",")
        let data = Data(#"{"models":[\#(models)]}"#.utf8)
        var parsed: [DiscoveredModel] = []
        let t = elapsed { parsed = ModelRegistry.parseOllamaTags(data) }
        XCTAssertEqual(parsed.count, 2_000)
        XCTAssertLessThan(t, 1.0, "parsing 2k tags took \(t)s")
    }

    func testAssemblePoolDedupScalesLinearly() {
        let local = (0..<5_000).map { DiscoveredModel(modelName: "m\($0 % 2_500)", backend: .ollama, endpoint: "e") }
        var pool: [DiscoveredModel] = []
        let t = elapsed {
            pool = ModelRegistry.assemblePool(ollama: local, useAllLocalModels: true,
                                              enableAllFrontierModels: false, useNovaGateway: false)
        }
        XCTAssertEqual(pool.count, 2_500)
        XCTAssertLessThan(t, 1.0)
    }

    func testBalancerSelectionMeasure() {
        let pool = (0..<50).map { DiscoveredModel(modelName: "m\($0)", backend: .ollama, endpoint: "e") }
        let lb = LoadBalancer()
        measure {
            for _ in 0..<2_000 {
                if let m = lb.next(pool: pool, policy: .leastBusy) { lb.checkOut(m.id); lb.checkIn(m.id) }
            }
        }
    }

    func testRoundRobinThroughputBudget() {
        let pool = (0..<20).map { DiscoveredModel(modelName: "m\($0)", backend: .ollama, endpoint: "e") }
        let lb = LoadBalancer()
        let t = elapsed { for _ in 0..<50_000 { _ = lb.next(pool: pool, policy: .roundRobin) } }
        XCTAssertLessThan(t, 2.0, "50k round-robin picks took \(t)s")
    }

    func testOpenRouterModelParsingIsFast() {
        let items = (0..<3_000).map { #"{"id":"vendor/model-\#($0)"}"# }.joined(separator: ",")
        let data = Data(#"{"data":[\#(items)]}"#.utf8)
        var ids: [String] = []
        let t = elapsed { ids = OpenRouterProvider.parseModels(data) }
        XCTAssertEqual(ids.count, 3_000)
        XCTAssertLessThan(t, 1.0)
    }
}
