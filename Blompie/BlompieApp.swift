//
//  BlompieApp.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import SwiftUI

@main
struct BlompieApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: NSNotification.Name("IncreaseFontSize"), object: nil)
                }
                .keyboardShortcut("+", modifiers: [.control, .shift])

                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: NSNotification.Name("DecreaseFontSize"), object: nil)
                }
                .keyboardShortcut("-", modifiers: [.control, .shift])
            }
        }
    }
}
