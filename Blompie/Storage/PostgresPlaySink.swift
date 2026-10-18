//
//  PostgresPlaySink.swift
//  Blompie
//
//  Writes play rows to the Nova Games Postgres (database `games`, schema `play`, LAN role `blompie_mac`).
//  SCRAM auth, TLS 1.2+ with the games-pg CA pinned and the server name verified (verify-full). Every value is a
//  bound parameter; the only SQL text is the two fixed statements below. Modeled on GTNW's PostgresGameStore.
//
//  Created by Jordan Koch on 2026-10-18.
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation
import PostgresNIO

actor PostgresPlaySink: PlaySink {
    let config: PlayDBConfig
    private let credentials: KeychainPlayCredentials
    private let caPEM: Data
    private var connection: PostgresConnection?
    private var nextConnectionID = 1
    private let logger: Logger = {
        var l = Logger(label: "blompie.playlog")
        l.logLevel = .critical   // never log queries or bound values
        return l
    }()

    init(config: PlayDBConfig, credentials: KeychainPlayCredentials, caPEM: Data) {
        self.config = config
        self.credentials = credentials
        self.caPEM = caPEM
    }

    deinit {
        let c = connection
        Task { try? await c?.close() }
    }

    // MARK: Writes

    func write(_ op: PlayOp) async throws {
        try await withConnection { conn in
            switch op {
            case .session(let s):
                try await conn.query("""
                    INSERT INTO play.sessions (id, game, client, player, started_at, last_seen_at, ended_at, outcome, score, actions, summary)
                    VALUES (\(s.id), \(s.game), \(s.client), \(s.player), \(s.startedAt), \(s.lastSeenAt), \(s.endedAt),
                            \(s.outcome), \(s.score), \(s.actions), \(s.summaryJSON)::jsonb)
                    ON CONFLICT (id) DO UPDATE SET
                        last_seen_at = GREATEST(play.sessions.last_seen_at, EXCLUDED.last_seen_at),
                        actions = GREATEST(play.sessions.actions, EXCLUDED.actions),
                        ended_at = EXCLUDED.ended_at, outcome = EXCLUDED.outcome,
                        score = EXCLUDED.score, summary = EXCLUDED.summary
                    WHERE play.sessions.ended_at IS NULL
                    """, logger: self.logger)
            case .event(let e):
                try await conn.query("""
                    INSERT INTO play.events (session_id, seq, ts, kind, detail)
                    VALUES (\(e.sessionID), \(e.seq), \(e.ts), \(e.kind), \(e.detailJSON)::jsonb)
                    ON CONFLICT (session_id, seq) DO NOTHING
                    """, logger: self.logger)
            }
        }
    }

    // MARK: Connection

    private func makeConfiguration() throws -> PostgresConnection.Configuration {
        try config.validate()
        guard let password = credentials.password() else {
            throw PlayLogError.notConfigured("no DB password in the Keychain yet")
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .fullVerification
        do {
            tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(caPEM)))
        } catch {
            throw PlayLogError.notConfigured("games-pg CA certificate is not valid PEM")
        }
        let context: NIOSSLContext
        do { context = try NIOSSLContext(configuration: tls) } catch { throw PlayLogError.notConfigured("TLS setup failed") }
        var pg = PostgresConnection.Configuration(host: config.host, port: config.port, username: config.user,
                                                  password: password, database: config.database, tls: .require(context))
        pg.options.tlsServerName = config.tlsServerName
        pg.options.connectTimeout = .seconds(5)
        return pg
    }

    /// Run `body` on a live connection. Any non-data failure drops the connection so the next call reconnects.
    private func withConnection(_ body: (PostgresConnection) async throws -> Void) async throws {
        do {
            let conn: PostgresConnection
            if let c = connection, !c.isClosed { conn = c } else {
                let pg = try makeConfiguration()
                nextConnectionID += 1
                conn = try await PostgresConnection.connect(configuration: pg, id: nextConnectionID, logger: logger)
                connection = conn
            }
            try await body(conn)
        } catch {
            let mapped = Self.map(error)
            if case .invalid = mapped {} else {
                let c = connection
                connection = nil
                try? await c?.close()
            }
            throw mapped
        }
    }

    // MARK: Error mapping (never includes passwords, queries or bound values)

    static func map(_ error: Error) -> PlayLogError {
        if let e = error as? PlayLogError { return e }
        if let p = error as? PSQLError {
            if p.code == .server {
                let state = p.serverInfo?[.sqlState] ?? ""
                // 22 data, 23 constraint (incl. FK when a session row was dropped), 42501 RLS / privilege.
                if state.hasPrefix("22") || state.hasPrefix("23") || state == "42501" {
                    return .invalid("rejected by the database (\(state))")
                }
                if state.hasPrefix("28") { return .notConfigured("authentication failed (\(state))") }
                return .unreachable("server error \(state)")
            }
            if p.code == .saslError || p.code == .unsupportedAuthMechanism { return .notConfigured("authentication failed") }
            return .unreachable("\(p.code)")
        }
        return .unreachable(String(describing: type(of: error)))
    }
}
