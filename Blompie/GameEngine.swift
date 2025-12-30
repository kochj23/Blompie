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

struct GameSnapshot: Codable {
    let messages: [GameMessage]
    let conversationHistory: [OllamaMessage]
    let currentActions: [String]
}

struct Achievement: Identifiable, Codable {
    let id: String
    let title: String
    let description: String
    var isUnlocked: Bool
    let unlockDate: Date?
}

@MainActor
class GameEngine: ObservableObject {
    @Published var messages: [GameMessage] = []
    @Published var currentActions: [String] = []
    @Published var isLoading: Bool = false
    @Published var streamingText: String = ""
    @Published var selectedModel: String = "mistral"
    @Published var availableModels: [String] = []
    @Published var currentTheme: ColorTheme = ColorTheme.classicGreen

    // Settings
    @Published var fontSize: Double = 14
    @Published var streamingEnabled: Bool = true
    @Published var temperature: Double = 0.7
    @Published var detailLevel: DetailLevel = .normal
    @Published var toneStyle: ToneStyle = .balanced
    @Published var autoSaveEnabled: Bool = true

    // Gameplay tracking
    @Published var actionHistory: [String] = []
    @Published var metNPCs: [String] = []
    @Published var inventory: [String] = []
    @Published var locationHistory: [String] = []
    @Published var achievements: [Achievement] = []
    @Published var showSidebar: Bool = false

    var stateHistory: [GameSnapshot] = []

    private var conversationHistory: [OllamaMessage] = []
    private let ollamaService = OllamaService()

    init() {
        loadSettings()
        initializeAchievements()
        Task {
            await refreshAvailableModels()
        }
    }

    func refreshAvailableModels() async {
        do {
            let models = try await ollamaService.fetchInstalledModels()
            availableModels = models.isEmpty ? ["mistral", "llama3.2", "llama3.1", "codellama", "phi"] : models
        } catch {
            availableModels = ["mistral", "llama3.2", "llama3.1", "codellama", "phi"]
        }
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

    // MARK: - Achievements

    private func initializeAchievements() {
        achievements = [
            Achievement(id: "first_step", title: "First Steps", description: "Take your first action", isUnlocked: false, unlockDate: nil),
            Achievement(id: "explorer", title: "Explorer", description: "Visit 5 different locations", isUnlocked: false, unlockDate: nil),
            Achievement(id: "world_traveler", title: "World Traveler", description: "Visit 20 different locations", isUnlocked: false, unlockDate: nil),
            Achievement(id: "social", title: "Social Butterfly", description: "Meet 5 NPCs", isUnlocked: false, unlockDate: nil),
            Achievement(id: "diplomat", title: "Diplomat", description: "Meet 15 NPCs", isUnlocked: false, unlockDate: nil),
            Achievement(id: "collector", title: "Collector", description: "Acquire 5 items", isUnlocked: false, unlockDate: nil),
            Achievement(id: "hoarder", title: "Hoarder", description: "Acquire 15 items", isUnlocked: false, unlockDate: nil),
            Achievement(id: "conversationalist", title: "Conversationalist", description: "Take 50 actions", isUnlocked: false, unlockDate: nil),
            Achievement(id: "veteran", title: "Veteran Adventurer", description: "Take 200 actions", isUnlocked: false, unlockDate: nil),
            Achievement(id: "trader", title: "Trader", description: "Complete 5 trades", isUnlocked: false, unlockDate: nil),
        ]
        loadAchievements()
    }

    private func checkAchievements() {
        var changed = false

        // First action
        if !achievements[0].isUnlocked && actionHistory.count >= 1 {
            unlockAchievement(id: "first_step")
            changed = true
        }

        // Location achievements
        if !achievements[1].isUnlocked && locationHistory.count >= 5 {
            unlockAchievement(id: "explorer")
            changed = true
        }
        if !achievements[2].isUnlocked && locationHistory.count >= 20 {
            unlockAchievement(id: "world_traveler")
            changed = true
        }

        // NPC achievements
        if !achievements[3].isUnlocked && metNPCs.count >= 5 {
            unlockAchievement(id: "social")
            changed = true
        }
        if !achievements[4].isUnlocked && metNPCs.count >= 15 {
            unlockAchievement(id: "diplomat")
            changed = true
        }

        // Inventory achievements
        if !achievements[5].isUnlocked && inventory.count >= 5 {
            unlockAchievement(id: "collector")
            changed = true
        }
        if !achievements[6].isUnlocked && inventory.count >= 15 {
            unlockAchievement(id: "hoarder")
            changed = true
        }

        // Action count achievements
        let totalActions = actionHistory.count
        if !achievements[7].isUnlocked && totalActions >= 50 {
            unlockAchievement(id: "conversationalist")
            changed = true
        }
        if !achievements[8].isUnlocked && totalActions >= 200 {
            unlockAchievement(id: "veteran")
            changed = true
        }

        if changed {
            saveAchievements()
        }
    }

    private func unlockAchievement(id: String) {
        if let index = achievements.firstIndex(where: { $0.id == id }) {
            achievements[index] = Achievement(
                id: achievements[index].id,
                title: achievements[index].title,
                description: achievements[index].description,
                isUnlocked: true,
                unlockDate: Date()
            )
            addMessage("")
            addMessage("🏆 Achievement Unlocked: \(achievements[index].title)")
            addMessage("")
        }
    }

    private func saveAchievements() {
        if let encoded = try? JSONEncoder().encode(achievements) {
            UserDefaults.standard.set(encoded, forKey: "BlompieAchievements")
        }
    }

    private func loadAchievements() {
        guard let data = UserDefaults.standard.data(forKey: "BlompieAchievements"),
              let saved = try? JSONDecoder().decode([Achievement].self, from: data) else {
            return
        }
        achievements = saved
    }

    // MARK: - Parsing & Tracking

    private func parseAndTrackGameElements(_ response: String) {
        let lowercased = response.lowercased()

        // Track NPCs (look for character names and interactions)
        let npcIndicators = ["meets", "encounter", "greet", "merchant", "traveler", "guide", "sprite", "elder", "adventurer", "wizard", "gnome", "shopkeeper"]
        for indicator in npcIndicators {
            if lowercased.contains(indicator) {
                // Extract potential NPC name from context
                let words = response.components(separatedBy: .whitespaces)
                for (index, word) in words.enumerated() {
                    if word.lowercased() == indicator && index + 1 < words.count {
                        let potentialName = words[index + 1].trimmingCharacters(in: .punctuationCharacters)
                        if potentialName.first?.isUppercase == true && !metNPCs.contains(potentialName) {
                            metNPCs.append(potentialName)
                        }
                    }
                }
            }
        }

        // Track inventory (look for "you pick up", "you take", "you receive")
        let inventoryPhrases = ["pick up", "take the", "receive", "acquire", "find a", "grab"]
        for phrase in inventoryPhrases {
            if lowercased.contains(phrase) {
                if let range = lowercased.range(of: phrase) {
                    let afterPhrase = String(response[range.upperBound...])
                    let words = afterPhrase.components(separatedBy: .whitespaces).prefix(3)
                    let item = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                    if !item.isEmpty && !inventory.contains(item) {
                        inventory.append(item)
                    }
                }
            }
        }

        // Track locations (look for "you enter", "you arrive", "you're in")
        let locationPhrases = ["enter", "arrive at", "you're in", "standing in", "you find yourself"]
        for phrase in locationPhrases {
            if lowercased.contains(phrase) {
                if let range = lowercased.range(of: phrase) {
                    let afterPhrase = String(response[range.upperBound...])
                    let words = afterPhrase.components(separatedBy: .whitespaces).prefix(4)
                    let location = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                    if !location.isEmpty && !locationHistory.contains(location) {
                        locationHistory.append(location)
                    }
                }
            }
        }

        checkAchievements()
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
        actionHistory = []
        metNPCs = []
        inventory = []
        locationHistory = []
        stateHistory = []

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
        // Save state before action for undo
        saveStateSnapshot()

        // Track action
        actionHistory.append(action)
        if actionHistory.count > 10 {
            actionHistory.removeFirst()
        }

        addMessage("> \(action)")
        addMessage("")

        Task {
            await sendMessageToOllama(action)
        }
    }

    func undoLastAction() {
        guard !stateHistory.isEmpty else { return }

        let snapshot = stateHistory.removeLast()
        messages = snapshot.messages
        conversationHistory = snapshot.conversationHistory
        currentActions = snapshot.currentActions

        if !actionHistory.isEmpty {
            actionHistory.removeLast()
        }
    }

    private func saveStateSnapshot() {
        let snapshot = GameSnapshot(
            messages: messages,
            conversationHistory: conversationHistory,
            currentActions: currentActions
        )
        stateHistory.append(snapshot)

        // Keep last 20 snapshots
        if stateHistory.count > 20 {
            stateHistory.removeFirst()
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

        // Track NPCs, inventory, locations, and check achievements
        parseAndTrackGameElements(response)
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
