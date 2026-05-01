//
//  ColorThemeTests.swift
//  BlompieTests
//
//  Unit tests for ColorTheme and CodableColor models.
//
//  Created by Jordan Koch on 2026-05-01.
//  Copyright 2026 Jordan Koch. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Blompie

final class ColorThemeTests: XCTestCase {

    // MARK: - Theme Definitions

    func testAllThemesCount() {
        XCTAssertEqual(ColorTheme.allThemes.count, 5)
    }

    func testClassicGreenTheme() {
        let theme = ColorTheme.classicGreen
        XCTAssertEqual(theme.id, "classic")
        XCTAssertEqual(theme.name, "Classic Green")
        XCTAssertEqual(theme.textColor.green, 1.0)
        XCTAssertEqual(theme.backgroundColor.red, 0.0)
    }

    func testAmberTheme() {
        let theme = ColorTheme.amber
        XCTAssertEqual(theme.id, "amber")
        XCTAssertEqual(theme.name, "Amber Terminal")
        XCTAssertEqual(theme.textColor.red, 1.0, accuracy: 0.01)
        XCTAssertEqual(theme.textColor.green, 0.75, accuracy: 0.01)
    }

    func testRetroBlueTheme() {
        let theme = ColorTheme.retroBlue
        XCTAssertEqual(theme.id, "retroBlue")
        XCTAssertEqual(theme.name, "Retro Blue")
        XCTAssertEqual(theme.textColor.blue, 1.0, accuracy: 0.01)
        XCTAssertEqual(theme.backgroundColor.blue, 0.2, accuracy: 0.01)
    }

    func testPaperModeTheme() {
        let theme = ColorTheme.paperMode
        XCTAssertEqual(theme.id, "paper")
        XCTAssertEqual(theme.name, "Paper Mode")
        // Paper mode has dark text on light background
        XCTAssertLessThan(theme.textColor.red, 0.5)
        XCTAssertGreaterThan(theme.backgroundColor.red, 0.9)
    }

    func testHackerTheme() {
        let theme = ColorTheme.hacker
        XCTAssertEqual(theme.id, "hacker")
        XCTAssertEqual(theme.name, "Matrix Green")
        XCTAssertEqual(theme.textColor.green, 1.0)
        XCTAssertEqual(theme.textColor.red, 0.0)
    }

    // MARK: - Theme Uniqueness

    func testAllThemeIDsUnique() {
        let ids = ColorTheme.allThemes.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAllThemeNamesUnique() {
        let names = ColorTheme.allThemes.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count)
    }

    // MARK: - Theme Codable

    func testThemeCodableRoundtrip() throws {
        for theme in ColorTheme.allThemes {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(ColorTheme.self, from: data)
            XCTAssertEqual(decoded.id, theme.id)
            XCTAssertEqual(decoded.name, theme.name)
            XCTAssertEqual(decoded.textColor.red, theme.textColor.red, accuracy: 0.001)
            XCTAssertEqual(decoded.textColor.green, theme.textColor.green, accuracy: 0.001)
            XCTAssertEqual(decoded.textColor.blue, theme.textColor.blue, accuracy: 0.001)
        }
    }

    // MARK: - CodableColor

    func testCodableColorFromComponents() {
        let color = CodableColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)
        XCTAssertEqual(color.red, 0.5)
        XCTAssertEqual(color.green, 0.6)
        XCTAssertEqual(color.blue, 0.7)
        XCTAssertEqual(color.alpha, 0.8)
    }

    func testCodableColorDefaultAlpha() {
        let color = CodableColor(red: 1.0, green: 0.0, blue: 0.0)
        XCTAssertEqual(color.alpha, 1.0)
    }

    func testCodableColorFromBlack() {
        let color = CodableColor(color: .black)
        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0)
        XCTAssertEqual(color.alpha, 1.0)
    }

    func testCodableColorFromGreen() {
        let color = CodableColor(color: .green)
        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 1)
        XCTAssertEqual(color.blue, 0)
    }

    func testCodableColorFromOtherColor() {
        // Any color that isn't .black or .green gets 0.5, 0.5, 0.5
        let color = CodableColor(color: .red)
        XCTAssertEqual(color.red, 0.5)
        XCTAssertEqual(color.green, 0.5)
        XCTAssertEqual(color.blue, 0.5)
    }

    func testCodableColorCodableRoundtrip() throws {
        let original = CodableColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodableColor.self, from: data)
        XCTAssertEqual(decoded.red, 0.1, accuracy: 0.001)
        XCTAssertEqual(decoded.green, 0.2, accuracy: 0.001)
        XCTAssertEqual(decoded.blue, 0.3, accuracy: 0.001)
        XCTAssertEqual(decoded.alpha, 0.9, accuracy: 0.001)
    }

    func testCodableColorToSwiftUIColor() {
        let codable = CodableColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let swiftUIColor = codable.color
        // Verify it returns a Color (type check)
        XCTAssertNotNil(swiftUIColor)
    }
}
