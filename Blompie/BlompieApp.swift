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
        }
    }
}
