import SwiftUI

// MARK: - ScratchLab cross-target core color primitives
//
// The minimal, platform-safe semantic color layer shared by every ScratchLab
// target — iPhone/iPad (`ScratchLab`), macOS (`ScratchLabDesktop`), and Watch
// (`ScratchLabWatch`). Pure RGB math only, no UIKit/AppKit dependency, so it
// is safe to compile into the Watch target: most of
// `ScratchLabDesignSystem.swift` (materials, the `UIColor`/`NSColor`
// system-color bridge in its "Platform color mapping" section — e.g.
// `.secondarySystemBackground`/`.systemBackground`, which do not exist on
// watchOS — plus card/button/badge/chip components sized for iPhone/iPad/
// macOS) is neither available nor appropriate for a Watch screen.
//
// `ScratchLabDesign.Sem`/`.Surface` on iOS/macOS resolve the roles below
// through these same constants, so there is exactly one canonical hex value
// per semantic role shared across every target — never a second, independent
// Watch-only palette.

extension Color {
    /// Locked Figma hex → SwiftUI Color. Every semantic token resolves through
    /// this so a role maps to one explicit RGB value, identical across every
    /// ScratchLab target — no system-color drift, no raw literal at a call site.
    init(scratchLabHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// The subset of `ScratchLabDesign.Sem`/`.Surface` a Watch-target view needs.
/// See the file-level note above for why the full design system can't be
/// added to the Watch target wholesale.
enum ScratchLabCoreColor {
    static let accent: Color   = Color(scratchLabHex: 0x0EA5E9)   // cyan/500 — primary action
    static let success: Color  = Color(scratchLabHex: 0x22C55E)   // green/500 — genuinely ready / confirmed
    static let warning: Color  = Color(scratchLabHex: 0xF59E0B)   // amber/500 — actionable attention
    static let danger: Color   = Color(scratchLabHex: 0xF44336)   // red/500 — recording / failure
    static let info: Color     = Color(scratchLabHex: 0x7DD3FC)   // cyan/300 — connected, not yet ready

    static let textPrimary: Color   = Color(scratchLabHex: 0xFFFFFF)
    static let textSecondary: Color = Color(scratchLabHex: 0xA8A5A0)
    static let textTertiary: Color  = Color(scratchLabHex: 0x8D8A85)

    static let canvas: Color = Color(scratchLabHex: 0x05070B)   // ink/950
    static let raised: Color = Color(scratchLabHex: 0x101826)   // ink/850

    /// Same translucent-white overlay idiom `ScratchLabDesign.Surface.controlFill`
    /// uses on iOS/macOS — a plain opacity value, not a second hex constant.
    static let controlFill: Color = Color.white.opacity(0.08)
}
