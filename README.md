# Blompie

A Zork-style text adventure game for macOS powered by Ollama's Mistral model.

## Overview

Blompie is a classic text adventure game that uses local AI (Ollama) to generate an interactive narrative experience. Unlike traditional text adventures with preset puzzles and objectives, Blompie creates a dynamic world where the AI game master responds to your actions and crafts unique adventures on the fly.

## Features

- **Terminal-style interface** - Classic green-on-black monospace text display
- **AI-powered narrative** - Uses Ollama's Mistral model for dynamic story generation
- **Action-based gameplay** - Click buttons to choose your actions
- **Save/Load system** - Resume your adventure anytime
- **No fixed objectives** - Pure exploration and discovery

## Requirements

- macOS 14.0 or later
- [Ollama](https://ollama.ai) installed and running locally
- Mistral model pulled: `ollama pull mistral`

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/kochj23/Blompie.git
   cd Blompie
   ```

2. Open `Blompie.xcodeproj` in Xcode

3. Build and run (⌘R)

## Usage

1. Make sure Ollama is running:
   ```bash
   ollama serve
   ```

2. Launch Blompie

3. Click action buttons to explore the world

4. Use **Save** to save your progress, **Load** to restore, or **New Game** to start fresh

## How It Works

Blompie communicates with Ollama running on `localhost:11434`. The game sends your actions to the Mistral model, which acts as a game master, describing the world and presenting new actions based on your choices.

The AI is instructed to:
- Create immersive, mysterious worlds
- Respond with vivid descriptions
- Present 2-4 possible actions after each response
- Track inventory and game state implicitly
- Make the world feel alive and responsive

## Architecture

- **SwiftUI** - Modern declarative UI framework
- **MVVM Pattern** - Clean separation of concerns
- **UserDefaults** - Persistent game state storage
- **Async/Await** - Modern concurrency for API calls

### Key Components

- `BlompieApp.swift` - App entry point
- `ContentView.swift` - Main UI with terminal display and action buttons
- `GameEngine.swift` - Core game logic and state management
- `OllamaService.swift` - Ollama API client

## Customization

Want to change the AI model or behavior?

1. Edit `OllamaService.swift` to change the model (line 27)
2. Edit `GameEngine.swift` to modify the system prompt (lines 34-54)

## License

MIT License - see LICENSE file for details

## Credits

Created by Jordan Koch ([@kochj23](https://github.com/kochj23))

Powered by [Ollama](https://ollama.ai)
