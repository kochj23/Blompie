# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Performance improvements
- Additional features based on community feedback

## [1.4.0] (build 8) - 2026-11-12

Watch contract v2: AI-vs-AI watch games are recorded and journaled.

### Changed
- A Watch AI Play game is recorded as its own play session: `player` `AI vs AI` (never a human), `summary.spectator = true`, `summary.matchup` (adventurer and narrator sides: backend, model, label, or `engine` for the built-in AI) and `summary.fallbacks` (`adventurer`, `narrator`). Outcomes: `completed`, `turn_limit`, `stalled`, `taken_over`. This replaces 1.3.0's "never record".
- Take Over ends the watch session as `taken_over` and starts a normal session (`started_from` `takeover`). After a watch that stopped on its own, the next action starts a normal session (`after_watch`).
- `PlayLogger.beginSession` takes a `player`.
- Tests: the "nothing recorded" test is replaced by watch-recording tests (385 total).

## [1.3.0] (build 7) - 2026-11-12

Watch AI Play: a spectator mode where an AI adventurer plays the game on its own.

### Added
- **Watch AI Play** (toolbar): starts a new adventure; an AI adventurer chooses each command through the same `AIBackendManager` as the narrator. When AI is off, a call fails, the reply is unusable or it repeats itself, a heuristic picks the suggested action least tried in the current scene, so it never stalls. Commands are validated like player input (`Adventurer.validate`).
- SPECTATING bar: indicator, turn count, who chose the last command, delay slider (0.5-10 s, default 3 s), Pause/Resume, Take Over. Picking any suggested action also takes over.
- Stops on its own when the story ends (`THE END` / game over), after 60 adventurer turns, or on a command loop (last 8 commands with at most 2 distinct).
- Tests: `Spectator*Tests` in all 7 categories (`AIParityTests.swift`).

### Changed
- A spectator story is never written to the Nova Games play history (no sessions or events, so no Nova review), including after a take-over, until the next New Game or Load. Starting one closes the player's open session as `completed`. Spectating also skips the autosave and achievements.
- `performAction` / `startNewGame` set `isLoading` immediately, so a second click cannot start a turn while one is pending.

## [1.2.0] (build 6) - 2026-11-11

AI parity with the other games: the AI is optional, every backend is configurable, and a failed AI call never loses a turn.

### Added
- Global **Use AI narrator** toggle (Settings > AI Narrator). Off: the scripted narrator runs the game and Blompie makes no AI network calls.
- Scripted fallback (`ScriptedNarrator`, `Blompie/Narration.swift`): a small deterministic rule-based world (7 places, items, 3 characters) that keeps the game fully playable when the AI is off or unreachable. Mid-story outages show a short "narrator away" line and keep the current actions. Scripted text is never fed back to the model.
- Backend picker over the canonical ids `auto, ollama, mlx, tinyllm, tinychat, openwebui, novagateway, openrouter, openai`, with a per-backend model picker and editable endpoint URLs. TinyLLM, TinyChat, OpenWebUI, Nova Gateway and OpenAI now drive the story path (they were probed but unused, or threw).
- Auto mode: reachable backends tried in a fixed order (Ollama, MLX, TinyChat, TinyLLM, OpenWebUI, Nova Gateway, OpenRouter, OpenAI); availability re-probed after 30 s; failed backends marked unreachable.
- Timeouts (local 180 s, cloud 60 s, probes 3 s) and bounded retries (2 attempts, 408/429/5xx/transport only) via `Retry.http` (copied from GTNW `Retry.swift`, injectable transport).
- `NarrationValidator`: strips `<think>` blocks, chat-template tokens and control/bidi characters, rejects empty or prompt-echo replies (next backend or scripted narrator answers), clips narration at 6,000 chars; suggested actions trimmed, de-duplicated, max 80 chars and 6 items.
- Narrator status badge in the toolbar (backend + online/away/AI off, and who narrated the last turn); per-backend status rows and **Test connection** in Settings; `GET /api/status` reports `ai.enabled/backend/active/online`; the widget shows the active backend or "Scripted".
- OpenAI key field (Keychain service `com.jordankoch.Blompie`).
- Play history: `turn`/`scene` events carry `source` (`llm`, `fallback`, `scripted`), the `start` event `ai_enabled`, and the summary a `fallbacks` count. A fallback turn is a completed turn (no `failed` flag).

### Changed
- The story path and the Nova API model list use the configured Ollama URL (was hardcoded `localhost:11434`). `OllamaService` takes a base URL.
- Single request path for every backend (`AIBackendManager.send`); the balancer reuses it, so retries, timeouts, https-only keys and validation are identical. Balancer failure falls through to the selected backend / Auto chain, then to the scripted narrator.
- OpenRouter key moved to Blompie's own Keychain service `com.jordankoch.Blompie.openrouter`; the AIStudio-shared item `com.jkoch.aistudio.openrouter` is read once, copied, and left untouched. OpenRouter attribution is now `HTTP-Referer: https://github.com/kochj23/Blompie`, `X-Title: Blompie`.
- Persisted backend values from 1.1.x (display names such as `MLX Toolkit`) migrate to the lowercase ids; removed cloud backends become `auto`.
- Clearing a key field deletes the Keychain item instead of storing an empty string. Legacy cloud keys left in `UserDefaults` are moved (OpenAI) or deleted (removed backends).
- A narration that lands after a turn was already recorded no longer creates a stray `scene` play event (scene = opening narration only).

### Security
- Requests carrying an API key are refused unless the URL is https; local backends never receive a key.
- Under XCTest the shared AI manager uses its own defaults suite and Keychain service, never migrates the legacy key and never probes, so tests cannot touch real settings or secrets.

### Removed
- Google Cloud, Microsoft Azure, AWS and IBM Watson backends (they always threw and never worked; OpenRouter covers frontier models).
- Dead code: the never-compiled `EthicalAIGuardian.swift`, `AIBackendManager+Enhanced.swift`, `AIBackendManager+EthicalGuardian.swift`, `AIBackendStatusMenu.swift`; the unused `AIBackendSelectionView`; the compiled-but-unused `Blompie/AICapabilities/*` (which read `OPENAI_API_KEY` from the environment); the duplicate per-backend request code in `+Balancer`; `AIError` (folded into `LLMError`).
- ComfyUI image generation (detected but never implemented).

### Tests
- `AIParityTests.swift`: 50 tests in all 7 categories (Unit 10, Security 10, Retry 8, Performance 5, Integration 4, Functional 8, Frame 5), no network (stub transport, stub narrator).
- Tests of removed types rewritten against their replacements: backend enum/error tests use `LLMBackendType`/`LLMError` (incl. legacy-value migration); source-reading Keychain tests are now behavioural round-trip/migration tests; `EthicalAIGuardianSourceTests` became `AIOutputValidationSecurityTests`; AICapabilities/AttackType tests replaced by narration-source and scripted-narrator tests; `testDefaultActiveBackend` now asserts a real default.
- Suite: 360 tests, all passing.

## [1.1.2] (build 5) - 2026-10-18

### Added
- Play history in the Nova Games DB (schema `play`, role `blompie_mac`): a session per sitting (new adventure or loaded save; the previous one ends `completed`, app quit ends it `quit`), a `start` event, a `scene` event for the opening narration and a `turn` event per action (action <= 200 chars, narrator excerpt <= 400 chars, achievements unlocked). `last_seen_at`, `actions` and a capped summary (turns, achievements, places/items/NPCs, last scene, recent moments) are updated every turn.
- `PlayLogger` (in-memory queue, background drain, backoff 5 s to 5 min, rejected rows dropped, fail open, disabled under XCTest) and `PostgresPlaySink` (PostgresNIO, SCRAM, TLS 1.2+ verify-full against the bundled games-pg CA). Modeled on GTNW's Games DB store.
- One-time DB password hand-off over SSH (`remote.sh getpw blompie_mac`, BatchMode) into Blompie's Data Protection keychain (service `nova-games-pg`, account `blompie_mac`), run automatically on first launch and from Settings > Play History.
- `keychain-access-groups` entitlement; PostgresNIO package; `tools/add_play_logging.rb` (xcodeproj gem) links the package, sources, CA resource and tests.

### Tests
- `PlayLoggerTests.swift`: 39 tests in all 7 categories (Unit 10, Security 8, Retry 6, Performance 2, Integration 3, Functional 6, Frame 4). Suite: 310 tests, all passing.

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
