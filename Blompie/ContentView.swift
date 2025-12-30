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
    @State private var newSaveName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(gameEngine.messages) { message in
                            Text(message.text)
                                .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color)
                                .textSelection(.enabled)
                                .id(message.id)
                        }

                        // Show streaming text
                        if !gameEngine.streamingText.isEmpty {
                            Text(gameEngine.streamingText)
                                .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.8))
                                .textSelection(.enabled)
                        }

                        if gameEngine.isLoading && gameEngine.streamingText.isEmpty {
                            HStack(spacing: 4) {
                                Text(">")
                                    .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.6))
                                Text("Thinking...")
                                    .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.6))
                            }
                            .font(.system(size: gameEngine.fontSize, design: .monospaced))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(gameEngine.currentTheme.backgroundColor.color)
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

            // Action buttons
            if !gameEngine.currentActions.isEmpty && !gameEngine.isLoading {
                VStack(spacing: 8) {
                    ForEach(gameEngine.currentActions, id: \.self) { action in
                        Button(action: {
                            gameEngine.performAction(action)
                        }) {
                            Text(action)
                                .font(.system(size: gameEngine.fontSize, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(gameEngine.currentTheme.textColor.color.opacity(0.1))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(gameEngine.currentTheme.backgroundColor.color.opacity(0.9))
            }

            // Control buttons
            HStack(spacing: 12) {
                Button(action: {
                    gameEngine.startNewGame()
                }) {
                    Text("New Game")
                        .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    showSaveDialog = true
                }) {
                    Text("Save")
                        .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    showLoadDialog = true
                }) {
                    Text("Load")
                        .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    exportTranscript()
                }) {
                    Text("Export")
                        .font(.system(size: gameEngine.fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    showSettings = true
                }) {
                    Text("⚙")
                        .font(.system(size: gameEngine.fontSize, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(gameEngine.currentTheme.backgroundColor.color.opacity(0.9))
        }
        .background(gameEngine.currentTheme.backgroundColor.color)
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

// MARK: - Save Dialog

struct SaveDialogView: View {
    @ObservedObject var gameEngine: GameEngine
    @Binding var isPresented: Bool
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Save Game")
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(gameEngine.currentTheme.textColor.color)

            TextField("Save Name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 16) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(gameEngine.currentTheme.textColor.color)

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
        .background(gameEngine.currentTheme.backgroundColor.color)
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
                .foregroundColor(gameEngine.currentTheme.textColor.color)

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
                                    .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.7))
                            }
                            .foregroundColor(gameEngine.currentTheme.textColor.color)

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
                        .background(gameEngine.currentTheme.textColor.color.opacity(0.1))
                        .cornerRadius(8)
                    }

                    if gameEngine.getSaveSlots().isEmpty {
                        Text("No saved games")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.5))
                            .padding()
                    }
                }
            }
            .frame(height: 300)

            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.borderless)
            .foregroundColor(gameEngine.currentTheme.textColor.color)
        }
        .padding(30)
        .frame(width: 500)
        .background(gameEngine.currentTheme.backgroundColor.color)
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
                    .foregroundColor(gameEngine.currentTheme.textColor.color)

                // Model Selection
                SettingsSection(title: "AI Model", textColor: gameEngine.currentTheme.textColor.color) {
                    Picker("Model", selection: $gameEngine.selectedModel) {
                        ForEach(gameEngine.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: gameEngine.selectedModel) { _ in
                        gameEngine.saveSettings()
                    }
                }

                // Font Size
                SettingsSection(title: "Font Size", textColor: gameEngine.currentTheme.textColor.color) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(Int(gameEngine.fontSize))pt")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color)
                            Spacer()
                        }
                        Slider(value: $gameEngine.fontSize, in: 8...36, step: 2)
                            .onChange(of: gameEngine.fontSize) { _ in
                                gameEngine.saveSettings()
                            }
                    }
                }

                // Streaming
                SettingsSection(title: "Streaming", textColor: gameEngine.currentTheme.textColor.color) {
                    Toggle("Enable streaming responses", isOn: $gameEngine.streamingEnabled)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                        .onChange(of: gameEngine.streamingEnabled) { _ in
                            gameEngine.saveSettings()
                        }
                }

                // Response Style
                SettingsSection(title: "Response Style", textColor: gameEngine.currentTheme.textColor.color) {
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
                            .foregroundColor(gameEngine.currentTheme.textColor.color)
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
                SettingsSection(title: "Auto-Save", textColor: gameEngine.currentTheme.textColor.color) {
                    Toggle("Enable auto-save", isOn: $gameEngine.autoSaveEnabled)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                        .onChange(of: gameEngine.autoSaveEnabled) { _ in
                            gameEngine.saveSettings()
                        }
                }

                // Color Theme
                SettingsSection(title: "Color Theme", textColor: gameEngine.currentTheme.textColor.color) {
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
                                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                                    Spacer()
                                    if theme.id == gameEngine.currentTheme.id {
                                        Text("✓")
                                            .foregroundColor(gameEngine.currentTheme.textColor.color)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(theme.id == gameEngine.currentTheme.id ? gameEngine.currentTheme.textColor.color.opacity(0.2) : Color.clear)
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Save Management
                SettingsSection(title: "Save Management", textColor: gameEngine.currentTheme.textColor.color) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(gameEngine.getSaveSlots().count) save(s)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.7))

                        Button("Delete All Saves") {
                            showDeleteAllConfirm = true
                        }
                        .foregroundColor(.red)
                        .font(.system(.body, design: .monospaced))
                    }
                }

                // About
                SettingsSection(title: "About", textColor: gameEngine.currentTheme.textColor.color) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blompie v1.2.0")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(gameEngine.currentTheme.textColor.color)

                        Text("AI-Powered Text Adventure")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.7))

                        Text("Created by Jordan Koch")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(gameEngine.currentTheme.textColor.color.opacity(0.7))

                        Button("GitHub") {
                            if let url = URL(string: "https://github.com/kochj23/Blompie") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                    }
                }

                // Reset
                SettingsSection(title: "Reset", textColor: gameEngine.currentTheme.textColor.color) {
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
        .background(gameEngine.currentTheme.backgroundColor.color)
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
