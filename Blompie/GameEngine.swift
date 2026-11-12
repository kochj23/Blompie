//
//  GameEngine.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import Foundation
import SwiftUI
import WidgetKit

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
    @Published var temperature: Double = 1.3
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
    @Published var lastTokensPerSecond: Double = 0.0
    @Published var randomModelMode: Bool = false
    @Published var actionsUntilModelSwitch: Int = 5

    /// Maximum number of state snapshots to retain for undo history.
    /// When exceeded, the oldest snapshots are dropped to prevent unbounded memory growth.
    private let maxStateHistoryCapacity = 20
    var stateHistory: [GameSnapshot] = []
    private var actionsSinceModelSwitch: Int = 0

    private var conversationHistory: [OllamaMessage] = []
    private let maxConversationHistorySize = 50

    // AI layer. `narrator` is the AI backend manager in the app; tests inject a stub.
    // `scripted` answers whenever the AI is off, unreachable or returns nonsense,
    // so a turn is never lost.
    let narrator: StoryNarrating
    let scripted = ScriptedNarrator()
    /// Who narrated the last turn (AI backend, fallback or scripted).
    @Published private(set) var lastNarrationSource: NarrationSource?
    /// True when the current story was opened by the scripted narrator.
    private(set) var storyIsScripted = false
    private(set) var fallbackTurns = 0

    // Play-history logging (Nova Games DB). Only the app window's engine has a logger;
    // NovaAPIServer sessions and tests create engines without one.
    let playLogger: PlayLogger?
    private(set) var playTurn = 0
    private var playSlot = ""
    private var playStartedFrom = ""
    private var pendingPlayAction: String?
    private var turnUnlocks: [String] = []
    private var sessionUnlocks: [String] = []
    private var lastNarration = ""
    private var playMoments: [[String: Any]] = []
    static let maxPlayMoments = 30

    // Spectator mode ("Watch AI Play"): an adventurer picks the commands. Recorded as an
    // AI-vs-AI session (player "AI vs AI", summary.spectator, summary.matchup); Take Over ends
    // it as `taken_over` and starts a normal session for the player.
    @Published private(set) var isSpectating = false
    @Published var spectatorPaused = false
    /// Seconds between adventurer turns (after the narrator finishes).
    @Published var spectatorDelay: Double = 3
    @Published private(set) var spectatorTurns = 0
    @Published private(set) var adventurerThinking = false
    /// Who chose the last command: the AI backend, or the heuristic (AI away / off).
    @Published private(set) var lastAdventurerSource: NarrationSource?
    var spectatorMaxTurns = Adventurer.maxTurns
    /// True while the open play session is an AI-vs-AI watch session.
    private(set) var watchSession = false
    /// After the watch stopped on its own, the player's next action starts a normal session.
    private var recordOnNextAction = false
    /// Turns where the AI adventurer's reply was unusable and the heuristic substituted.
    private(set) var adventurerFallbacks = 0
    private var spectatorTask: Task<Void, Never>?
    private var adventurerTried: [String: Int] = [:]
    private var adventurerRecent: [String] = []

    init(playLogger: PlayLogger? = nil, narrator: StoryNarrating = AIBackendManager.shared) {
        self.playLogger = playLogger
        self.narrator = narrator
        loadSettings()
        initializeAchievements()
        Task {
            await refreshAvailableModels()
        }
    }

    func refreshAvailableModels() async {
        guard narrator.aiEnabled else {
            if availableModels.isEmpty { availableModels = ["mistral", "llama3.2", "llama3.1", "codellama", "phi"] }
            return
        }
        do {
            let service = OllamaService(baseURL: AIBackendManager.shared.baseURL(for: .ollama))
            let models = try await service.fetchInstalledModels()
            availableModels = models.isEmpty ? ["mistral", "llama3.2", "llama3.1", "codellama", "phi"] : models
        } catch {
            availableModels = ["mistral", "llama3.2", "llama3.1", "codellama", "phi"]
        }
    }

    func setTheme(_ theme: ColorTheme) {
        currentTheme = theme
        saveSettings()
    }

    /// Consolidated settings struct for single JSON write to UserDefaults
    private struct SettingsBundle: Codable {
        var fontSize: Double
        var streamingEnabled: Bool
        var temperature: Double
        var detailLevel: String
        var toneStyle: String
        var autoSaveEnabled: Bool
        var selectedModel: String
        var randomModelMode: Bool
        var actionsUntilModelSwitch: Int
        var theme: ColorTheme
    }

    private static let settingsKey = "BlompieSettingsBundle"

    func saveSettings() {
        let bundle = SettingsBundle(
            fontSize: fontSize,
            streamingEnabled: streamingEnabled,
            temperature: temperature,
            detailLevel: detailLevel.rawValue,
            toneStyle: toneStyle.rawValue,
            autoSaveEnabled: autoSaveEnabled,
            selectedModel: selectedModel,
            randomModelMode: randomModelMode,
            actionsUntilModelSwitch: actionsUntilModelSwitch,
            theme: currentTheme
        )

        if let encoded = try? JSONEncoder().encode(bundle) {
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        }
    }

    private func loadSettings() {
        // Try loading from consolidated JSON bundle first
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let bundle = try? JSONDecoder().decode(SettingsBundle.self, from: data) {
            fontSize = bundle.fontSize > 0 ? bundle.fontSize : 14
            streamingEnabled = bundle.streamingEnabled
            temperature = bundle.temperature > 0 ? bundle.temperature : 1.3
            if let detail = DetailLevel(rawValue: bundle.detailLevel) { detailLevel = detail }
            if let tone = ToneStyle(rawValue: bundle.toneStyle) { toneStyle = tone }
            autoSaveEnabled = bundle.autoSaveEnabled
            selectedModel = bundle.selectedModel
            randomModelMode = bundle.randomModelMode
            actionsUntilModelSwitch = bundle.actionsUntilModelSwitch > 0 ? bundle.actionsUntilModelSwitch : 5
            currentTheme = bundle.theme
            return
        }

        // Legacy fallback: load from individual keys (one-time migration)
        fontSize = UserDefaults.standard.double(forKey: "BlompieFontSize")
        if fontSize == 0 { fontSize = 14 }

        streamingEnabled = UserDefaults.standard.object(forKey: "BlompieStreamingEnabled") as? Bool ?? true
        temperature = UserDefaults.standard.double(forKey: "BlompieTemperature")
        if temperature == 0 { temperature = 1.3 }

        if let detailStr = UserDefaults.standard.string(forKey: "BlompieDetailLevel"),
           let detail = DetailLevel(rawValue: detailStr) {
            detailLevel = detail
        }

        if let toneStr = UserDefaults.standard.string(forKey: "BlompieToneStyle"),
           let tone = ToneStyle(rawValue: toneStr) {
            toneStyle = tone
        }

        autoSaveEnabled = UserDefaults.standard.object(forKey: "BlompieAutoSaveEnabled") as? Bool ?? true
        randomModelMode = UserDefaults.standard.object(forKey: "BlompieRandomModelMode") as? Bool ?? false

        let savedSwitchCount = UserDefaults.standard.integer(forKey: "BlompieActionsUntilModelSwitch")
        if savedSwitchCount > 0 {
            actionsUntilModelSwitch = savedSwitchCount
        }

        if let model = UserDefaults.standard.string(forKey: "BlompieSelectedModel") {
            selectedModel = model
        }

        if let data = UserDefaults.standard.data(forKey: "BlompieColorTheme"),
           let theme = try? JSONDecoder().decode(ColorTheme.self, from: data) {
            currentTheme = theme
        }

        // Migrate to new format
        saveSettings()
    }

    func resetSettings() {
        fontSize = 14
        streamingEnabled = true
        temperature = 1.3
        detailLevel = .normal
        toneStyle = .balanced
        autoSaveEnabled = true
        randomModelMode = false
        actionsUntilModelSwitch = 5
        selectedModel = "mistral"
        currentTheme = ColorTheme.classicGreen
        saveSettings()
    }

    // MARK: - Stats

    func getStats() -> [String: String] {
        return [
            "Total Actions": "\(actionHistory.count)",
            "NPCs Met": "\(metNPCs.count)",
            "Items Collected": "\(inventory.count)",
            "Locations Visited": "\(locationHistory.count)",
            "Achievements": "\(achievements.filter { $0.isUnlocked }.count)/\(achievements.count)",
            "Current Model": selectedModel,
            "Last Token/sec": lastTokensPerSecond > 0 ? String(format: "%.1f", lastTokensPerSecond) : "N/A",
            "Saves": "\(getSaveSlots().count)",
            "Messages": "\(messages.count)"
        ]
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
            // Sync to widget when achievements change
            SharedDataManager.shared.updateFromGameEngine(self)
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
            turnUnlocks.append(achievements[index].title)
            sessionUnlocks.append(achievements[index].title)
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

        if !isSpectating { checkAchievements() }   // the adventurer does not earn the player's trophies
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

        CRITICAL - ACTIONS MUST PROGRESS THE STORY:
        • When a player takes an action, something NEW must happen
        • If they "step through door" → they enter a DIFFERENT location with NEW elements
        • If they "read journal" → they learn SPECIFIC information or trigger an event
        • If they "talk to NPC" → the NPC responds with DIALOGUE and actions
        • NEVER re-describe the same scene with different metaphors
        • PROGRESS IS MANDATORY - each action moves the story forward
        • Avoid excessive metaphors - be concrete, clear, and actionable
        • Make EVENTS happen: discoveries, meetings, changes, revelations

        BAD (stuck): "The door glows. The crystal pulses. You sense mystery."
        GOOD (progress): "You step through. You're now in a forest clearing. An old wizard sits by a fire."

        STYLE: \(detailInstruction) \(toneInstruction) But ALWAYS prioritize story progression over atmosphere.

        CRITICAL FORMAT REQUIREMENT - THIS IS MANDATORY:
        You MUST end every response with action options. Use ANY of these formats:

        FORMAT 1 (PREFERRED): Pipe-separated on one line:
        ACTIONS: action1 | action2 | action3 | action4

        FORMAT 2 (ACCEPTABLE): Numbered list:
        1. Open the door
        2. Talk to the merchant
        3. Pick up the sword
        4. Go north

        FORMAT 3 (ACCEPTABLE): Bulleted list with header:
        What do you do?
        1. Action one
        2. Action two
        3. Action three
        4. Action four

        IMPORTANT: Actions must be SHORT (2-6 words), SPECIFIC, and ACTIONABLE.
        BAD: "Examine the intricate carvings on the ancient door while pondering"
        GOOD: "Examine door carvings"

        Make actions specific and interesting. Prioritize interactive actions over passive examination. MAKE THINGS HAPPEN.
        """
    }

    func startNewGame(spectating: Bool = false) {
        if !spectating { stopSpectating(reason: nil) }
        recordOnNextAction = false
        messages = []
        conversationHistory = []
        currentActions = []
        actionHistory = []
        metNPCs = []
        inventory = []
        locationHistory = []
        stateHistory = []
        storyIsScripted = false
        fallbackTurns = 0
        scripted.reset()

        beginPlaySession(from: spectating ? "watch" : "new", slot: "",
                         start: ["setting": spectating ? "watch" : "new adventure"], watch: spectating)

        addMessage("=== BLOMPIE ===")
        addMessage(narrator.aiEnabled ? "A Text Adventure (AI narrator)" : "A Text Adventure (scripted narrator, AI off)")
        addMessage("")
        addMessage("Initializing game world...")
        addMessage("")

        isLoading = true
        Task {
            await generateInitialScene()
        }
    }

    func performAction(_ action: String) {
        // Save state before action for undo
        saveStateSnapshot()

        if recordOnNextAction && !isSpectating {
            recordOnNextAction = false
            beginPlaySession(from: "after_watch", slot: "", start: ["setting": "after watch"])
        }
        pendingPlayAction = action

        // Track action
        actionHistory.append(action)
        if actionHistory.count > 10 {
            actionHistory.removeFirst()
        }

        // Random model switching
        if randomModelMode {
            actionsSinceModelSwitch += 1
            if actionsSinceModelSwitch >= actionsUntilModelSwitch {
                switchToRandomModel()
                actionsSinceModelSwitch = 0
            }
        }

        addMessage("> \(action)")
        addMessage("")

        isLoading = true   // at once, so a second click (or the spectator loop) waits for this turn
        Task {
            await sendMessageToOllama(action)
        }
    }

    private func switchToRandomModel() {
        guard !availableModels.isEmpty else { return }
        let otherModels = availableModels.filter { $0 != selectedModel }
        if let randomModel = otherModels.randomElement() {
            selectedModel = randomModel
            addMessage("")
            addMessage("🔀 Switched to model: \(randomModel)")
            addMessage("")
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

        // Keep only the most recent snapshots to bound memory usage
        while stateHistory.count > maxStateHistoryCapacity {
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

        await sendToNarrator(action: nil)
        isLoading = false
    }

    private func sendMessageToOllama(_ userMessage: String) async {
        isLoading = true

        conversationHistory.append(OllamaMessage(
            role: "user",
            content: userMessage
        ))

        await sendToNarrator(action: userMessage)
        isLoading = false
    }

    /// Trims conversation history to maxConversationHistorySize.
    /// When exceeded, summarizes the oldest messages into a single system message
    /// to preserve context while reducing token usage.
    private func trimConversationHistory() {
        guard conversationHistory.count > maxConversationHistorySize else { return }

        // Keep the system prompt (first message if it's a system role)
        let systemMessages = conversationHistory.prefix(while: { $0.role == "system" })
        let nonSystemMessages = Array(conversationHistory.dropFirst(systemMessages.count))

        // Summarize the oldest messages that exceed the limit
        let excessCount = nonSystemMessages.count - maxConversationHistorySize
        guard excessCount > 0 else { return }

        let messagesToSummarize = Array(nonSystemMessages.prefix(excessCount))
        let remainingMessages = Array(nonSystemMessages.dropFirst(excessCount))

        // Build a summary of the trimmed messages
        var summaryParts: [String] = []
        for msg in messagesToSummarize {
            let prefix = msg.role == "user" ? "Player" : "Game"
            let truncated = String(msg.content.prefix(100))
            summaryParts.append("\(prefix): \(truncated)")
        }
        let summaryText = "[Earlier conversation summary - \(messagesToSummarize.count) messages condensed]\n" +
                          summaryParts.joined(separator: "\n")

        let summaryMessage = OllamaMessage(role: "system", content: summaryText)

        // Rebuild: system prompt + summary + recent messages
        conversationHistory = Array(systemMessages) + [summaryMessage] + remainingMessages
    }

    /// Narrate the opening (`action == nil`) or one player action. AI first (when
    /// on); any failure or invalid reply falls back to the scripted narrator, so
    /// the turn always completes. Scripted text is shown but never fed back to the model.
    private func sendToNarrator(action: String?) async {
        streamingText = ""
        guard narrator.aiEnabled else {
            applyScripted(action: action, source: .scripted)
            return
        }

        var streamed = ""
        let onChunk: ((String) -> Void)? = streamingEnabled ? { chunk in
            Task { @MainActor in
                guard self.isLoading else { return }   // ignore chunks that arrive after the turn ended
                streamed += chunk
                self.streamingText = streamed
            }
        } : nil

        do {
            let reply = try await narrator.narrate(
                messages: conversationHistory,
                model: selectedModel,
                temperature: temperature,
                onChunk: onChunk
            )
            if let tps = reply.tokensPerSecond { lastTokensPerSecond = tps }

            conversationHistory.append(OllamaMessage(role: "assistant", content: reply.text))
            trimConversationHistory()
            streamingText = ""

            let narrative = parseOllamaResponse(reply.text)
            lastNarrationSource = .ai(reply.backend)
            recordPlayNarration(narrative, failed: false, source: .ai(reply.backend))
            finishTurn()
        } catch {
            streamingText = ""
            print("[GameEngine] AI narration failed, using scripted narrator: \(error.localizedDescription)")
            applyScripted(action: action, source: .fallback)
        }
    }

    /// The scripted narrator answers: the rule-based world when AI is off or the
    /// story began scripted, otherwise a short "narrator away" line that keeps the
    /// current actions so the player can simply try again.
    private func applyScripted(action: String?, source: NarrationSource) {
        let text: String
        if let action {
            text = (source == .scripted || storyIsScripted)
                ? scripted.respond(to: action)
                : scripted.awayLine(keeping: currentActions)
        } else {
            text = scripted.opening()
            storyIsScripted = true
        }
        if source == .fallback {
            fallbackTurns += 1
            addMessage("[scripted narrator: AI unavailable]")
        }
        let narrative = parseOllamaResponse(text)
        lastNarrationSource = source
        recordPlayNarration(narrative, failed: false, source: source)
        finishTurn()
    }

    private func finishTurn() {
        if autoSaveEnabled && !isSpectating {   // never overwrite the player's autosave while watching
            saveGame(toSlot: "autosave")
        }
        // Sync to widget
        SharedDataManager.shared.updateFromGameEngine(self)
    }

    @discardableResult
    private func parseOllamaResponse(_ response: String) -> String {
        let lines = response.components(separatedBy: .newlines)
        var narrativeLines: [String] = []
        var actions: [String] = []

        // System prompt keywords to filter out
        let systemPromptPhrases = [
            "You are the game master",
            "Your role is to:",
            "CRITICAL FORMAT REQUIREMENT",
            "CRITICAL - ACTIONS MUST",
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
            "Prioritize interactive actions",
            "When a player takes an action",
            "PROGRESS IS MANDATORY",
            "NEVER re-describe the same",
            "BAD (stuck):",
            "GOOD (progress):",
            "MAKE THINGS HAPPEN",
            "But ALWAYS prioritize story"
        ]

        var inActionsList = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("ACTIONS:") {
                // Extract actions from pipe-separated format
                let actionsString = trimmed.replacingOccurrences(of: "ACTIONS:", with: "").trimmingCharacters(in: .whitespaces)
                actions = actionsString.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                inActionsList = false
            } else if trimmed.lowercased().contains("possible actions") ||
                      trimmed.lowercased().contains("what do you do") ||
                      trimmed.lowercased().contains("your options") ||
                      trimmed.lowercased().contains("you can:") {
                // Detected action section header
                inActionsList = true
            } else if trimmed.range(of: "^\\d+\\.\\s*\\*\\*", options: .regularExpression) != nil {
                // Parse numbered list with bold actions (e.g., "1. **Action** (description)")
                inActionsList = true
                // Extract text between ** markers
                let components = trimmed.components(separatedBy: "**")
                if components.count >= 3 {
                    let action = components[1].trimmingCharacters(in: .whitespaces)
                    if !action.isEmpty {
                        actions.append(action)
                    }
                }
            } else if trimmed.range(of: "^\\d+\\.", options: .regularExpression) != nil {
                // Parse any numbered list item as potential action
                let withoutNumber = trimmed.replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
                // Remove parenthetical descriptions
                let action = withoutNumber.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? withoutNumber
                // Remove trailing punctuation and descriptions
                let cleanAction = action.components(separatedBy: ":").first?.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) ?? action
                if !cleanAction.isEmpty && cleanAction.count < 80 {
                    actions.append(cleanAction)
                    inActionsList = true
                }
            } else if !trimmed.isEmpty {
                // Filter out system prompt text
                let isSystemPrompt = systemPromptPhrases.contains { phrase in
                    trimmed.contains(phrase)
                }

                // Don't add action list items to narrative
                if !isSystemPrompt && !inActionsList {
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

        // Update current actions (clamped: trimmed, <= 80 chars, de-duplicated, <= 6)
        currentActions = NarrationValidator.sanitizeActions(actions)

        // If no actions were found, provide default exploration actions
        if currentActions.isEmpty {
            currentActions = ["Look around", "Continue", "Go back", "Examine surroundings"]
        }

        // Track NPCs, inventory, locations, and check achievements
        parseAndTrackGameElements(response)
        return narrative
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
        stopSpectating(reason: nil)
        recordOnNextAction = false
        storyIsScripted = false
        scripted.reset()
        beginPlaySession(from: "load", slot: slotName,
                         start: ["slot": slotName, "resumed": true, "messages": state.messages.count])
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

    // MARK: - Play history

    /// New adventure or loaded save: a new play session (the open one ends as `completed`).
    func beginPlaySession(from origin: String, slot: String, start: [String: Any], watch: Bool = false) {
        watchSession = watch
        guard let playLogger else { return }
        playTurn = 0
        playSlot = PlayJSON.clean(slot, max: 64)
        playStartedFrom = origin
        pendingPlayAction = nil
        turnUnlocks = []
        sessionUnlocks = []
        lastNarration = ""
        playMoments = []
        var detail = start
        detail["model"] = PlayJSON.clean(selectedModel, max: 64)
        detail["ai_enabled"] = narrator.aiEnabled
        detail["tone"] = toneStyle.rawValue
        detail["detail"] = detailLevel.rawValue
        if watch { detail["matchup"] = watchMatchup() }
        playLogger.beginSession(start: detail, summary: playSummary(),
                                player: watch ? PlayLogger.watchPlayer : PlayLogger.player)
    }

    /// After the narrator answered (or failed): a `turn` event for a player action, or a `scene` event for the
    /// opening narration. `source` (llm / fallback / scripted) is recorded when given. Never throws, never waits.
    func recordPlayNarration(_ narrative: String, failed: Bool, source: NarrationSource? = nil) {
        defer { turnUnlocks = [] }
        guard let playLogger else { pendingPlayAction = nil; return }
        let excerpt = PlayJSON.clean(narrative, max: 400)
        if !excerpt.isEmpty { lastNarration = excerpt }
        if let action = pendingPlayAction {
            pendingPlayAction = nil
            playTurn += 1
            let act = PlayJSON.clean(action, max: 200)
            var detail: [String: Any] = ["turn": playTurn, "action": act, "narration": excerpt]
            if !turnUnlocks.isEmpty { detail["achievements"] = turnUnlocks }
            if failed { detail["failed"] = true }
            if let source { detail["source"] = source.playValue }
            if !failed {
                playMoments.append(["turn": playTurn, "action": PlayJSON.clean(act, max: 120),
                                    "narration": PlayJSON.clean(excerpt, max: 200)])
                if playMoments.count > Self.maxPlayMoments { playMoments.removeFirst(playMoments.count - Self.maxPlayMoments) }
            }
            playLogger.record(kind: "turn", detail: detail, action: true, summary: playSummary())
        } else if !failed && !excerpt.isEmpty && playTurn == 0 {
            // Opening narration only: a reply that lands after a turn was already recorded is not a new scene.
            var detail: [String: Any] = ["narration": excerpt]
            if let source { detail["source"] = source.playValue }
            if !turnUnlocks.isEmpty { detail["achievements"] = turnUnlocks }
            playLogger.record(kind: "scene", detail: detail, action: false, summary: playSummary())
        }
    }

    /// Self-contained session summary for Nova's reporter. Lists are capped; no paths or personal data.
    func playSummary() -> [String: Any] {
        var s: [String: Any] = [
            "turns": playTurn,
            "started_from": playStartedFrom,
            "model": PlayJSON.clean(selectedModel, max: 64),
            "tone": toneStyle.rawValue,
            "detail": detailLevel.rawValue,
            "achievements_unlocked": PlayJSON.cap(sessionUnlocks, count: 20),
            "achievements_total": achievements.filter(\.isUnlocked).count,
            "places": PlayJSON.cap(locationHistory, count: 40),
            "items": PlayJSON.cap(inventory, count: 40),
            "npcs": PlayJSON.cap(metNPCs, count: 40),
            "places_count": locationHistory.count,
            "items_count": inventory.count,
            "npcs_count": metNPCs.count,
            "moments": playMoments,
            "fallbacks": fallbackTurns,
        ]
        if !playSlot.isEmpty { s["slot"] = playSlot }
        if !lastNarration.isEmpty { s["last_scene"] = lastNarration }
        if watchSession {
            s["spectator"] = true
            s["matchup"] = watchMatchup()
            s["fallbacks"] = ["adventurer": adventurerFallbacks, "narrator": fallbackTurns]
        }
        return s
    }

    /// `summary.matchup` of a watch session: the adventurer and the narrator sides.
    func watchMatchup() -> [String: Any] {
        let backend = (narrator as? AIBackendManager)?.activeBackend
        let model = PlayJSON.clean(selectedModel, max: 64)
        func side(_ name: String, engineLabel: String) -> [String: Any] {
            guard narrator.aiEnabled else {
                return ["side": name, "kind": "engine", "backend": NSNull(), "model": NSNull(), "label": engineLabel]
            }
            return ["side": name, "kind": "model", "backend": backend?.rawValue ?? NSNull(), "model": model,
                    "label": PlayJSON.clean([backend?.shortName, model].compactMap { $0 }.joined(separator: " "), max: 64)]
        }
        return ["sides": [side("adventurer", engineLabel: "Heuristic adventurer"),
                          side("narrator", engineLabel: "Scripted narrator")]]
    }

    // MARK: - Spectator mode

    /// Start a new adventure that the adventurer plays on its own.
    func startSpectating() {
        spectatorTask?.cancel()
        startNewGame(spectating: true)
        isSpectating = true
        spectatorPaused = false
        spectatorTurns = 0
        adventurerTried = [:]
        adventurerRecent = []
        adventurerFallbacks = 0
        lastAdventurerSource = nil
        addMessage("[SPECTATING: the AI adventurer is playing. Pick an action or Take Over to play.]")
        addMessage("")
        spectatorTask = Task { await runSpectator() }
    }

    /// Hand the controls back to the player: the watch session ends as `taken_over` and a
    /// normal session starts from here.
    func takeOver() {
        guard isSpectating else { return }
        stopSpectating(reason: "you took over", outcome: "taken_over")
        recordOnNextAction = false
        beginPlaySession(from: "takeover", slot: "", start: ["setting": "take over"])
    }

    /// Stop the adventurer. `outcome` ends the watch session; nil leaves it to the next session start.
    func stopSpectating(reason: String?, outcome: String? = nil) {
        spectatorTask?.cancel()
        spectatorTask = nil
        guard isSpectating else { return }
        isSpectating = false
        spectatorPaused = false
        adventurerThinking = false
        if let outcome, watchSession {
            playLogger?.endSession(outcome: outcome, summary: playSummary())
            watchSession = false
            recordOnNextAction = true
        }
        if let reason {
            addMessage("[Spectating stopped: \(reason). You have the controls.]")
            addMessage("")
        }
    }

    /// Why spectating must stop now (and the watch session's outcome), or nil:
    /// story ended, turn cap, or a command loop.
    func spectatorStopReason() -> (reason: String, outcome: String)? {
        if messages.suffix(8).contains(where: { Adventurer.storyEnded($0.text) }) { return ("the story ended", "completed") }
        if spectatorTurns >= spectatorMaxTurns { return ("reached the \(spectatorMaxTurns)-turn limit", "turn_limit") }
        if Adventurer.isLooping(adventurerRecent) { return ("the adventurer is going in circles", "stalled") }
        return nil
    }

    private func runSpectator() async {
        while isSpectating && !Task.isCancelled {
            var waited = 0.0
            while isSpectating && (isLoading || spectatorPaused || currentActions.isEmpty || waited < spectatorDelay) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !isLoading && !spectatorPaused { waited += 0.1 }
            }
            guard isSpectating && !Task.isCancelled else { return }
            if let stop = spectatorStopReason() { stopSpectating(reason: stop.reason, outcome: stop.outcome); return }
            let command = await nextAdventurerCommand()
            guard isSpectating && !Task.isCancelled && !spectatorPaused && !isLoading else { continue }
            spectatorTurns += 1
            adventurerTried[Adventurer.key(command, in: currentActions), default: 0] += 1
            adventurerRecent = Array((adventurerRecent + [command.lowercased()]).suffix(Adventurer.loopWindow))
            performAction(command)
        }
    }

    /// AI adventurer through the narrator's backend; heuristic pick when AI is off, fails,
    /// replies with nothing usable, or keeps repeating itself.
    private func nextAdventurerCommand() async -> String {
        if narrator.aiEnabled {
            adventurerThinking = true
            defer { adventurerThinking = false }
            let prompt = Adventurer.prompt(story: messages.suffix(12).map(\.text), actions: currentActions,
                                           recent: adventurerRecent)
            if let reply = try? await narrator.narrate(messages: prompt, model: selectedModel,
                                                        temperature: 0.8, onChunk: nil),
               let command = Adventurer.validate(reply.text),
               adventurerRecent.suffix(4).filter({ $0 == command.lowercased() }).count < 2 {
                lastAdventurerSource = .ai(reply.backend)
                return command
            }
        }
        lastAdventurerSource = narrator.aiEnabled ? .fallback : .scripted
        if narrator.aiEnabled { adventurerFallbacks += 1 }
        return Adventurer.pick(from: currentActions, tried: adventurerTried)
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
