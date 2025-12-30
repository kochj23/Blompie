//
//  ContentView.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var gameEngine = GameEngine()
    @AppStorage("fontSize") private var fontSize: Double = 14

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(gameEngine.messages) { message in
                            Text(message.text)
                                .font(.system(size: fontSize, design: .monospaced))
                                .foregroundColor(.green)
                                .textSelection(.enabled)
                                .id(message.id)
                        }

                        if gameEngine.isLoading {
                            HStack(spacing: 4) {
                                Text(">")
                                    .foregroundColor(.green.opacity(0.6))
                                Text("Loading...")
                                    .foregroundColor(.green.opacity(0.6))
                            }
                            .font(.system(size: fontSize, design: .monospaced))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black)
                .onChange(of: gameEngine.messages.count) {
                    if let lastMessage = gameEngine.messages.last {
                        withAnimation {
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
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.8))
            }

            // Control buttons
            HStack(spacing: 16) {
                Button(action: {
                    gameEngine.startNewGame()
                }) {
                    Text("New Game")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)

                Button(action: {
                    gameEngine.saveGame()
                }) {
                    Text("Save")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)

                Button(action: {
                    gameEngine.loadGame()
                }) {
                    Text("Load")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.8))
        }
        .background(Color.black)
        .onAppear {
            gameEngine.loadGame()
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
    }
}

#Preview {
    ContentView()
}
