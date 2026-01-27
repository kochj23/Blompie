//
//  ContentView.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var gameEngine = GameEngine()
    @State private var showSaveDialog = false
    @State private var showLoadDialog = false
    @State private var showSettings = false
    @State private var showAchievements = false
    @State private var showStats = false
    @State private var showImageGeneration = false
    @Environment(\.colorScheme) var systemColorScheme

    var body: some View {
        ZStack {
            // Glassmorphic animated background
            GlassmorphicBackground()

            HStack(spacing: 0) {
                // Main game area
                VStack(spacing: 0) {
                    // Terminal output area with glass card
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(gameEngine.messages) { message in
                                    Text(message.text)
                                        .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                        .foregroundColor(ModernColors.textPrimary)
                                        .textSelection(.enabled)
                                        .id(message.id)
                                }

                                // Show streaming text
                                if !gameEngine.streamingText.isEmpty {
                                    Text(gameEngine.streamingText)
                                        .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                        .foregroundColor(ModernColors.cyan)
                                        .textSelection(.enabled)
                                }

                                if gameEngine.isLoading && gameEngine.streamingText.isEmpty {
                                    HStack(spacing: 4) {
                                        Text(">")
                                            .foregroundColor(ModernColors.cyan.opacity(0.6))
                                        Text("Thinking...")
                                            .foregroundColor(ModernColors.cyan.opacity(0.6))
                                    }
                                    .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.3))
                                .background(.ultraThinMaterial.opacity(0.9))
                        )
                        .padding(12)
                    .onChange(of: gameEngine.messages.count) {
                        if let lastMessage = gameEngine.messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: gameEngine.streamingText) {
                        withAnimation(.linear(duration: 0.1)) {
                            if let lastMessage = gameEngine.messages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Action history
                if !gameEngine.actionHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent Actions:")
                            .font(.system(size: gameEngine.fontSize - 4, design: .monospaced))
                            .foregroundColor(ModernColors.yellow)

                        ForEach(gameEngine.actionHistory.suffix(5).reversed(), id: \.self) { action in
                            Text("• \(action)")
                                .font(.system(size: gameEngine.fontSize - 4, design: .monospaced))
                                .foregroundColor(ModernColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal, 12)
                }

                // Action buttons with keyboard shortcuts
                if !gameEngine.currentActions.isEmpty && !gameEngine.isLoading {
                    VStack(spacing: 8) {
                        ForEach(Array(gameEngine.currentActions.enumerated()), id: \.element) { index, action in
                            Button(action: {
                                gameEngine.performAction(action)
                            }) {
                                HStack {
                                    Text("[\(index + 1)]")
                                        .foregroundColor(ModernColors.cyan.opacity(0.8))
                                    Text(action)
                                    Spacer()
                                }
                                .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                .foregroundColor(ModernColors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(ModernColors.cyan.opacity(0.15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(ModernColors.cyan.opacity(0.5), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal, 12)
                }

                // Control buttons
                HStack(spacing: 12) {
                    Button(action: {
                        gameEngine.startNewGame()
                    }) {
                        Text("New Game")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        gameEngine.undoLastAction()
                    }) {
                        Text("Undo")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(gameEngine.stateHistory.isEmpty)

                    Button(action: {
                        showSaveDialog = true
                    }) {
                        Text("Save")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        showLoadDialog = true
                    }) {
                        Text("Load")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        exportTranscript()
                    }) {
                        Text("Export")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Token/sec dial gauge with modern styling
                    if gameEngine.lastTokensPerSecond > 0 {
                        HStack(spacing: 8) {
                            Text("⚡")
                                .font(.system(size: gameEngine.fontSize))
                            Text(String(format: "%.1f t/s", gameEngine.lastTokensPerSecond))
                                .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                                .foregroundColor(ModernColors.cyan)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(ModernColors.cyan.opacity(0.15))
                        )
                    }

                    Button(action: {
                        showStats = true
                    }) {
                        Text("📊")
                            .font(.system(size: gameEngine.fontSize, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        showAchievements = true
                    }) {
                        Text("🏆 \(gameEngine.achievements.filter { $0.isUnlocked }.count)/\(gameEngine.achievements.count)")
                            .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        showImageGeneration = true
                    }) {
                        Text("🎨")
                            .font(.system(size: gameEngine.fontSize, design: .monospaced))
                            .foregroundColor(ModernColors.cyan)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        gameEngine.showSidebar.toggle()
                    }) {
                        Text(gameEngine.showSidebar ? "◀" : "▶")
                            .font(.system(size: gameEngine.fontSize, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        showSettings = true
                    }) {
                        Text("⚙")
                            .font(.system(size: gameEngine.fontSize, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(ModernColors.cyan.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            // Sidebar
            if gameEngine.showSidebar {
                SidebarView(gameEngine: gameEngine)
                    .frame(width: 300)
            }
            }
        }
        .onAppear {
            gameEngine.loadGame(fromSlot: "autosave")
            if gameEngine.messages.isEmpty {
                gameEngine.startNewGame()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IncreaseFontSize"))) { _ in
            if gameEngine.fontSize < 36 {
                gameEngine.fontSize += 2
                gameEngine.saveSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DecreaseFontSize"))) { _ in
            if gameEngine.fontSize > 8 {
                gameEngine.fontSize -= 2
                gameEngine.saveSettings()
            }
        }
        .sheet(isPresented: $showSaveDialog) {
            SaveDialogView(gameEngine: gameEngine, isPresented: $showSaveDialog)
        }
        .sheet(isPresented: $showLoadDialog) {
            LoadDialogView(gameEngine: gameEngine, isPresented: $showLoadDialog)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(gameEngine: gameEngine, isPresented: $showSettings)
        }
        .sheet(isPresented: $showAchievements) {
            AchievementsView(gameEngine: gameEngine, isPresented: $showAchievements)
        }
        .sheet(isPresented: $showStats) {
            StatsView(gameEngine: gameEngine, isPresented: $showStats)
        }
        .sheet(isPresented: $showImageGeneration) {
            ImageGenerationView(
                currentScene: .constant(gameEngine.messages.last?.text ?? "You are in a mysterious place..."),
                isPresented: $showImageGeneration
            )
        }
        .preferredColorScheme(gameEngine.currentTheme.id == "paper" ? .light : .dark)
    }

    private func exportTranscript() {
        let transcript = gameEngine.exportTranscript()

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "blompie_transcript_\(Date().timeIntervalSince1970).txt"
        savePanel.title = "Export Transcript"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? transcript.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var gameEngine: GameEngine
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("📍").tag(0)
                Text("🎒").tag(1)
                Text("👥").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if selectedTab == 0 {
                        // Locations
                        Text("Locations Visited")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(ModernColors.cyan)

                        if gameEngine.locationHistory.isEmpty {
                            Text("No locations yet")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(ModernColors.textSecondary)
                        } else {
                            ForEach(gameEngine.locationHistory.suffix(10).reversed(), id: \.self) { location in
                                Text("• \(location)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ModernColors.textPrimary)
                            }
                        }
                    } else if selectedTab == 1 {
                        // Inventory
                        Text("Inventory")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(ModernColors.cyan)

                        if gameEngine.inventory.isEmpty {
                            Text("No items")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(ModernColors.textSecondary)
                        } else {
                            ForEach(gameEngine.inventory, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ModernColors.textPrimary)
                            }
                        }
                    } else if selectedTab == 2 {
                        // NPCs
                        Text("Characters Met")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(ModernColors.cyan)

                        if gameEngine.metNPCs.isEmpty {
                            Text("No one yet")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(ModernColors.textSecondary)
                        } else {
                            ForEach(gameEngine.metNPCs, id: \.self) { npc in
                                Text("• \(npc)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ModernColors.textPrimary)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .background(.ultraThinMaterial.opacity(0.9))
        )
        .padding(12)
    }
}

// MARK: - Achievements View

struct AchievementsView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            GlassmorphicBackground()

            VStack(spacing: 20) {
                Text("Achievements")
                    .font(.system(.title, design: .monospaced))
                    .foregroundColor(ModernColors.cyan)

                Text("\(gameEngine.achievements.filter { $0.isUnlocked }.count) / \(gameEngine.achievements.count) Unlocked")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(ModernColors.textSecondary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(gameEngine.achievements) { achievement in
                        HStack(alignment: .top, spacing: 12) {
                            Text(achievement.isUnlocked ? "🏆" : "🔒")
                                .font(.system(size: 24))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(achievement.title)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundColor(ModernColors.textPrimary)

                                Text(achievement.description)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ModernColors.textSecondary)

                                if let date = achievement.unlockDate {
                                    Text("Unlocked: \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(ModernColors.textTertiary)
                                }
                            }

                            Spacer()
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(achievement.isUnlocked ? ModernColors.cyan.opacity(0.15) : Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(ModernColors.cyan.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .frame(height: 400)

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(ModernColors.cyan)
            }
            .padding(30)
            .frame(width: 500)
        }
    }
}

// MARK: - Stats View

struct StatsView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Game Statistics")
                .font(.system(.title, design: .monospaced))
                .foregroundColor(ModernColors.textPrimary)

            ScrollView {
                VStack(spacing: 20) {
                    // Performance Stats
                    StatSection(title: "Performance", textColor: ModernColors.textPrimary) {
                        StatRow(label: "Token/sec", value: gameEngine.lastTokensPerSecond > 0 ? String(format: "%.1f", gameEngine.lastTokensPerSecond) : "N/A", textColor: ModernColors.textPrimary)
                        StatRow(label: "Model", value: gameEngine.selectedModel, textColor: ModernColors.textPrimary)
                        StatRow(label: "Random Mode", value: gameEngine.randomModelMode ? "Enabled" : "Disabled", textColor: ModernColors.textPrimary)
                    }

                    // Gameplay Stats
                    StatSection(title: "Gameplay", textColor: ModernColors.textPrimary) {
                        StatRow(label: "Total Actions", value: "\(gameEngine.actionHistory.count)", textColor: ModernColors.textPrimary)
                        StatRow(label: "Total Messages", value: "\(gameEngine.messages.count)", textColor: ModernColors.textPrimary)
                        StatRow(label: "NPCs Met", value: "\(gameEngine.metNPCs.count)", textColor: ModernColors.textPrimary)
                        StatRow(label: "Items Collected", value: "\(gameEngine.inventory.count)", textColor: ModernColors.textPrimary)
                        StatRow(label: "Locations Visited", value: "\(gameEngine.locationHistory.count)", textColor: ModernColors.textPrimary)
                    }

                    // Achievements Summary
                    StatSection(title: "Achievements", textColor: ModernColors.textPrimary) {
                        StatRow(label: "Unlocked", value: "\(gameEngine.achievements.filter { $0.isUnlocked }.count)/\(gameEngine.achievements.count)", textColor: ModernColors.textPrimary)
                        StatRow(label: "Progress", value: String(format: "%.0f%%", Double(gameEngine.achievements.filter { $0.isUnlocked }.count) / Double(gameEngine.achievements.count) * 100), textColor: ModernColors.textPrimary)
                    }

                    // Session Info
                    StatSection(title: "Session", textColor: ModernColors.textPrimary) {
                        StatRow(label: "Theme", value: gameEngine.currentTheme.name, textColor: ModernColors.textPrimary)
                        StatRow(label: "Font Size", value: "\(Int(gameEngine.fontSize))pt", textColor: ModernColors.textPrimary)
                        StatRow(label: "Streaming", value: gameEngine.streamingEnabled ? "Enabled" : "Disabled", textColor: ModernColors.textPrimary)
                        StatRow(label: "Auto-Save", value: gameEngine.autoSaveEnabled ? "Enabled" : "Disabled", textColor: ModernColors.textPrimary)
                    }

                    // All Achievements List
                    VStack(alignment: .leading, spacing: 12) {
                        Text("All Achievements")
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)

                        ForEach(gameEngine.achievements) { achievement in
                            HStack {
                                Text(achievement.isUnlocked ? "✅" : "⬜")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(achievement.title)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(ModernColors.textPrimary)
                                    Text(achievement.description)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(ModernColors.textPrimary.opacity(0.6))
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .background(ModernColors.textPrimary.opacity(0.05))
                    .cornerRadius(8)
                }
            }
            .frame(height: 500)

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .background(.ultraThinMaterial.opacity(0.9))
        )
    }
}

struct StatSection<Content: View>: View {
    let title: String
    let textColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(textColor)

            content
        }
        .padding()
        .background(textColor.opacity(0.05))
        .cornerRadius(8)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let textColor: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(textColor.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(textColor)
        }
    }
}

// MARK: - Save Dialog

struct SaveDialogView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Game")
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(ModernColors.textPrimary)

            TextField("Save Name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 16) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(ModernColors.textPrimary)

                Button("Save") {
                    if !saveName.isEmpty {
                        gameEngine.saveGame(toSlot: saveName)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveName.isEmpty)
            }
        }
        .padding(30)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .background(.ultraThinMaterial.opacity(0.9))
        )
    }
}

// MARK: - Load Dialog

struct LoadDialogView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Load Game")
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(ModernColors.textPrimary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(gameEngine.getSaveSlots()) { slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(slot.name)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                                Text("\(slot.savedDate.formatted()) • \(slot.messageCount) messages")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ModernColors.textSecondary)
                            }
                            .foregroundColor(ModernColors.textPrimary)

                            Spacer()

                            Button("Load") {
                                gameEngine.loadGame(fromSlot: slot.id)
                                isPresented = false
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Delete") {
                                gameEngine.deleteSaveSlot(slot.id)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                        .padding()
                        .background(ModernColors.textPrimary.opacity(0.1))
                        .cornerRadius(8)
                    }

                    if gameEngine.getSaveSlots().isEmpty {
                        Text("No saved games")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ModernColors.textTertiary)
                            .padding()
                    }
                }
            }
            .frame(height: 300)

            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.borderless)
            .foregroundColor(ModernColors.textPrimary)
        }
        .padding(30)
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .background(.ultraThinMaterial.opacity(0.9))
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool
    @State private var showResetConfirm = false
    @State private var showDeleteAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                Text("Settings")
                    .font(.system(.title, design: .monospaced))
                    .foregroundColor(ModernColors.textPrimary)

                // Model Selection
                SettingsSection(title: "AI Model", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Model", selection: $gameEngine.selectedModel) {
                            ForEach(gameEngine.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: gameEngine.selectedModel) { _ in
                            gameEngine.saveSettings()
                        }

                        Button("Refresh Available Models") {
                            Task {
                                await gameEngine.refreshAvailableModels()
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ModernColors.textPrimary)
                    }
                }

                // Font Size
                SettingsSection(title: "Font Size", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Int(gameEngine.fontSize))pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(ModernColors.textPrimary)
                            Spacer()
                        }
                        Slider(value: $gameEngine.fontSize, in: 8...36, step: 2)
                            .onChange(of: gameEngine.fontSize) { _ in
                                gameEngine.saveSettings()
                            }
                    }
                }

                // Streaming
                SettingsSection(title: "Streaming", textColor: ModernColors.textPrimary) {
                    Toggle("Enable streaming responses", isOn: $gameEngine.streamingEnabled)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(ModernColors.textPrimary)
                        .onChange(of: gameEngine.streamingEnabled) { _ in
                            gameEngine.saveSettings()
                        }
                }

                // Response Style
                SettingsSection(title: "Response Style", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Temperature
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Creativity")
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(String(format: "%.1f", gameEngine.temperature))
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .foregroundColor(ModernColors.textPrimary)
                            Slider(value: $gameEngine.temperature, in: 0.0...1.0, step: 0.1)
                                .onChange(of: gameEngine.temperature) { _ in
                                    gameEngine.saveSettings()
                                }
                        }

                        // Detail Level
                        Picker("Detail Level", selection: $gameEngine.detailLevel) {
                            ForEach(DetailLevel.allCases, id: \.self) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: gameEngine.detailLevel) { _ in
                            gameEngine.saveSettings()
                        }

                        // Tone
                        Picker("Tone", selection: $gameEngine.toneStyle) {
                            ForEach(ToneStyle.allCases, id: \.self) { tone in
                                Text(tone.rawValue).tag(tone)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: gameEngine.toneStyle) { _ in
                            gameEngine.saveSettings()
                        }
                    }
                }

                // Auto-Save
                SettingsSection(title: "Auto-Save", textColor: ModernColors.textPrimary) {
                    Toggle("Enable auto-save", isOn: $gameEngine.autoSaveEnabled)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(ModernColors.textPrimary)
                        .onChange(of: gameEngine.autoSaveEnabled) { _ in
                            gameEngine.saveSettings()
                        }
                }

                // Random Model Mode
                SettingsSection(title: "Random Model Mode", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable random model switching", isOn: $gameEngine.randomModelMode)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)
                            .onChange(of: gameEngine.randomModelMode) { _ in
                                gameEngine.saveSettings()
                            }

                        Text("Automatically switches to a random model every N actions to experience different AI storytelling styles.")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(ModernColors.textSecondary)

                        HStack {
                            Text("Switch every")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(ModernColors.textPrimary)
                            Picker("", selection: $gameEngine.actionsUntilModelSwitch) {
                                Text("3").tag(3)
                                Text("5").tag(5)
                                Text("10").tag(10)
                                Text("15").tag(15)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: gameEngine.actionsUntilModelSwitch) { _ in
                                gameEngine.saveSettings()
                            }
                            Text("actions")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(ModernColors.textPrimary)
                        }
                        .disabled(!gameEngine.randomModelMode)
                    }
                }

                // Color Theme
                SettingsSection(title: "Color Theme", textColor: ModernColors.textPrimary) {
                    VStack(spacing: 8) {
                        ForEach(ColorTheme.allThemes) { theme in
                            Button(action: {
                                gameEngine.setTheme(theme)
                            }) {
                                HStack {
                                    Circle()
                                        .fill(theme.textColor.color)
                                        .frame(width: 16, height: 16)
                                    Text(theme.name)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(ModernColors.textPrimary)
                                    Spacer()
                                    if theme.id == gameEngine.currentTheme.id {
                                        Text("✓")
                                            .foregroundColor(ModernColors.textPrimary)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(theme.id == gameEngine.currentTheme.id ? ModernColors.textPrimary.opacity(0.2) : Color.clear)
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Save Management
                SettingsSection(title: "Save Management", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(gameEngine.getSaveSlots().count) save(s)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(ModernColors.textSecondary)

                        Button("Delete All Saves") {
                            showDeleteAllConfirm = true
                        }
                        .foregroundColor(.red)
                        .font(.system(.body, design: .monospaced))
                    }
                }

                // About
                SettingsSection(title: "About", textColor: ModernColors.textPrimary) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blompie v1.3.0")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ModernColors.textPrimary)

                        Text("AI-Powered Text Adventure")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(ModernColors.textSecondary)

                        Text("Created by Jordan Koch")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(ModernColors.textSecondary)

                        Button("GitHub") {
                            if let url = URL(string: "https://github.com/kochj23/Blompie") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ModernColors.textPrimary)
                    }
                }

                // Reset
                SettingsSection(title: "Reset", textColor: ModernColors.textPrimary) {
                    Button("Reset All Settings to Defaults") {
                        showResetConfirm = true
                    }
                    .foregroundColor(.red)
                    .font(.system(.body, design: .monospaced))
                }

                // Done button
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 16)
            }
            .padding(30)
        }
        .frame(width: 600, height: 700)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.3))
                .background(.ultraThinMaterial.opacity(0.9))
        )
        .alert("Reset Settings?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                gameEngine.resetSettings()
            }
        } message: {
            Text("This will reset all settings to their default values.")
        }
        .alert("Delete All Saves?", isPresented: $showDeleteAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                gameEngine.deleteAllSaves()
            }
        } message: {
            Text("This will permanently delete all saved games. This cannot be undone.")
        }
    }
}

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    let textColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(textColor)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(textColor.opacity(0.05))
        .cornerRadius(8)
    }
}

#Preview {
    ContentView()
}
