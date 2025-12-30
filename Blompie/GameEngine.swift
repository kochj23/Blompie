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

enum DetailLevel: String, Codable, CaseIterable {
    case brief = "Brief"
    case normal = "Normal"
    case detailed = "Detailed"
}

enum ToneStyle: String, Codable, CaseIterable {
    case serious = "Serious"
    case balanced = "Balanced"
    case whimsical = "Whimsical"
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

    // Settings
    @Published var fontSize: Double = 14
    @Published var streamingEnabled: Bool = true
    @Published var temperature: Double = 0.7
    @Published var detailLevel: DetailLevel = .normal
    @Published var toneStyle: ToneStyle = .balanced
    @Published var autoSaveEnabled: Bool = true

    private var conversationHistory: [OllamaMessage] = []
    private let ollamaService = OllamaService()

    init() {
        loadSettings()
    }

    func setTheme(_ theme: ColorTheme) {
        currentTheme = theme
        saveSettings()
    }

    func saveSettings() {
        UserDefaults.standard.set(fontSize, forKey: "BlompieFontSize")
        UserDefaults.standard.set(streamingEnabled, forKey: "BlompieStreamingEnabled")
        UserDefaults.standard.set(temperature, forKey: "BlompieTemperature")
        UserDefaults.standard.set(detailLevel.rawValue, forKey: "BlompieDetailLevel")
        UserDefaults.standard.set(toneStyle.rawValue, forKey: "BlompieToneStyle")
        UserDefaults.standard.set(autoSaveEnabled, forKey: "BlompieAutoSaveEnabled")
        UserDefaults.standard.set(selectedModel, forKey: "BlompieSelectedModel")

        if let encoded = try? JSONEncoder().encode(currentTheme) {
            UserDefaults.standard.set(encoded, forKey: "BlompieColorTheme")
        }
    }

    private func loadSettings() {
        fontSize = UserDefaults.standard.double(forKey: "BlompieFontSize")
        if fontSize == 0 { fontSize = 14 }

        streamingEnabled = UserDefaults.standard.object(forKey: "BlompieStreamingEnabled") as? Bool ?? true
        temperature = UserDefaults.standard.double(forKey: "BlompieTemperature")
        if temperature == 0 { temperature = 0.7 }

        if let detailStr = UserDefaults.standard.string(forKey: "BlompieDetailLevel"),
           let detail = DetailLevel(rawValue: detailStr) {
            detailLevel = detail
        }

        if let toneStr = UserDefaults.standard.string(forKey: "BlompieToneStyle"),
           let tone = ToneStyle(rawValue: toneStr) {
            toneStyle = tone
        }

        autoSaveEnabled = UserDefaults.standard.object(forKey: "BlompieAutoSaveEnabled") as? Bool ?? true

        if let model = UserDefaults.standard.string(forKey: "BlompieSelectedModel") {
            selectedModel = model
        }

        if let data = UserDefaults.standard.data(forKey: "BlompieColorTheme"),
           let theme = try? JSONDecoder().decode(ColorTheme.self, from: data) {
            currentTheme = theme
        }
    }

    func resetSettings() {
        fontSize = 14
        streamingEnabled = true
        temperature = 0.7
        detailLevel = .normal
        toneStyle = .balanced
        autoSaveEnabled = true
        selectedModel = "mistral"
        currentTheme = ColorTheme.classicGreen
        saveSettings()
    }

    func deleteAllSaves() {
        let slots = getSaveSlots()
        for slot in slots {
            deleteSaveSlot(slot.id)
        }
        messages = []
        conversationHistory = []
        currentActions = []
    }

    private func generateSystemPrompt() -> String {
        let detailInstruction: String
        switch detailLevel {
        case .brief:
            detailInstruction = "Keep descriptions VERY brief (1-2 sentences maximum). Focus on action over description."
        case .normal:
            detailInstruction = "Keep descriptions concise but evocative (2-4 sentences)."
        case .detailed:
            detailInstruction = "Provide rich, detailed descriptions (4-6 sentences). Paint a vivid picture with sensory details."
        }

        let toneInstruction: String
        switch toneStyle {
        case .serious:
            toneInstruction = "Maintain a serious, dramatic tone. The world is mysterious and consequential."
        case .balanced:
            toneInstruction = "Balance seriousness with occasional lightness. The world can be both mysterious and charming."
        case .whimsical:
            toneInstruction = "Embrace whimsy and humor. The world is playful, quirky, and delightfully strange."
        }

        return """
        You are the game master for a text-based adventure game in the style of Zork. Your role is to:

        1. Create an immersive, mysterious world with interesting locations, puzzles, and discoveries
        2. Populate the world with NPCs, creatures, and other beings the player can interact with
        3. Include friendly characters to talk to, trade with, or help (not everything is hostile!)
        4. Add mysterious beings with their own agendas - some helpful, some mischievous, none deadly
        5. Create opportunities for dialogue, trading items, solving problems together, and making allies
        6. Present 2-4 possible actions focusing on INTERACTION over examination
        7. Track inventory, location, relationships, and game state implicitly
        8. Make the world feel alive with beings who have personality, quirks, and goals
        9. Avoid deadly combat - conflicts should be puzzles, negotiations, or clever escapes
        10. Vary the gameplay: talking, trading, following, helping, questioning, befriending

        IMPORTANT: Balance exploration with social interaction. Not every scene needs an NPC, but the player should regularly encounter other beings. These can be:
        - Friendly travelers with useful information or items to trade
        - Eccentric shopkeepers or merchants
        - Magical creatures who speak in riddles
        - Lost adventurers who need help
        - Mysterious guides offering cryptic advice
        - Mischievous sprites playing harmless tricks
        - Wise elders with stories and knowledge
        - Fellow explorers with their own quests

        STYLE: \(detailInstruction) \(toneInstruction)

        CRITICAL FORMAT REQUIREMENT:
        Always end your response with a line containing ONLY:
        ACTIONS: action1 | action2 | action3 | action4

        Make actions specific and interesting. Prioritize interactive actions over passive examination.
        """
    }

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
            content: generateSystemPrompt()
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
        ollamaService.temperature = temperature
        streamingText = ""
        var fullResponse = ""

        do {
            if streamingEnabled {
                try await ollamaService.chatStreaming(messages: conversationHistory) { chunk in
                    Task { @MainActor in
                        fullResponse += chunk
                        self.streamingText = fullResponse
                    }
                }
            } else {
                fullResponse = try await ollamaService.chat(messages: conversationHistory)
            }

            conversationHistory.append(OllamaMessage(
                role: "assistant",
                content: fullResponse
            ))

            streamingText = ""

            // Parse response to extract narrative and actions
            parseOllamaResponse(fullResponse)

            if autoSaveEnabled {
                saveGame(toSlot: "autosave")
            }
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
            "Make the world feel alive",
            "Populate the world with NPCs",
            "Include friendly characters",
            "IMPORTANT: Balance exploration",
            "These can be:",
            "Friendly travelers with useful",
            "Eccentric shopkeepers",
            "Magical creatures who speak",
            "Prioritize interactive actions"
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
