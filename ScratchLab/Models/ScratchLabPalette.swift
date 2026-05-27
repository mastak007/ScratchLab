//  ScratchLabPalette.swift
//  ScratchLab — shared visual palette.

import SwiftUI

enum ScratchLabPalette {

    // MARK: UI semantic roles
    // sRGB values match the hex literals previously inlined in MainMenuView.

    static let success     = Color(.sRGB, red: 34/255,  green: 197/255, blue: 94/255,  opacity: 1)   // 22C55E
    static let info        = Color(.sRGB, red: 14/255,  green: 165/255, blue: 233/255, opacity: 1)   // 0EA5E9
    static let warning     = Color(.sRGB, red: 245/255, green: 158/255, blue: 11/255,  opacity: 1)   // F59E0B
    static let link        = Color(.sRGB, red: 99/255,  green: 102/255, blue: 241/255, opacity: 1)   // 6366F1
    static let demoGold    = Color(.sRGB, red: 255/255, green: 215/255, blue: 0/255,   opacity: 1)   // FFD700
    static let neutralIdle = Color(.sRGB, red: 71/255,  green: 85/255,  blue: 105/255, opacity: 1)   // 475569
    static let neutralDim  = Color(.sRGB, red: 51/255,  green: 65/255,  blue: 85/255,  opacity: 1)   // 334155

    // Heading accents
    static let headingCyan   = Color(.sRGB, red: 125/255, green: 211/255, blue: 252/255, opacity: 1) // 7DD3FC
    static let headingViolet = Color(.sRGB, red: 167/255, green: 139/255, blue: 250/255, opacity: 1) // A78BFA

    // MARK: Notation visual

    static let notationCanvas         = Color(white: 0.10)
    static let notationCanvasRecord   = Color(white: 0.11)
    static let notationCanvasFader    = Color(white: 0.085)
    static let notationGridMajor      = Color(white: 0.22)
    static let notationGridMinor      = Color(white: 0.14)
    static let notationGridMinorDense = Color(white: 0.155)
    static let notationForward        = Color(red: 0.20, green: 0.88, blue: 0.55)
    static let notationFaderClosed    = Color(red: 1.00, green: 0.25, blue: 0.25)
    static let notationCutMark        = Color(white: 0.90)
    static let notationPlayhead       = Color.white
}
