//
//  Retry.swift
//  Blompie (copied verbatim from GTNW Shared/Engine/Retry.swift, the canonical retry helper)
//
//  Small, reusable retry-with-exponential-backoff helper for every external call
//  (HTTP to Ollama / Gateway / OpenAI-compatible servers, the live-session bridge,
//  and Python/MLX subprocesses). External calls must never fail silently on the
//  first attempt: each failed attempt is logged and retried up to
//  `RetryPolicy.maxAttempts` times before the caller's fallback kicks in.
//
//  The sleep function and HTTP transport are injectable so tests run in
//  milliseconds with no network.
//
//  Created by Jordan Koch on 2026.
//

import Foundation

// MARK: - Policy

/// How many times to try, and how long to wait between tries.
struct RetryPolicy: Equatable, Sendable {
    /// Total attempts including the first one (clamped to >= 1).
    var maxAttempts: Int = 3
    /// Delay before the 2nd attempt.
    var baseDelay: TimeInterval = 0.5
    /// Exponential growth factor between attempts.
    var multiplier: Double = 2.0
    /// Upper bound on any single delay.
    var maxDelay: TimeInterval = 4.0

    /// Default for network calls: 3 attempts, 0.5s → 1s backoff.
    static let network = RetryPolicy()
    /// Default for local subprocesses (python/MLX): 2 attempts, 0.25s backoff.
    static let subprocess = RetryPolicy(maxAttempts: 2, baseDelay: 0.25)
    /// No retries (single attempt).
    static let none = RetryPolicy(maxAttempts: 1)

    /// Delay to wait *after* failed attempt `attempt` (1-based) before the next one.
    func delay(afterAttempt attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        let raw = max(0, baseDelay) * pow(max(1, multiplier), Double(n - 1))
        return min(raw, max(0, maxDelay))
    }

    /// Total time spent sleeping if every attempt fails.
    var worstCaseSleep: TimeInterval {
        let attempts = max(1, maxAttempts)
        guard attempts > 1 else { return 0 }
        return (1..<attempts).reduce(0) { $0 + delay(afterAttempt: $1) }
    }
}

// MARK: - Injectable seams

/// Sleeps for the given number of seconds (injectable for tests).
typealias RetrySleeper = @Sendable (TimeInterval) async -> Void

/// Performs one HTTP request (injectable for tests).
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum HTTP {
    /// The real transport: `URLSession.shared`.
    static let live: HTTPTransport = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Transient HTTP statuses worth retrying (rate-limit + server errors).
    static func isRetryableStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }
}

/// Thrown by `Retry` helpers to classify a non-2xx response.
struct HTTPStatusError: Error, Equatable {
    let statusCode: Int
    var isRetryable: Bool { HTTP.isRetryableStatus(statusCode) }
}

// MARK: - Retry

enum Retry {

    /// Real sleep; returns early (without throwing) if the task is cancelled.
    static let realSleep: RetrySleeper = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Run a throwing operation, retrying with backoff on failure.
    ///
    /// - Parameters:
    ///   - label: Shown in the log line for each failed attempt.
    ///   - shouldRetry: Return false for permanent errors (bad config, 4xx) to fail fast.
    /// - Returns: The first successful result.
    /// - Throws: The last error once attempts are exhausted, or a non-retryable error immediately.
    static func run<T>(
        _ label: String,
        policy: RetryPolicy = .network,
        sleep: RetrySleeper = Retry.realSleep,
        shouldRetry: (Error) -> Bool = { _ in true },
        operation: () async throws -> T
    ) async throws -> T {
        let attempts = max(1, policy.maxAttempts)
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let retryable = shouldRetry(error) && !(error is CancellationError)
                guard retryable, attempt < attempts, !Task.isCancelled else { break }
                let wait = policy.delay(afterAttempt: attempt)
                print("[Retry] \(label) attempt \(attempt)/\(attempts) failed: \(error). Retrying in \(String(format: "%.2f", wait))s")
                await sleep(wait)
                if Task.isCancelled { break }
            }
        }
        print("[Retry] \(label) failed after retries: \(lastError.map { "\($0)" } ?? "unknown error")")
        throw lastError ?? CancellationError()
    }

    /// Optional-returning variant: `nil` counts as a failed attempt.
    static func optional<T>(
        _ label: String,
        policy: RetryPolicy = .network,
        sleep: RetrySleeper = Retry.realSleep,
        operation: () async -> T?
    ) async -> T? {
        try? await run(label, policy: policy, sleep: sleep) {
            guard let value = await operation() else { throw RetryNilResult() }
            return value
        }
    }

    /// Perform an HTTP request with retry. Retries transport errors and transient
    /// statuses (408/429/5xx); returns immediately on 2xx or on permanent 4xx (thrown).
    static func http(
        _ request: URLRequest,
        label: String,
        transport: HTTPTransport = HTTP.live,
        policy: RetryPolicy = .network,
        sleep: RetrySleeper = Retry.realSleep
    ) async throws -> (Data, URLResponse) {
        try await run(label, policy: policy, sleep: sleep, shouldRetry: { error in
            if let status = error as? HTTPStatusError { return status.isRetryable }
            return true
        }) {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw HTTPStatusError(statusCode: http.statusCode)
            }
            return (data, response)
        }
    }
}

/// Internal marker used by `Retry.optional` when an attempt yields nil.
struct RetryNilResult: Error {}
