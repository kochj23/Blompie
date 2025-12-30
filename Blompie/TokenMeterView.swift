//
//  TokenMeterView.swift
//  Blompie
//
//  Created by Jordan Koch on 12/30/2024.
//

import SwiftUI

struct TokenMeterView: View {
    let tokensPerSecond: Double
    let textColor: Color
    let fontSize: Double

    private var normalizedValue: Double {
        // Normalize to 0-1 range, assuming max of 60 tok/s for display
        min(tokensPerSecond / 60.0, 1.0)
    }

    private var gaugeColor: Color {
        if tokensPerSecond < 15 {
            return .red
        } else if tokensPerSecond < 30 {
            return .orange
        } else {
            return .green
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Background circle
                Circle()
                    .stroke(textColor.opacity(0.2), lineWidth: 4)
                    .frame(width: 50, height: 50)

                // Progress arc
                Circle()
                    .trim(from: 0, to: normalizedValue)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: normalizedValue)

                // Center text
                VStack(spacing: 0) {
                    Text("\(Int(tokensPerSecond))")
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(gaugeColor)
                }
            }

            Text("tok/s")
                .font(.system(size: fontSize - 6, design: .monospaced))
                .foregroundColor(textColor.opacity(0.6))
        }
    }
}
