# Blompie v1.1.0

**AI-Powered Text Adventure Game - Every playthrough is unique**

Classic text adventure meets modern AI. Explore infinite procedurally-generated worlds where the AI dungeon master creates your story in real-time.

---

## What is Blompie?

Blompie is a text-based adventure game powered by local AI (Ollama/MLX). Like classic games Zork and Colossal Cave Adventure, you explore worlds through text commands—but with AI, every playthrough is completely unique. The AI acts as your dungeon master, creating characters, locations, and plot twists on the fly based on your actions.

**What Makes Blompie Special:**
- **Infinite Replayability**: AI generates new adventures every time
- **True Freedom**: Do literally anything—AI adapts to your choices
- **Local AI**: Runs on your Mac, no internet required
- **Save Anywhere**: Multiple save slots with auto-save
- **Retro Aesthetic**: Classic terminal UI with modern design
- **AI-Generated Imagery**: Optional scene illustrations

**Perfect For:**
- **Text Adventure Fans**: Modern take on classic IF
- **Creative Players**: AI adapts to any play style
- **Offline Gaming**: No internet required with local AI
- **Story Lovers**: Unique narratives every playthrough

---

## Gameplay

### How to Play

**You Are The Hero**: Type what you want to do, and the AI responds with what happens.

**Example Session:**
```
> You wake up in a dimly lit tavern. The smell of ale and smoke fills the air.
> What do you do?

look around

> You see a hooded figure in the corner, a barkeep polishing glasses,
> and a notice board with various quests. Stairs lead up to rooms.

talk to hooded figure

> The figure looks up, revealing a scarred face. "You looking for work?
> The mayor needs someone brave—or foolish. Talk to her at the town hall."

go to town hall

> You step outside into a bustling medieval town square. Children play,
> merchants hawk wares. The grand town hall looms ahead with marble columns.
```

**The AI Creates:**
- Characters with personalities and motivations
- Locations with rich descriptions
- Plotlines that respond to your actions
- Consequences for your choices
- Mysteries and secrets to uncover

### Game Features

**Core Gameplay:**
- **Infinite Adventures**: Every game is completely different
- **True Open World**: Go anywhere, do anything
- **Character Interactions**: Deep NPCs with memories
- **Inventory System**: Pick up and use items
- **Location Tracking**: Map of places you've visited
- **Achievement System**: Unlock achievements for actions
- **Multiple Endings**: Your choices determine the outcome

**AI Dungeon Master:**
- **Adaptive Storytelling**: AI responds to your play style
- **Dynamic NPCs**: Characters remember your actions
- **Procedural Quests**: Unique missions each playthrough
- **Context Awareness**: AI remembers previous events
- **Multiple Tones**: Choose story tone (serious, balanced, whimsical)
- **Detail Control**: Brief, normal, or detailed descriptions

**Game Progression:**
- **Save System**: Multiple save slots (8 slots)
- **Auto-Save**: Automatic saves every few actions
- **Load Anytime**: Resume from any save point
- **Action History**: Review your entire playthrough
- **Undo System**: Rewind bad decisions
- **Achievement Tracking**: Progress towards 30+ achievements

### Visual Features

**Classic Terminal Aesthetic:**
- **Retro UI**: Green-on-black terminal (customizable themes)
- **Monospaced Font**: Authentic typewriter feel
- **Smooth Scrolling**: Modern smoothness with retro look
- **Glassmorphic Effects**: Modern visual polish
- **Color Themes**: Classic green, amber, blue, matrix

**AI-Generated Imagery (Optional):**
- Generate scene illustrations
- Character portraits
- Item visualizations
- Location artwork
- Save images to gallery

**Customization:**
- **Font Size**: Adjustable (⌘+ / ⌘-)
- **Color Theme**: 5+ retro terminal themes
- **Detail Level**: Control description length
- **Tone**: Serious, balanced, or whimsical
- **Streaming**: See AI write in real-time or instant

---

## What's New in v1.1.0 (January 2026)

### 🚀 MLX Backend Support
**Apple Silicon native AI for faster, offline gameplay:**

- **Local AI**: Game runs entirely offline on Apple Silicon
- **Faster Generation**: Neural Engine acceleration
- **No Internet Required**: Complete privacy
- **Model Support**: mlx-community models optimized for storytelling
- **Automatic Fallback**: Switches to Ollama if MLX unavailable

**Setup:**
```bash
pip install mlx-lm
# Blompie auto-detects and uses MLX if available
```

---

## Features

### Story Generation
- **Infinite Worlds**: Procedurally generated adventures
- **Dynamic NPCs**: AI creates memorable characters
- **Branching Narratives**: Your choices shape the story
- **Multiple Genres**: Fantasy, sci-fi, mystery, horror, comedy
- **Adaptive Difficulty**: AI adjusts to your skill level

### Game Systems
- **Combat**: Text-based battle system
- **Inventory**: Pick up, use, and trade items
- **Dialogue**: Conversation system with NPCs
- **Exploration**: Discover locations and secrets
- **Quests**: AI-generated missions and objectives
- **Puzzles**: Solve riddles and challenges

### Technical Features
- **Local AI**: Ollama or MLX (v1.1.0)
- **Save System**: 8 save slots with auto-save
- **Undo/Redo**: Rewind bad decisions
- **Export**: Save game logs as text
- **Statistics**: Track your play stats
- **Achievements**: 30+ unlockable achievements

---

## Security & Privacy

- **100% Local**: All AI runs on your Mac
- **No Internet Required**: Completely offline (with local AI)
- **No Telemetry**: Zero analytics or tracking
- **Private Stories**: Your adventures stay private
- **Ethical AI**: Content moderation prevents harmful outputs

---

## Requirements

### System Requirements
- **macOS 13.0 (Ventura) or later**
- **8GB RAM** (16GB recommended for MLX)
- **Architecture**: Universal (Apple Silicon recommended)

### AI Backend (Choose One)
**Ollama (Recommended):**
```bash
brew install ollama
ollama serve
ollama pull mistral:latest  # Best for storytelling
```

**MLX (Apple Silicon Only):**
```bash
pip install mlx-lm
# Blompie auto-detects
```

### Dependencies
**Built-in:**
- SwiftUI, AppKit, Foundation

**Required:**
- Ollama OR MLX for AI

---

## Installation

### Pre-built Binary

```bash
open "/Volumes/Data/xcode/binaries/20260127-Blompie-v1.1.0/Blompie-v1.1.0-build2.dmg"
```

### Build from Source

```bash
git clone https://github.com/kochj23/Blompie.git
cd Blompie
open "Blompie.xcodeproj"
# Press ⌘R to build and run
```

---

## How to Play

### First Adventure

1. **Launch Blompie**
2. **Wait for AI** to generate opening scene
3. **Type your action** in the input field
4. **Press Enter** to send
5. **AI responds** with what happens
6. **Continue exploring!**

### Commands

**Free-Form Input:**
- Type anything! "examine door", "talk to merchant", "attack goblin"
- AI understands natural language
- Be specific or vague—AI adapts

**System Commands:**
- `/save` - Save current game
- `/load` - Load saved game
- `/undo` - Undo last action
- `/stats` - View statistics
- `/help` - Show all commands

### Tips for Best Experience

- **Be descriptive**: "Carefully open the creaking wooden door"
- **Try anything**: AI adapts to creative actions
- **Talk to everyone**: NPCs have deep personalities
- **Explore thoroughly**: Secrets everywhere
- **Save often**: Multiple save slots available
- **Experiment**: There are no wrong answers

---

## Troubleshooting

**AI Responses Slow:**
- Use faster model: `ollama pull mistral:latest`
- Or try MLX on Apple Silicon
- Close other apps

**Game Stuck:**
- Try different phrasing
- Use `/undo` to rewind
- Restart conversation with `/restart`

**Ollama Not Responding:**
- Check: `ollama serve` is running
- Verify: `ollama list` shows models
- Restart Ollama service

---

## Version History

### v1.1.0 (January 2026)
- MLX backend support
- Apple Silicon optimization
- Faster story generation

### v1.0.0 (December 2024)
- Initial release
- Ollama integration
- Save system
- Achievement system

---

## License

MIT License - Copyright © 2026 Jordan Koch

---

**Last Updated:** January 27, 2026
**Status:** ✅ Ready to Play
