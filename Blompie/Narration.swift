//
//  Narration.swift
//  Blompie
//
//  Game-level AI contract: where a turn's narration came from, the sanity
//  check every model reply passes before it touches game state, and the
//  rule-based scripted narrator that keeps Blompie playable with the AI
//  switched off or unreachable. A failed AI call never loses a turn.
//
//  Copyright © 2026 Jordan Koch. All rights reserved.
//

import Foundation

// MARK: - Source label

/// Who narrated a turn.
enum NarrationSource: Equatable, Sendable {
    /// A model answered through this backend.
    case ai(LLMBackendType)
    /// AI is on but no backend answered (or the reply failed validation):
    /// the scripted narrator filled in.
    case fallback
    /// AI is switched off: the scripted narrator runs the game.
    case scripted

    /// Value written to the Nova Games DB `detail.source` field.
    var playValue: String {
        switch self {
        case .ai: return "llm"
        case .fallback: return "fallback"
        case .scripted: return "scripted"
        }
    }

    /// Short label shown in the status badge.
    var label: String {
        switch self {
        case .ai(let backend): return "AI via \(backend.shortName)"
        case .fallback: return "Scripted (AI away)"
        case .scripted: return "Scripted (AI off)"
        }
    }

    var isAI: Bool {
        if case .ai = self { return true }
        return false
    }
}

// MARK: - Output validation

/// Sanity checks for model output. Anything that fails is discarded and the
/// scripted narrator answers instead, so nonsense never reaches game state.
enum NarrationValidator {
    /// Longest narration accepted (characters). Longer replies are clipped.
    static let maxNarrationChars = 6_000
    /// Fewest letters a reply needs to count as narration.
    static let minLetters = 10
    /// Most suggested actions kept per turn.
    static let maxActions = 6
    /// Longest suggested action kept (characters).
    static let maxActionChars = 80

    /// Phrases from the system prompt. A reply that repeats several of them is
    /// the model echoing its instructions, not narrating.
    static let promptEchoMarkers = [
        "You are the game master",
        "Your role is to:",
        "CRITICAL FORMAT REQUIREMENT",
        "CRITICAL - ACTIONS MUST",
        "PROGRESS IS MANDATORY",
        "FORMAT 1 (PREFERRED)",
        "FORMAT 2 (ACCEPTABLE)",
        "IMPORTANT: Balance exploration",
        "MAKE THINGS HAPPEN"
    ]

    /// Clean a raw model reply. Returns nil when it must be rejected.
    static func clean(_ raw: String) -> String? {
        var text = raw

        // Reasoning models: drop <think>...</think>. An unclosed block is all reasoning.
        while text.utf8.contains(UInt8(ascii: "<")),
              let open = text.range(of: "<think>", options: [.caseInsensitive, .literal]) {
            if let close = text.range(of: "</think>", options: [.caseInsensitive, .literal], range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        // Chat-template tokens such as <|im_start|>.
        if text.contains("<|") {
            text = text.replacingOccurrences(of: "<\\|[^|>]{0,40}\\|>", with: "", options: .regularExpression)
        }
        // Control and bidi characters (keep newlines and tabs). Fast path: most
        // replies contain none, so only rebuild the string when one is present.
        if text.unicodeScalars.contains(where: isStrippable) {
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: text.unicodeScalars.lazy.filter { !isStrippable($0) })
            text = String(kept)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Enough letters to be narration (stop counting once the minimum is reached).
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if letters >= minLetters { break }
        }
        guard letters >= minLetters else { return nil }
        let echoes = promptEchoMarkers.filter { text.contains($0) }.count
        guard echoes < 2 else { return nil }

        if text.utf8.count > maxNarrationChars, text.count > maxNarrationChars {
            let clipped = String(text.prefix(maxNarrationChars))
            if let cut = clipped.lastIndex(where: { $0 == "\n" || $0 == " " }) {
                text = String(clipped[..<cut])
            } else {
                text = clipped
            }
        }
        return text
    }

    private static func isStrippable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0x0A || v == 0x09 { return false }                       // newline, tab
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }          // C0/C1 controls
        return (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
            || (0x2060...0x206F).contains(v) || v == 0xFEFF                // zero-width / bidi
    }

    /// Clamp parsed actions: trimmed, markdown stripped, 1...80 chars,
    /// de-duplicated (case-insensitive), at most `maxActions`.
    static func sanitizeActions(_ actions: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in actions {
            let a = raw
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !a.isEmpty, a.count <= maxActionChars else { continue }
            guard seen.insert(a.lowercased()).inserted else { continue }
            out.append(a)
            if out.count == maxActions { break }
        }
        return out
    }
}

// MARK: - Scripted narrator

/// A small rule-based world so Blompie is fully playable with no model at all.
/// Deterministic (no randomness), so tests and replays are stable. Replies use
/// the same `ACTIONS: a | b` format as the model, so the normal parser,
/// tracking and achievements work unchanged.
final class ScriptedNarrator {

    struct Place {
        let id: String
        let name: String
        let arrival: String       // phrase that starts with "You arrive at" / "You enter" ...
        let detail: String
        let exits: [(direction: String, to: String)]
        let item: String?
        let npc: (title: String, name: String, lines: [String])?
    }

    /// Lines used when AI is on but no backend answered mid-story (borrowed
    /// from the web Blompie relay fallback).
    static let awayLines = [
        "A thick, slightly sarcastic fog rolls in. For a moment you can't see your own boots, but you can hear them, and they sound unimpressed.",
        "Somewhere nearby a kettle whistles, though there is no kettle and nobody is making tea. The world seems to be thinking very hard about what happens next.",
        "A small sign appears at your feet. It reads: 'Narrator on a short break. Please continue adventuring responsibly.' It disappears with a polite pop.",
        "The wind changes direction twice, apologises, and settles down. The path ahead looks exactly as mysterious as before.",
        "A passing snail gives you a long look, as if it knows something. It does not share."
    ]

    static let places: [Place] = [
        Place(id: "meadow", name: "the Cinnamon Meadow",
              arrival: "You find yourself in the Cinnamon Meadow.",
              detail: "It smells faintly of cinnamon and old maps. A crooked signpost points in three directions at once, and somewhere a bell rings without a bell.",
              exits: [("north", "tower"), ("east", "market"), ("west", "woods")],
              item: "brass compass", npc: nil),
        Place(id: "tower", name: "the Bell Tower",
              arrival: "You arrive at the Bell Tower.",
              detail: "Ivy climbs the stones in tidy spirals. A spiral stair leads up into the belfry.",
              exits: [("up", "belfry"), ("south", "meadow")],
              item: nil,
              npc: ("elder", "Pim", [
                "Elder Pim squints at you. \"The bell lost its voice. Find the clapper and the meadow will sing again.\"",
                "Elder Pim taps the wall. \"Up the stair, child. Mind the third step; it bites.\"",
                "Elder Pim smiles. \"Every road here loops back to the meadow. That is the point of roads.\""
              ])),
        Place(id: "belfry", name: "the Belfry",
              arrival: "You enter the Belfry.",
              detail: "A great silent bell hangs above you. Pigeons hold a committee meeting in the rafters.",
              exits: [("down", "tower")],
              item: "silver bell clapper", npc: nil),
        Place(id: "market", name: "the Upside-Down Market",
              arrival: "You arrive at the Upside-Down Market.",
              detail: "Stalls hang from the sky by ropes and the awnings point at the ground. Everything is for sale, including the weather.",
              exits: [("north", "library"), ("west", "meadow")],
              item: nil,
              npc: ("merchant", "Quillby", [
                "The merchant Quillby bows. \"Trade me anything shiny and I will tell you a secret about the woods.\"",
                "The merchant Quillby whispers, \"The pond keeps a key. The key keeps a door. The door keeps its opinions.\"",
                "The merchant Quillby counts your coins twice and gives you three back. \"Interest,\" he says."
              ])),
        Place(id: "library", name: "the Lopsided Library",
              arrival: "You enter the Lopsided Library.",
              detail: "Shelves lean together like gossiping friends. A reading lamp follows you politely.",
              exits: [("south", "market")],
              item: "map of nowhere",
              npc: ("gnome", "Fennick", [
                "The gnome Fennick peers over his spectacles. \"Shh. The books are sleeping. Mostly.\"",
                "The gnome Fennick hands you a bookmark. \"For later. You will know when.\"",
                "The gnome Fennick sighs. \"The map of nowhere is very accurate. That is the problem.\""
              ])),
        Place(id: "woods", name: "the Whispering Woods",
              arrival: "You find yourself in the Whispering Woods.",
              detail: "The trees whisper to each other and stop whenever you look at them.",
              exits: [("north", "pond"), ("east", "meadow")],
              item: nil,
              npc: ("sprite", "Tansy", [
                "The sprite Tansy giggles and spins around your head. \"Lost? Wonderful! Lost is where the good stuff is.\"",
                "The sprite Tansy points north. \"The pond is shy. Be shy back and it will like you.\"",
                "The sprite Tansy steals your shoelace, ties a bow in it and gives it back."
              ])),
        Place(id: "pond", name: "the Mirror Pond",
              arrival: "You arrive at the Mirror Pond.",
              detail: "The water shows the sky from yesterday. Something glints beneath the surface.",
              exits: [("south", "woods")],
              item: "glass key", npc: nil)
    ]

    private(set) var location = "meadow"
    private(set) var taken: [String] = []
    private var talks: [String: Int] = [:]
    private var awayCount = 0
    private var idleCount = 0

    init() {}

    /// Start over at the meadow.
    func reset() {
        location = "meadow"
        taken = []
        talks = [:]
        awayCount = 0
        idleCount = 0
    }

    var currentPlace: Place {
        Self.places.first { $0.id == location } ?? Self.places[0]
    }

    /// Opening scene for a new adventure.
    func opening() -> String {
        reset()
        let p = currentPlace
        return "You wake up in a meadow. \(p.detail) This is Blompie.\n\(actionsLine(for: p))"
    }

    /// Mid-story filler when the AI is on but did not answer. Keeps the previous
    /// actions so the player can simply try again.
    func awayLine(keeping actions: [String]) -> String {
        let line = Self.awayLines[awayCount % Self.awayLines.count]
        awayCount += 1
        let kept = NarrationValidator.sanitizeActions(actions)
        return "\(line)\nACTIONS: \((kept.isEmpty ? ["Look around", "Continue"] : kept).joined(separator: " | "))"
    }

    /// Rule-based reply to a player action.
    func respond(to action: String) -> String {
        let a = action.lowercased()
        let place = currentPlace

        // Taking the local item.
        if ["take", "pick", "grab", "get", "collect"].contains(where: { Self.containsWord(a, $0) }) {
            if let item = place.item, !taken.contains(item) {
                taken.append(item)
                return "You pick up the \(item). It feels important in a way you can't explain.\n\(actionsLine(for: place))"
            }
            return "You pat the ground hopefully, but there is nothing here worth taking.\n\(actionsLine(for: place))"
        }

        // Talking or trading with the local character.
        if ["talk", "ask", "greet", "speak", "chat", "trade", "give"].contains(where: { Self.containsWord(a, $0) }) {
            if let npc = place.npc {
                let n = talks[npc.name, default: 0]
                talks[npc.name] = n + 1
                var line = npc.lines[n % npc.lines.count]
                if Self.containsWord(a, "trade") || Self.containsWord(a, "give") {
                    line = taken.isEmpty
                        ? "\(line) You have nothing to trade yet."
                        : "\(line) You trade away nothing important and receive a lucky button."
                }
                return "\(line)\n\(actionsLine(for: place))"
            }
            return "You talk to the air. The air, to its credit, listens.\n\(actionsLine(for: place))"
        }

        // Movement: a direction word or a destination's name.
        if let exit = place.exits.first(where: { exit in
            let dest = Self.places.first { $0.id == exit.to }
            let destWord = dest?.name.lowercased().replacingOccurrences(of: "the ", with: "") ?? "\u{0}"
            return Self.containsWord(a, exit.direction) || a.contains(destWord)
                || (exit.direction == "up" && a.contains("climb")) || (exit.direction == "down" && a.contains("descend"))
        }), let dest = Self.places.first(where: { $0.id == exit.to }) {
            location = dest.id
            idleCount = 0
            return describe(dest, arriving: true)
        }

        // Looking, examining, reading.
        if ["look", "examine", "read", "search", "inspect", "observe"].contains(where: { Self.containsWord(a, $0) }) {
            return describe(place, arriving: false)
        }

        // Anything else: a gentle nudge that still moves time along.
        let line = Self.awayLines[idleCount % Self.awayLines.count]
        idleCount += 1
        return "\(line)\n\(actionsLine(for: place))"
    }

    private func describe(_ place: Place, arriving: Bool) -> String {
        var parts = [arriving ? place.arrival : "You look around \(place.name)."]
        parts.append(place.detail)
        if let npc = place.npc { parts.append("\(npc.title.capitalized) \(npc.name) is here.") }
        if let item = place.item, !taken.contains(item) { parts.append("You notice a \(item).") }
        let ways = place.exits.map { $0.direction }.joined(separator: ", ")
        parts.append("Paths lead \(ways).")
        return parts.joined(separator: " ") + "\n" + actionsLine(for: place)
    }

    /// Suggested actions for a place, in the model's `ACTIONS:` format.
    func actions(for place: Place) -> [String] {
        var list: [String] = []
        if let item = place.item, !taken.contains(item) { list.append("Take the \(item)") }
        if let npc = place.npc { list.append("Talk to \(npc.name)") }
        list += place.exits.map { "Go \($0.direction)" }
        list.append("Look around")
        return Array(list.prefix(NarrationValidator.maxActions))
    }

    private func actionsLine(for place: Place) -> String {
        "ACTIONS: " + actions(for: place).joined(separator: " | ")
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }
}

// MARK: - Adventurer (spectator mode)

/// Chooses the player's next command in spectator mode ("Watch AI Play"). The AI
/// adventurer goes through the same `StoryNarrating` backend as the narrator;
/// when AI is off, a call fails or the reply is unusable, `pick` chooses from the
/// suggested actions so the game never stalls. Every command is validated like
/// player input before it reaches the engine.
enum Adventurer {
    /// Spectating stops after this many adventurer turns, so it never runs forever.
    static let maxTurns = 60
    /// Loop detection: the last `loopWindow` commands have at most `loopDistinct` distinct values.
    static let loopWindow = 8
    static let loopDistinct = 2

    static let systemPrompt = """
    You are the PLAYER of a text adventure, not the narrator. Read the story so far and choose the single next \
    command that moves the adventure forward: explore new places, talk to characters, pick up useful items, \
    solve puzzles. Do not repeat your recent commands.
    Reply with exactly one line: COMMAND: <a short command, 2-6 words>
    """

    /// Prompt for the AI adventurer: recent story, suggested actions, its own recent commands.
    static func prompt(story: [String], actions: [String], recent: [String]) -> [OllamaMessage] {
        let scene = story.map { String($0.prefix(400)) }.filter { !$0.isEmpty }.joined(separator: "\n")
        var user = "Story so far:\n\(scene)\n\nSuggested actions: \(actions.joined(separator: " | "))"
        if !recent.isEmpty { user += "\nYour recent commands: \(recent.suffix(5).joined(separator: " | "))" }
        user += "\nWhat is your next command?"
        return [OllamaMessage(role: "system", content: systemPrompt), OllamaMessage(role: "user", content: user)]
    }

    /// Validate a command like player input: the `COMMAND:` line (or first line), markdown and control /
    /// format characters stripped, needs a letter, 1...80 chars. nil = rejected.
    static func validate(_ raw: String) -> String? {
        let lines = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var line = lines.first { $0.uppercased().hasPrefix("COMMAND:") } ?? lines.first ?? ""
        if line.uppercased().hasPrefix("COMMAND:") { line = String(line.dropFirst(8)) }
        line = String(String.UnicodeScalarView(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: ">\"'.").union(.whitespaces))
        guard line.contains(where: \.isLetter) else { return nil }
        return NarrationValidator.sanitizeActions([line]).first
    }

    /// Key for "tried" counts: the command within its set of suggested actions (a stand-in for
    /// the current scene), so each scene's exits are tried in turn and the world gets explored.
    static func key(_ action: String, in actions: [String]) -> String {
        action.lowercased() + "@" + actions.map { $0.lowercased() }.sorted().joined(separator: "|")
    }

    /// Heuristic adventurer: the action least tried in this scene, preferring take > talk > move > other > look.
    static func pick(from actions: [String], tried: [String: Int]) -> String {
        func rank(_ action: String) -> Int {
            let a = action.lowercased()
            if ["take", "pick", "grab", "get "].contains(where: { a.hasPrefix($0) }) { return 0 }
            if ["talk", "ask", "trade", "greet"].contains(where: { a.hasPrefix($0) }) { return 1 }
            if ["go ", "enter", "climb", "follow", "open"].contains(where: { a.hasPrefix($0) }) { return 2 }
            if ["look", "examine"].contains(where: { a.hasPrefix($0) }) { return 4 }
            return 3
        }
        let options = actions.isEmpty ? ["Look around"] : actions
        return options.enumerated().min { x, y in
            (tried[key(x.element, in: options), default: 0], rank(x.element), x.offset)
                < (tried[key(y.element, in: options), default: 0], rank(y.element), y.offset)
        }?.element ?? "Look around"
    }

    /// True when the adventurer keeps issuing the same one or two commands.
    static func isLooping(_ recent: [String]) -> Bool {
        recent.count >= loopWindow && Set(recent.suffix(loopWindow)).count <= loopDistinct
    }

    /// True when the narration says the story is over.
    static func storyEnded(_ text: String) -> Bool {
        text.contains("THE END") || text.lowercased().contains("game over")
    }
}
