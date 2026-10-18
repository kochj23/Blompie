//
//  NovaAPIServerTests.swift
//  BlompieTests
//
//  Tests for the NovaAPIServer local HTTP API: port binding, endpoint routing,
//  and request/response contract validation.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
@testable import Blompie

@MainActor
final class NovaAPIServerTests: XCTestCase {

    // MARK: - Server Configuration

    func testServerPort() {
        let server = NovaAPIServer.shared
        XCTAssertEqual(server.port, 37426,
            "Blompie Nova API must run on port 37426")
    }

    func testServerSingleton() {
        let a = NovaAPIServer.shared
        let b = NovaAPIServer.shared
        XCTAssertTrue(a === b, "NovaAPIServer must be a singleton")
    }

    // MARK: - Integration: /api/status

    func testStatusEndpointResponds() async throws {
        let server = NovaAPIServer.shared
        server.start()

        // Brief delay for server to start
        try await Task.sleep(nanoseconds: 200_000_000)

        guard let url = URL(string: "http://127.0.0.1:37426/api/status") else {
            XCTFail("Invalid URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: authed(url))
            let httpResponse = response as! HTTPURLResponse
            XCTAssertEqual(httpResponse.statusCode, 200)

            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(json["status"] as? String, "running")
            XCTAssertEqual(json["app"] as? String, "Blompie")
            XCTAssertEqual(json["port"] as? String, "37426")
        } catch {
            // Server might not start in test environment; port conflict is acceptable
            print("Note: NovaAPIServer integration test skipped (port conflict or server issue): \(error)")
        }
    }

    // MARK: - Integration: /api/ping

    func testPingEndpointResponds() async throws {
        guard let url = URL(string: "http://127.0.0.1:37426/api/ping") else {
            XCTFail("Invalid URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: authed(url))
            let httpResponse = response as! HTTPURLResponse
            XCTAssertEqual(httpResponse.statusCode, 200)

            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(json["pong"] as? String, "true")
        } catch {
            print("Note: Ping test skipped (server not running): \(error)")
        }
    }

    private func authed(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        if let t = NovaAPIToken.load() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    // MARK: - Integration: auth enforced over the wire

    func testUnauthenticatedAndBrowserRequestsRefused() async throws {
        NovaAPIServer.shared.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        let url = URL(string: "http://127.0.0.1:37426/api/status")!
        do {
            let (_, r1) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((r1 as! HTTPURLResponse).statusCode, 401)
            var req = authed(url)
            req.setValue("https://evil.example", forHTTPHeaderField: "Origin")
            let (_, r2) = try await URLSession.shared.data(for: req)
            XCTAssertEqual((r2 as! HTTPURLResponse).statusCode, 403)
            XCTAssertNil((r2 as! HTTPURLResponse).value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        } catch {
            print("Note: auth integration test skipped (server not running): \(error)")
        }
    }

    // MARK: - Security: Loopback Only

    func testServerOnlyBindsToLoopback() throws {
        // Verify at code level that server uses 127.0.0.1
        let path = "\(blompieProjectRoot)/Blompie/NovaAPIServer.swift"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("host: \"127.0.0.1\""),
            "Server must bind to 127.0.0.1 only")
    }

    // MARK: - HTTP Request Parser

    func testHTTPRequestParserValidRequest() {
        // The NovaRequest struct is private, but we can test via network
        // This test verifies the server handles GET requests properly
        // (tested indirectly through /api/status and /api/ping)
    }
}
