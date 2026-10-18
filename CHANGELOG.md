# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Performance improvements
- Additional features based on community feedback

## [1.1.1] (build 4) - 2026-10-17

### Security
- Local Nova API on 127.0.0.1:37426 now requires `Authorization: Bearer <token>` on every route. The token is generated on first launch and stored in the macOS Keychain (service `net.digitalnoise.blompie.api`, account `api-token`). Browser requests (`Origin` / `Sec-Fetch-Site` headers, `OPTIONS` preflight) are refused with 403, the `Host` header must be loopback (DNS-rebinding defense), the token is compared in constant time, and request size (64 KB) and command length (500 chars) are capped. Wildcard CORS removed (commit 5264733).

### Fixed
- All 14 deprecated `onChange(of:perform:)` warnings in `ContentView` and `Design/ModernDesign` migrated to the two-parameter `onChange(of:) { oldValue, newValue in }` form.
- Unused-variable warnings in `BlompieComprehensiveTests.swift`.
- Settings About and `GET /api/status` reported hardcoded versions ("v1.3.0" and "1.2"); both now read `CFBundleShortVersionString` (About also shows the build number) from the bundle.

### Changed
- Extracted the balancer failover loop into `LoadBalancer.firstSuccess` (tries each healthy model once, drops failures, rethrows the last error only when all fail). Behavior is unchanged; the logic is now unit-testable.
- README rewritten: full feature list, Mermaid architecture and data-flow diagrams, Nova API reference with Keychain token usage, security, build and test instructions.

### Added
- `PerformanceTests`: gate throughput, constant-time compare, tag/model parsing, pool de-dup and balancer selection, using `XCTest measure` with time budgets.
- `RetryTests`: `LoadBalancer.firstSuccess` failover, in-flight bookkeeping, round-robin fairness after failover, re-authentication on retry after 429.

### Tests
- Wired `BlompieComprehensiveTests.swift` into the test target (it was never compiled) and removed its tests for EthicalAIGuardian types that are not part of the app target.
- Test suite grows from 174 to 271 tests across all 7 categories (Security, Performance, Retry, Unit, Integration, Functional, Frame), all passing.

## [1.0.0] - 2025-01-01

### Added
- Initial release
- Core functionality
- macOS native interface
- MIT License

---

*For detailed release notes, see [GitHub Releases](https://github.com/kochj23/Blompie/releases).*
