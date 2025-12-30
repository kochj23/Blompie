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
    @AppStorage("fontSize") private var fontSize: Double = 14
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
                                .font(.system(size: fontSize, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color)
                                .textSelection(.enabled)
                                .id(message.id)
                        }

                        // Show streaming text
                        if !gameEngine.streamingText.isEmpty {
                            Text(gameEngine.streamingText)
                                .font(.system(size: fontSize, design: .monospaced))
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
                            .font(.system(size: fontSize, design: .monospaced))
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
                                .font(.system(size: fontSize, design: .monospaced))
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
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    showSaveDialog = true
                }) {
                    Text("Save")
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    showLoadDialog = true
                }) {
                    Text("Load")
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Button(action: {
                    exportTranscript()
                }) {
                    Text("Export")
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .buttonStyle(.plain)

                Spacer()

                // Model selector
                Menu {
                    ForEach(gameEngine.availableModels, id: \.self) { model in
                        Button(model) {
                            gameEngine.selectedModel = model
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Model:")
                            .font(.system(size: fontSize - 2, design: .monospaced))
                        Text(gameEngine.selectedModel)
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(gameEngine.currentTheme.textColor.color)
                }
                .menuStyle(.borderlessButton)

                Button(action: {
                    showSettings = true
                }) {
                    Text("⚙")
                        .font(.system(size: fontSize, design: .monospaced))
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
            if fontSize < 36 {
                fontSize += 2
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DecreaseFontSize"))) { _ in
            if fontSize > 8 {
                fontSize -= 2
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

    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(gameEngine.currentTheme.textColor.color)

            VStack(alignment: .leading, spacing: 16) {
                Text("Color Theme")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(gameEngine.currentTheme.textColor.color)

                ForEach(ColorTheme.allThemes) { theme in
                    Button(action: {
                        gameEngine.setTheme(theme)
                    }) {
                        HStack {
                            Circle()
                                .fill(theme.textColor.color)
                                .frame(width: 20, height: 20)
                            Text(theme.name)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(gameEngine.currentTheme.textColor.color)
                            Spacer()
                            if theme.id == gameEngine.currentTheme.id {
                                Text("✓")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(gameEngine.currentTheme.textColor.color)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(theme.id == gameEngine.currentTheme.id ? gameEngine.currentTheme.textColor.color.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 400, height: 500)
        .background(gameEngine.currentTheme.backgroundColor.color)
    }
}

#Preview {
    ContentView()
}
