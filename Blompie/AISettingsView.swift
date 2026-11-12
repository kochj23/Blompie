//
//  AISettingsView.swift
//  Blompie
//
//  AI options UI: the toolbar narrator status badge and the Settings
//  "AI Narrator" section (global toggle, backend + model pickers, endpoint
//  URLs, Keychain-backed keys, per-backend status and "Test connection").
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import SwiftUI

// MARK: - Toolbar badge

/// "Narrator: online (Ollama)" / "away (scripted fallback)" / "AI off (scripted)".
struct NarratorStatusBadge: View {
    @ObservedObject var gameEngine: GameEngine
    @ObservedObject private var ai = AIBackendManager.shared

    private var color: Color {
        if !ai.aiEnabled { return ModernColors.textSecondary }
        return ai.statusOnline ? ModernColors.statusLow : ModernColors.orange
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(ai.statusText)
                    .font(.system(size: gameEngine.fontSize - 4, design: .monospaced))
                    .foregroundColor(ModernColors.textPrimary)
                if let source = gameEngine.lastNarrationSource {
                    Text("Last turn: \(source.label)")
                        .font(.system(size: gameEngine.fontSize - 6, design: .monospaced))
                        .foregroundColor(ModernColors.textSecondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
        .help("AI narrator status. Settings > AI Narrator to change backend or test the connection.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Spectator bar

/// Shown while the AI adventurer plays: SPECTATING indicator, turn count, who chose the
/// last command, speed (delay between turns), pause/resume and take-over.
struct SpectatorBar: View {
    @ObservedObject var gameEngine: GameEngine

    var body: some View {
        HStack(spacing: 12) {
            Text("● SPECTATING")
                .fontWeight(.bold)
                .foregroundColor(ModernColors.statusCritical)
            Text("turn \(gameEngine.spectatorTurns)/\(gameEngine.spectatorMaxTurns)")
                .foregroundColor(ModernColors.textSecondary)
            if gameEngine.adventurerThinking {
                Text("adventurer thinking...").foregroundColor(ModernColors.cyan)
            } else if let source = gameEngine.lastAdventurerSource {
                Text("adventurer: \(source.isAI ? source.label : "heuristic")").foregroundColor(ModernColors.textSecondary)
            }
            Spacer()
            Text("Delay \(String(format: "%.1f", gameEngine.spectatorDelay))s")
                .foregroundColor(ModernColors.textSecondary)
            Slider(value: $gameEngine.spectatorDelay, in: 0.5...10, step: 0.5)
                .frame(width: 110)
                .help("Seconds between adventurer turns")
            Button(gameEngine.spectatorPaused ? "Resume" : "Pause") { gameEngine.spectatorPaused.toggle() }
            Button("Take Over") { gameEngine.takeOver() }
                .help("Stop the adventurer and play from here (this story is still not recorded)")
        }
        .font(.system(size: gameEngine.fontSize - 3, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(ModernColors.statusCritical.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ModernColors.statusCritical.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Settings section

struct AINarratorSettingsSection: View {
    @ObservedObject var gameEngine: GameEngine
    @ObservedObject private var ai = AIBackendManager.shared
    @State private var openAIKeyField = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        SettingsSection(title: "AI Narrator", textColor: ModernColors.textPrimary) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use AI narrator", isOn: $ai.aiEnabled)
                    .onChange(of: ai.aiEnabled) { _, _ in
                        ai.saveConfiguration()
                        Task { await ai.refreshAllBackends() }
                    }
                caption("Off: the built-in scripted narrator runs the game and nothing is sent over the network. On: if no backend answers, the scripted narrator fills in for that turn.")

                if ai.aiEnabled {
                    Picker("Backend", selection: $ai.activeBackend) {
                        ForEach(LLMBackendType.allCases, id: \.self) { backend in
                            Label(backend.displayName, systemImage: backend.icon).tag(backend)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: ai.activeBackend) { _, _ in ai.saveConfiguration() }
                    caption(ai.activeBackend.description)

                    modelPicker
                    endpointFields
                    keyFields

                    HStack {
                        Button(testing ? "Testing…" : "Test connection") {
                            testing = true
                            Task {
                                let ok = await ai.testConnection()
                                await MainActor.run {
                                    testing = false
                                    testResult = ok ? "Reachable" : "Unreachable"
                                }
                            }
                        }
                        .disabled(testing)
                        if let testResult {
                            Text(testResult)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(testResult == "Reachable" ? ModernColors.statusLow : ModernColors.orange)
                        }
                        Spacer()
                        Text(ai.statusText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(ModernColors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(LLMBackendType.concrete, id: \.self) { backend in
                            BackendStatusRow(icon: backend.icon, name: backend.displayName,
                                             isAvailable: ai.isAvailable(backend),
                                             url: backend == .mlx ? AIBackendManager.mlxExecutable : ai.baseURL(for: backend))
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .foregroundColor(ModernColors.textPrimary)
        }
    }

    @ViewBuilder private var modelPicker: some View {
        switch ai.activeBackend {
        case .auto, .ollama, .tinyChat, .openWebUI:
            HStack {
                Picker("Model", selection: $gameEngine.selectedModel) {
                    ForEach(gameEngine.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: gameEngine.selectedModel) { _, _ in gameEngine.saveSettings() }
                Button("Refresh") { Task { await gameEngine.refreshAvailableModels() } }
            }
        case .openRouter:
            Picker("Model", selection: $ai.selectedOpenRouterModel) {
                ForEach(ai.openRouterModels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: ai.selectedOpenRouterModel) { _, _ in ai.saveConfiguration() }
        case .openAI:
            field("Model", text: $ai.selectedOpenAIModel)
        case .mlx:
            field("MLX model", text: $ai.selectedMLXModel)
        case .tinyLLM:
            field("Model", text: $ai.tinyLLMModel)
        case .novaGateway:
            caption("Model: nova (the gateway applies Nova's own routing; Claude is reached here or via OpenRouter)")
        }
    }

    @ViewBuilder private var endpointFields: some View {
        DisclosureGroup("Endpoints") {
            VStack(alignment: .leading, spacing: 6) {
                urlField("Ollama", text: $ai.ollamaServerURL)
                urlField("TinyLLM", text: $ai.tinyLLMServerURL)
                urlField("TinyChat", text: $ai.tinyChatServerURL)
                urlField("OpenWebUI", text: $ai.openWebUIServerURL)
                urlField("Nova Gateway", text: $ai.novaGatewayServerURL)
                urlField("OpenRouter (https)", text: $ai.openRouterServerURL)
                urlField("OpenAI (https)", text: $ai.openAIServerURL)
                caption("Defaults point at this Mac; any LAN host works. API keys are only ever sent to https URLs.")
            }
        }
    }

    @ViewBuilder private var keyFields: some View {
        if ai.activeBackend == .openAI || ai.activeBackend == .auto {
            VStack(alignment: .leading, spacing: 4) {
                caption("OpenAI API key (Keychain)")
                HStack {
                    SecureField(ai.hasOpenAIKey ? "•••••• (saved)" : "sk-…", text: $openAIKeyField)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        ai.setOpenAIAPIKey(openAIKeyField)
                        openAIKeyField = ""
                        Task { await ai.refreshAllBackends() }
                    }
                }
            }
        }
        if ai.activeBackend == .openRouter || ai.activeBackend == .auto {
            caption("OpenRouter API key: see Multi-Model Load Balancing below (one key for every frontier model, stored in the Keychain).")
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { ai.saveConfiguration() }
        }
    }

    private func urlField(_ title: String, text: Binding<String>) -> some View {
        let valid = EndpointPolicy.isValidBaseURL(text.wrappedValue)
        return HStack {
            Text(title).frame(width: 150, alignment: .leading)
                .font(.system(.caption, design: .monospaced))
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit {
                    if EndpointPolicy.isValidBaseURL(text.wrappedValue) {
                        ai.saveConfiguration()
                        Task { await ai.refreshAllBackends() }
                    }
                }
            Image(systemName: valid ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(valid ? ModernColors.statusLow : ModernColors.orange)
                .help(valid ? "Valid URL (press Return to save)" : "Enter http(s)://host[:port]")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(ModernColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Backend Status Row

struct BackendStatusRow: View {
    let icon: String
    let name: String
    let isAvailable: Bool
    let url: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                Text(url)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(isAvailable ? "Available" : "Unavailable")
                .font(.caption)
                .foregroundColor(isAvailable ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}
