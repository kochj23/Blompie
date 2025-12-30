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
}

@MainActor
class GameEngine: ObservableObject {
    @Published var messages: [GameMessage] = []
    @Published var currentActions: [String] = []
    @Published var isLoading: Bool = false

    private var conversationHistory: [OllamaMessage] = []
    private let ollamaService = OllamaService()

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
        do {
            let response = try await ollamaService.chat(messages: conversationHistory)

            conversationHistory.append(OllamaMessage(
                role: "assistant",
                content: response
            ))

            // Parse response to extract narrative and actions
            parseOllamaResponse(response)

            saveGame()
        } catch {
            addMessage("=== ERROR ===")
            if let ollamaError = error as? OllamaError {
                addMessage(ollamaError.errorDescription ?? error.localizedDescription)
            } else {
                addMessage("Error: \(error.localizedDescription)")
            }
            addMessage("")
            addMessage("Troubleshooting:")
            addMessage("• Make sure Ollama is running: ollama serve")
            addMessage("• Verify mistral model is installed: ollama pull mistral")
            addMessage("• Check Ollama is on port 11434")
        }
    }

    private func parseOllamaResponse(_ response: String) {
        let lines = response.components(separatedBy: .newlines)
        var narrativeLines: [String] = []
        var actions: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("ACTIONS:") {
                // Extract actions
                let actionsString = trimmed.replacingOccurrences(of: "ACTIONS:", with: "").trimmingCharacters(in: .whitespaces)
                actions = actionsString.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !trimmed.isEmpty {
                narrativeLines.append(line)
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

    func saveGame() {
        let state = GameState(
            messages: messages,
            conversationHistory: conversationHistory,
            currentActions: currentActions
        )

        if let encoded = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(encoded, forKey: "BlompieGameState")
        }
    }

    func loadGame() {
        guard let data = UserDefaults.standard.data(forKey: "BlompieGameState"),
              let state = try? JSONDecoder().decode(GameState.self, from: data) else {
            return
        }

        messages = state.messages
        conversationHistory = state.conversationHistory
        currentActions = state.currentActions
    }
}
