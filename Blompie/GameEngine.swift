//
//  GameEngine.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import Foundation
import SwiftUI

struct GameMessage: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }
}

struct GameState: Codable {
    var messages: [GameMessage]
    var conversationHistory: [OllamaMessage]
    var currentActions: [String]
    var slotName: String
    var savedDate: Date
}

struct SaveSlot: Identifiable, Codable {
    let id: String
    let name: String
    let savedDate: Date
    var messageCount: Int
}

@MainActor
class GameEngine: ObservableObject {
    @Published var messages: [GameMessage] = []
    @Published var currentActions: [String] = []
    @Published var isLoading: Bool = false
    @Published var streamingText: String = ""
    @Published var selectedModel: String = "mistral"
    @Published var availableModels: [String] = ["mistral", "llama3.2", "llama3.1", "codellama", "phi"]
    @Published var currentTheme: ColorTheme = ColorTheme.classicGreen

    private var conversationHistory: [OllamaMessage] = []
    private let ollamaService = OllamaService()

    init() {
        loadTheme()
    }

    func setTheme(_ theme: ColorTheme) {
        currentTheme = theme
        saveTheme()
    }

    private func saveTheme() {
        if let encoded = try? JSONEncoder().encode(currentTheme) {
            UserDefaults.standard.set(encoded, forKey: "BlompieColorTheme")
        }
    }

    private func loadTheme() {
        guard let data = UserDefaults.standard.data(forKey: "BlompieColorTheme"),
              let theme = try? JSONDecoder().decode(ColorTheme.self, from: data) else {
            return
        }
        currentTheme = theme
    }

    private let systemPrompt = """
    You are the game master for a text-based adventure game in the style of Zork. Your role is to:

    1. Create an immersive, mysterious world with interesting locations, puzzles, and discoveries
    2. Respond to player actions with vivid descriptions
    3. Present 2-4 possible actions the player can take after each description
    4. Be creative and surprising - no set objective or monsters, just exploration and discovery
    5. Track inventory, location, and game state implicitly
    6. Make the world feel alive and responsive to player choices

    CRITICAL FORMAT REQUIREMENT:
    Always end your response with a line containing ONLY:
    ACTIONS: action1 | action2 | action3 | action4

    Example response format:
    You are standing in a dimly lit cavern. Water drips from stalactites above, creating an eerie echo. To the north, you see a faint glowing light. To the east, a narrow passage winds into darkness. A worn leather journal lies at your feet.

    ACTIONS: Go north toward the light | Enter the eastern passage | Pick up the journal | Examine the cavern walls

    Keep descriptions concise but evocative (2-4 sentences). Make actions specific and interesting.
    """

    func startNewGame() {
        messages = []
        conversationHistory = []
        currentActions = []

        addMessage("=== BLOMPIE ===")
        addMessage("A Text Adventure Powered by Ollama")
        addMessage("")
        addMessage("Initializing game world...")
        addMessage("")

        Task {
            await generateInitialScene()
        }
    }

    func performAction(_ action: String) {
        addMessage("> \(action)")
        addMessage("")

        Task {
            await sendMessageToOllama(action)
        }
    }

    private func generateInitialScene() async {
        isLoading = true

        conversationHistory.append(OllamaMessage(
            role: "system",
            content: systemPrompt
        ))

        conversationHistory.append(OllamaMessage(
            role: "user",
            content: "Start a new text adventure. Describe the opening scene and provide the first set of actions."
        ))

        await sendToOllama()
        isLoading = false
    }

    private func sendMessageToOllama(_ userMessage: String) async {
        isLoading = true

        conversationHistory.append(OllamaMessage(
            role: "user",
            content: userMessage
        ))

        await sendToOllama()
        isLoading = false
    }

    private func sendToOllama() async {
        ollamaService.model = selectedModel
        streamingText = ""
        var fullResponse = ""

        do {
            try await ollamaService.chatStreaming(messages: conversationHistory) { chunk in
                Task { @MainActor in
                    fullResponse += chunk
                    self.streamingText = fullResponse
                }
            }

            conversationHistory.append(OllamaMessage(
                role: "assistant",
                content: fullResponse
            ))

            streamingText = ""

            // Parse response to extract narrative and actions
            parseOllamaResponse(fullResponse)

            saveGame(toSlot: "autosave")
        } catch {
            streamingText = ""
            addMessage("=== ERROR ===")
            if let ollamaError = error as? OllamaError {
                addMessage(ollamaError.errorDescription ?? error.localizedDescription)
            } else {
                addMessage("Error: \(error.localizedDescription)")
            }
            addMessage("")
            addMessage("Troubleshooting:")
            addMessage("• Make sure Ollama is running: ollama serve")
            addMessage("• Verify \(selectedModel) model is installed: ollama pull \(selectedModel)")
            addMessage("• Check Ollama is on port 11434")
        }
    }

    private func parseOllamaResponse(_ response: String) {
        let lines = response.components(separatedBy: .newlines)
        var narrativeLines: [String] = []
        var actions: [String] = []

        // System prompt keywords to filter out
        let systemPromptPhrases = [
            "You are the game master",
            "Your role is to:",
            "CRITICAL FORMAT REQUIREMENT",
            "Example response format:",
            "Always end your response",
            "Keep descriptions concise",
            "Create an immersive",
            "Respond to player actions",
            "Present 2-4 possible actions",
            "Be creative and surprising",
            "Track inventory",
            "Make the world feel alive"
        ]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("ACTIONS:") {
                // Extract actions
                let actionsString = trimmed.replacingOccurrences(of: "ACTIONS:", with: "").trimmingCharacters(in: .whitespaces)
                actions = actionsString.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !trimmed.isEmpty {
                // Filter out system prompt text
                let isSystemPrompt = systemPromptPhrases.contains { phrase in
                    trimmed.contains(phrase)
                }

                if !isSystemPrompt {
                    narrativeLines.append(line)
                }
            }
        }

        // Add narrative to messages
        let narrative = narrativeLines.joined(separator: "\n")
        if !narrative.isEmpty {
            addMessage(narrative)
            addMessage("")
        }

        // Update current actions
        currentActions = actions.filter { !$0.isEmpty }

        // If no actions were found, provide default exploration actions
        if currentActions.isEmpty {
            currentActions = ["Look around", "Continue", "Go back", "Examine surroundings"]
        }
    }

    private func addMessage(_ text: String) {
        messages.append(GameMessage(text: text))
    }

    // MARK: - Save/Load

    func saveGame(toSlot slotName: String = "autosave") {
        let state = GameState(
            messages: messages,
            conversationHistory: conversationHistory,
            currentActions: currentActions,
            slotName: slotName,
            savedDate: Date()
        )

        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: "BlompieGameState_\(slotName)")
            updateSaveSlotMetadata(slotName: slotName, messageCount: messages.count)
        }
    }

    func loadGame(fromSlot slotName: String = "autosave") {
        guard let data = UserDefaults.standard.data(forKey: "BlompieGameState_\(slotName)"),
              let state = try? JSONDecoder().decode(GameState.self, from: data) else {
            return
        }

        messages = state.messages
        conversationHistory = state.conversationHistory
        currentActions = state.currentActions
    }

    func getSaveSlots() -> [SaveSlot] {
        guard let data = UserDefaults.standard.data(forKey: "BlompieSaveSlots"),
              let slots = try? JSONDecoder().decode([SaveSlot].self, from: data) else {
            return []
        }
        return slots.sorted { $0.savedDate > $1.savedDate }
    }

    private func updateSaveSlotMetadata(slotName: String, messageCount: Int) {
        var slots = getSaveSlots()
        slots.removeAll { $0.id == slotName }
        slots.append(SaveSlot(id: slotName, name: slotName, savedDate: Date(), messageCount: messageCount))

        if let encoded = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(encoded, forKey: "BlompieSaveSlots")
        }
    }

    func deleteSaveSlot(_ slotName: String) {
        UserDefaults.standard.removeObject(forKey: "BlompieGameState_\(slotName)")
        var slots = getSaveSlots()
        slots.removeAll { $0.id == slotName }
        if let encoded = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(encoded, forKey: "BlompieSaveSlots")
        }
    }

    // MARK: - Export

    func exportTranscript() -> String {
        var transcript = "=== BLOMPIE GAME TRANSCRIPT ===\n"
        transcript += "Exported: \(Date().formatted())\n"
        transcript += "Model: \(selectedModel)\n"
        transcript += "Total Messages: \(messages.count)\n"
        transcript += "\n" + String(repeating: "=", count: 50) + "\n\n"

        for message in messages {
            transcript += message.text + "\n"
        }

        return transcript
    }
}
