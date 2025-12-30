//
//  ColorTheme.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import SwiftUI

struct ColorTheme: Identifiable, Codable {
    let id: String
    let name: String
    let textColor: CodableColor
    let backgroundColor: CodableColor

    static let classicGreen = ColorTheme(
        id: "classic",
        name: "Classic Green",
        textColor: CodableColor(color: .green),
        backgroundColor: CodableColor(color: .black)
    )

    static let amber = ColorTheme(
        id: "amber",
        name: "Amber Terminal",
        textColor: CodableColor(red: 1.0, green: 0.75, blue: 0.0),
        backgroundColor: CodableColor(color: .black)
    )

    static let retroBlue = ColorTheme(
        id: "retroBlue",
        name: "Retro Blue",
        textColor: CodableColor(red: 0.0, green: 0.9, blue: 1.0),
        backgroundColor: CodableColor(red: 0.0, green: 0.0, blue: 0.2)
    )

    static let paperMode = ColorTheme(
        id: "paper",
        name: "Paper Mode",
        textColor: CodableColor(red: 0.1, green: 0.1, blue: 0.1),
        backgroundColor: CodableColor(red: 0.98, green: 0.97, blue: 0.93)
    )

    static let hacker = ColorTheme(
        id: "hacker",
        name: "Matrix Green",
        textColor: CodableColor(red: 0.0, green: 1.0, blue: 0.0),
        backgroundColor: CodableColor(color: .black)
    )

    static let allThemes: [ColorTheme] = [.classicGreen, .amber, .retroBlue, .paperMode, .hacker]
}

struct CodableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(color: Color) {
        if color == .black {
            self.red = 0
            self.green = 0
            self.blue = 0
        } else if color == .green {
            self.red = 0
            self.green = 1
            self.blue = 0
        } else {
            self.red = 0.5
            self.green = 0.5
            self.blue = 0.5
        }
        self.alpha = 1.0
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
