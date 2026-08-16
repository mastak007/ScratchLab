import SwiftUI

// MARK: - ScratchLab cross-platform design system
//
// Single source of truth for the shared semantic spacing, typography, palette,
// and reusable presentation primitives used by both the macOS (`ScratchLabDesktop`)
// and iPhone/iPad (`ScratchLab`) targets. New code should import these tokens
// rather than hard-coding literal padding / colors / font sizes.
//
// Platform-dependent values are isolated behind a narrow `#if canImport(UIKit)`
// conditional so the shared layer never depends on `NSColor` / `UIColor` at a
// call site. The application surface uses Apple system typography (SF Pro);
// technical/data content uses `.monospaced` (SF Mono / Menlo) as the approved
// system fallback — Roboto Mono is not bundled.
//
// Convention: tokens live in `ScratchLabDesign.*` so they show up grouped in
// auto-complete. Shared components live at the top level (StatusBadge, Chip).

private extension Color {
    /// Locked Figma hex → SwiftUI Color. Every semantic token resolves through
    /// this so a role maps to one explicit RGB value, identical on macOS,
    /// iPhone and iPad — no system-color drift, no raw literal at a call site.
    init(scratchLabHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

enum ScratchLabDesign {

    // MARK: Spacing
    //
    // The canonical Figma scale (V3.2 Foundations) plus the workspace-specific
    // rhythm tokens the macOS/iOS views already use. New components consume the
    // canonical scale; the named rhythm tokens stay for the existing call sites.

    enum Spacing {
        // Canonical Figma scale.
        static let none: CGFloat = 0
        static let xxs: CGFloat = 4    // spacing/2xs
        static let xs: CGFloat = 6     // spacing/xs
        static let sm: CGFloat = 8     // spacing/sm
        static let md: CGFloat = 12    // spacing/md
        static let lg: CGFloat = 16    // spacing/lg
        static let xl: CGFloat = 20    // spacing/xl
        static let xxl: CGFloat = 24   // spacing/2xl
        static let xxxl: CGFloat = 32  // spacing/3xl

        // Workspace rhythm (existing call sites).
        static let cardGroup: CGFloat = 22         // between sibling cards in a sidebar
        static let cardSection: CGFloat = 18       // between major sections in a card
        static let itemRow: CGFloat = 14           // between rows inside a section
        static let itemTight: CGFloat = 8          // inside a row
        static let disclosureContentTop: CGFloat = 12
        static let sidebarTop: CGFloat = 18
        static let sidebarBottom: CGFloat = 28
        static let sidebarHorizontal: CGFloat = 24
        static let sidebarHorizontalCompact: CGFloat = 20  // Capture
    }

    // MARK: Card

    enum Card {
        static let padding: CGFloat = 20
        static let stagePadding: CGFloat = 16
        static let compactPadding: CGFloat = 14
        static let cornerRadius: CGFloat = 18
        static let compactCornerRadius: CGFloat = 14
        static let heroCornerRadius: CGFloat = 22  // outermost camera/notation
    }

    // MARK: Sidebar widths (macOS workspace layout)

    enum Sidebar {
        static let practiceMin: CGFloat = 300
        static let practiceIdeal: CGFloat = 340
        static let practiceMax: CGFloat = 400

        static let captureMin: CGFloat = 320
        static let captureIdeal: CGFloat = 360
        static let captureMax: CGFloat = 420

        static let reviewMin: CGFloat = 340
        static let reviewIdeal: CGFloat = 380
        static let reviewMax: CGFloat = 460

        static let advancedMin: CGFloat = 340
        static let advancedIdeal: CGFloat = 380
        static let advancedMax: CGFloat = 460
    }

    // MARK: Stage

    enum Stage {
        static let outerPadding: CGFloat = 18
        static let headerToContent: CGFloat = 18
    }

    // MARK: Typography
    //
    // Apple system typography (SF Pro). Technical/data faces use the system
    // monospaced fallback (`.monospaced`). No bundled font, no Inter.

    enum Typo {
        // Canonical Figma typography roles (V3.2 Foundations). Line heights are
        // documented here and applied via `.lineSpacing` where a surface needs
        // them; SwiftUI sizes track Dynamic Type rather than fixed px.
        //   Display/App 30/36 · Title/1 28/34 · Title/2 22/28 · Title/3 17/22 ·
        //   Body/Default 15/21 · Body/Small 13/18 · Label 12/16 · Caption 11/15 ·
        //   Technical 11/16 (monospaced).
        static let display    = Font.system(size: 30, weight: .semibold)
        static let title1     = Font.system(size: 28, weight: .semibold)
        static let title2     = Font.system(size: 22, weight: .semibold)
        static let title3     = Font.system(size: 17, weight: .semibold)
        static let bodyDefault = Font.system(size: 15, weight: .regular)
        static let bodySmall   = Font.system(size: 13, weight: .regular)
        static let label       = Font.system(size: 12, weight: .medium)
        static let caption     = Font.system(size: 11, weight: .medium)
        static let technical   = Font.system(size: 11, weight: .medium, design: .monospaced)

        // Existing app-specific roles (kept for the current call sites; new
        // surfaces should prefer the canonical roles above).
        static let pageTitle    = Font.system(size: 28, weight: .semibold)
        static let pageSubtitle = Font.system(size: 14, weight: .medium)
        static let pageEyebrow  = Font.system(size: 12, weight: .medium)
        static let pageStatus   = Font.system(size: 12, weight: .semibold)
        static let cardHeading  = Font.system(size: 17, weight: .semibold)
        static let sectionLabel = Font.system(size: 13, weight: .semibold)
        static let body         = Font.system(size: 13, weight: .medium)
        static let bodySecondary = Font.system(size: 12, weight: .medium)
        static let metricLabel  = Font.system(size: 10, weight: .bold, design: .monospaced)
        static let metricValue  = Font.system(size: 12, weight: .semibold)
        static let statusPill   = Font.system(size: 11, weight: .bold)
        static let controlValue = Font.system(size: 14, weight: .semibold)
        static let disclosureLabel = Font.system(size: 13, weight: .semibold)
        static let chipLabel    = Font.system(size: 12, weight: .semibold)
        static let chipNumeric  = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let buttonPrimary    = Font.system(size: 14, weight: .semibold)
        static let buttonSecondary  = Font.system(size: 13, weight: .semibold)
        static let buttonTertiary   = Font.system(size: 12, weight: .medium)
    }

    // MARK: Semantic colors
    //
    // Roles only — never screen-specific decoration. Red (`danger`) is reserved
    // for recording, destructive actions, failure and urgent interruption.

    enum Sem {
        // V3.2 locked semantic roles — Figma `--scratchlab-color-*`. Explicit
        // RGB literals, NOT `.accentColor`/system colours: this app's AccentColor
        // asset is gold (icon) — a separate legacy concern these roles stay
        // decoupled from. Semantic colour rules, enforced here not per screen:
        //   cyan   = normal primary action
        //   green  = genuinely ready / confirmed / complete
        //   amber  = warning / coaching correction / needs attention
        //   red    = recording / destructive / failure / urgent interruption
        //   grey   = inactive / unavailable / secondary
        static let accent: Color   = Color(scratchLabHex: 0x0EA5E9)   // cyan/500
        static let success: Color  = Color(scratchLabHex: 0x22C55E)   // green/500
        static let warning: Color  = Color(scratchLabHex: 0xF59E0B)   // amber/500
        static let danger: Color   = Color(scratchLabHex: 0xF44336)   // red/500
        static let info: Color     = Color(scratchLabHex: 0x7DD3FC)   // cyan/300
        static let muted: Color    = Color(scratchLabHex: 0x8D8A85)   // neutral/500

        // Text hierarchy — locked Figma `color/text/*`.
        static let textPrimary: Color   = Color(scratchLabHex: 0xFFFFFF)
        static let textSecondary: Color = Color(scratchLabHex: 0xA8A5A0)
        static let textTertiary: Color  = Color(scratchLabHex: 0x8D8A85)
        static let textAccent: Color    = Color(scratchLabHex: 0x7DD3FC)
        static let textSuccess: Color   = Color(scratchLabHex: 0x22C55E)
        static let textWarning: Color   = Color(scratchLabHex: 0xF59E0B)
        static let textError: Color     = Color(scratchLabHex: 0xF44336)
        /// READY is neutral bone, never green — green is reserved for confirmed
        /// completion (Foundations usage rule).
        static let textStatusReady: Color = Color(scratchLabHex: 0xE8E4DC)
        /// Dark text on a cyan/green fill — the Button primary label colour.
        static let textOnAccent: Color = Color(scratchLabHex: 0x05070B)
    }

    // MARK: Semantic borders / icons

    enum Border {
        static let `default`: Color = Color(scratchLabHex: 0x2C3340)  // slate/700
        static let strong: Color    = Color(scratchLabHex: 0x475569)  // slate/600
        static let warning: Color   = Color(scratchLabHex: 0x4A3F2A)  // muted amber
        static let error: Color     = Color(scratchLabHex: 0x4A2326)  // muted red
    }

    enum Icon {
        static let `default`: Color = Color(scratchLabHex: 0xFFFFFF)
        static let accent: Color    = Color(scratchLabHex: 0x0EA5E9)
    }

    // MARK: Surface colors

    enum Surface {
        // Locked Figma `color/bg/*` — dark-only product surfaces. The app is
        // intentionally dark (Foundations: "Dark application surfaces only");
        // these never fall back to adaptive system light surfaces.
        static let canvas: Color   = Color(scratchLabHex: 0x05070B)   // ink/950
        static let surface: Color  = Color(scratchLabHex: 0x0B1018)   // ink/900
        static let elevated: Color = Color(scratchLabHex: 0x101826)   // ink/850
        static let raised: Color   = Color(scratchLabHex: 0x151E2B)   // ink/800

        // Role aliases for the names the existing views already consume.
        static let card: Color         = Self.raised
        static let window: Color       = Self.canvas
        static let stageOverlay: Color = Color.white.opacity(0.05)   // app-specific, unchanged
        static let divider: Color      = Border.default
    }

    // MARK: Notation palette (shared by notation + review surfaces)

    enum Notation {
        static let forward       = Color(scratchLabHex: 0x22C55E)
        static let backward      = Color(scratchLabHex: 0xF59E0B)
        /// V3.2 target-trace bone (#E8E4DC) — the muted reference path the
        /// learner copies. Warmer than neutral grey so the performed overlay
        /// (accent) reads as the stronger signal. Shared by Practice/Review
        /// on every platform.
        static let targetTrace       = Color(scratchLabHex: 0xE8E4DC)
        /// V3.2 performance trace (#0EA5E9) — the strong cyan path the learner
        /// produces (live or captured). One hue so direction stays geometric
        /// (slope + chevrons), not colour.
        static let performanceTrace  = Color(scratchLabHex: 0x0EA5E9)
        /// Distinct lane canvases — target and performance backgrounds never
        /// blend into one surface (Figma `color/bg/notation/*`).
        static let targetCanvas       = Color(scratchLabHex: 0x101013)
        static let performanceCanvas  = Color(scratchLabHex: 0x0E131B)
        /// Trace stroke weights (Figma `--scratchlab-stroke-*`).
        static let targetStroke: CGFloat      = 1.6
        static let performanceStroke: CGFloat = 2.0
        /// Beat/subdivision grid + neutral rail colours (Figma notation grid).
        static let gridBar: Color         = Color(scratchLabHex: 0x3A3A42)
        static let gridBeat: Color        = Color(scratchLabHex: 0x3A3A42)
        static let gridSubdivision: Color = Color(scratchLabHex: 0x26262C)
        static let lineNeutral: Color     = Color(scratchLabHex: 0x32323A)

        static let audioInferred = Color(scratchLabHex: 0xF59E0B)
        static let audioBurst    = Color(scratchLabHex: 0x7DD3FC)
        static let cut           = Color(scratchLabHex: 0xF59E0B)
        static let fader         = Color(scratchLabHex: 0xFF5C33)
        static let silence       = Color(scratchLabHex: 0x8D8A85)
        static let holdLine      = Color(scratchLabHex: 0x8D8A85)
        static let dot           = Color(scratchLabHex: 0xE8E4DC)
        static let canvasBg      = targetCanvas
        static let gridMajor     = gridBeat
        static let gridMinor     = gridSubdivision
    }

    // MARK: Buttons

    enum Button {
        // Figma's Button component states a 44pt minimum touch target for every
        // filled role (primary/secondary/destructive); only the borderless
        // tertiary utility stays compact.
        static let primaryHeight: CGFloat = 44
        static let secondaryHeight: CGFloat = 44
        static let tertiaryHeight: CGFloat = 26
        static let destructiveHeight: CGFloat = 44
    }

    // MARK: Chips (selectable pills)

    enum Chip {
        static let height: CGFloat = 28
        static let minWidth: CGFloat = 44
        static let cornerRadius: CGFloat = 7
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 6
        static let borderWidth: CGFloat = 1
    }

    // MARK: Status badge (display-only status chip)

    enum Badge {
        static let cornerRadius: CGFloat = 8
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 8
        static let background: Color = Color.white.opacity(0.04)
    }
}

// MARK: - Adaptive layout policy

/// Pure, deterministic adaptive-layout policy shared by iPhone and iPad.
/// Maps a horizontal size class (passed as `isRegularWidth` so the policy is
/// testable without SwiftUI) to the presentation decisions the V3.2 layout
/// makes. The same content and state reorganize by available space — the
/// policy never branches on platform identity, so iPhone and iPad reuse one
/// content path with no semantic fork.
enum ScratchLabAdaptiveLayout {
    /// Deterministic layout mode from size classes — never device-name or
    /// model checks. The three modes match the Figma iPad adaptive contract
    /// (34:2 landscape / 34:41 portrait / 34:66 compact).
    enum LayoutMode: Equatable, Sendable {
        /// Sidebar + detail split (iPad landscape).
        case regularLandscape
        /// Single column, full-width content (iPad portrait).
        case portrait
        /// Single column, compact notation (iPhone / iPad split-view).
        case compact
    }

    /// Maps size classes to `LayoutMode`. Compact horizontal → `.compact`;
    /// regular horizontal + compact vertical → `.regularLandscape` (landscape);
    /// regular + regular → `.portrait`. Pure and stable across boundary widths.
    static func layoutMode(
        horizontalSizeClass: UserInterfaceSizeClass,
        verticalSizeClass: UserInterfaceSizeClass
    ) -> LayoutMode {
        if horizontalSizeClass == .compact { return .compact }
        return verticalSizeClass == .compact ? .regularLandscape : .portrait
    }

    /// ScratchNotationPanel density: Standard on regular width (room for the
    /// full 520×172 panel), Compact on compact width (340×146).
    static func notationPresentation(isRegularWidth: Bool) -> ScratchNotationPanelPresentation {
        isRegularWidth ? .standard : .compact
    }

    static func notationPresentation(for mode: LayoutMode) -> ScratchNotationPanelPresentation {
        mode == .compact ? .compact : .standard
    }

    /// Whether the navigation sidebar is shown (regular width) or collapsed
    /// into a single column (compact width).
    static func usesNavigationSidebar(isRegularWidth: Bool) -> Bool {
        isRegularWidth
    }

    static func usesNavigationSidebar(for mode: LayoutMode) -> Bool {
        mode == .regularLandscape
    }
}

// MARK: - Platform color mapping
//
// The only place `NSColor` / `UIColor` appear in the shared layer. Everything
// else consumes `ScratchLabDesign.*`, so views never branch on platform.

private extension Color {
    static var platformSuccess: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemGreen)
        #else
        return Color(nsColor: .systemGreen)
        #endif
    }

    static var platformDanger: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemRed)
        #else
        return Color(nsColor: .systemRed)
        #endif
    }

    static var platformRaisedSurface: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var platformBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - StatusBadge
//
// Reusable status chip with the canonical "TITLE · STATE" grammar. Status is
// expressed as a semantic variant (neutral / success / warning / danger /
// info / accent) rather than a raw color, so call sites can't repurpose a
// signal color for decoration. `.custom` is the escape hatch for continuous
// signals (e.g. a live audio meter) that don't reduce to a discrete status.
//
// The value is sanitised at display time so callers cannot produce
// repeated-word output like "Audio · Audio Ready" — the title prefix is
// stripped from the value if it repeats. Optional leading SF Symbol gives a
// non-colour cue for state (vital for users who can't distinguish red/green).

enum StatusBadgeVariant: Equatable {
    case neutral
    /// READY — neutral bone. Distinct from `.neutral` (grey inactive): bone
    /// is the positive-but-unconfirmed status the Figma `StatusBadge` uses for
    /// its READY state, so green stays reserved for completion.
    case ready
    case success
    case warning
    case danger
    case info
    case accent
    case custom(Color)

    var color: Color {
        switch self {
        case .neutral:            return ScratchLabDesign.Sem.textSecondary
        case .ready:              return ScratchLabDesign.Sem.textStatusReady
        case .success:            return ScratchLabDesign.Sem.success
        case .warning:            return ScratchLabDesign.Sem.warning
        case .danger:             return ScratchLabDesign.Sem.danger
        case .info:               return ScratchLabDesign.Sem.info
        case .accent:             return ScratchLabDesign.Sem.accent
        case .custom(let color):  return color
        }
    }
}

/// Figma `StatusBadge` state (node 144:23) — the semantic status axis, mapped
/// to a display variant + label. READY is neutral bone; green is reserved for
/// confirmed completion; red for recording/failure; amber for attention;
/// cyan for detected. Used by the domain cards so call sites state a semantic
/// status, never a colour.
enum StatusBadgeState: String, CaseIterable, Sendable {
    case ready
    case detected
    case attention
    case recording
    case failure
    case completed

    var variant: StatusBadgeVariant {
        switch self {
        case .ready:     return .ready
        case .detected:  return .info
        case .attention: return .warning
        case .recording: return .danger
        case .failure:   return .danger
        case .completed: return .success
        }
    }

    var label: String {
        switch self {
        case .ready:     return "READY"
        case .detected:  return "DETECTED"
        case .attention: return "NEEDS ATTENTION"
        case .recording: return "RECORDING"
        case .failure:   return "FAILED"
        case .completed: return "COMPLETE"
        }
    }
}

struct StatusBadge: View {
    let title: String
    let value: String
    let variant: StatusBadgeVariant
    let systemImage: String?

    init(
        title: String,
        value: String,
        variant: StatusBadgeVariant = .neutral,
        systemImage: String? = nil
    ) {
        self.title = title
        self.value = value
        self.variant = variant
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(variant.color)
                        .accessibilityHidden(true)
                }
                Text(Self.dedupedStatusValue(title: title, value: value))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(variant.color)
            }
        }
        .padding(.horizontal, ScratchLabDesign.Badge.horizontalPadding)
        .padding(.vertical, ScratchLabDesign.Badge.verticalPadding)
        .background(
            ScratchLabDesign.Badge.background,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Badge.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// Drop the title token from the value when it appears as a prefix or
    /// echoes the title verbatim, so the "Audio · Audio Ready" pattern can
    /// never reach the UI. Shared by every status chip and tile.
    static func dedupedStatusValue(title: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let lowerTitle = title.lowercased()
        let lowerValue = trimmed.lowercased()
        if lowerValue == lowerTitle { return "—" }
        if lowerValue.hasPrefix(lowerTitle + " ") {
            return String(trimmed.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

// MARK: - Chip
//
// Reusable selectable chip used by BPM, beat-style, mode, and demo-vs-template
// pickers. Selection state uses `Sem.accent` everywhere — never green or
// yellow (those are reserved for health and warning roles).

struct Chip<Label: View>: View {
    let isSelected: Bool
    let isNumeric: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        isSelected: Bool,
        isNumeric: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isSelected = isSelected
        self.isNumeric = isNumeric
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(isNumeric ? ScratchLabDesign.Typo.chipNumeric : ScratchLabDesign.Typo.chipLabel)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, ScratchLabDesign.Chip.horizontalPadding)
                .padding(.vertical, ScratchLabDesign.Chip.verticalPadding)
                .frame(minWidth: ScratchLabDesign.Chip.minWidth, minHeight: ScratchLabDesign.Chip.height)
                .background(
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Chip.cornerRadius, style: .continuous)
                        .fill(isSelected
                              ? ScratchLabDesign.Sem.accent.opacity(0.20)
                              : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Chip.cornerRadius, style: .continuous)
                        .stroke(isSelected
                                ? ScratchLabDesign.Sem.accent
                                : Color.primary.opacity(0.12),
                                lineWidth: ScratchLabDesign.Chip.borderWidth)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension Chip where Label == Text {
    init(_ title: String, isSelected: Bool, isNumeric: Bool = false, action: @escaping () -> Void) {
        self.init(isSelected: isSelected, isNumeric: isNumeric, action: action) {
            Text(title)
        }
    }
}

// MARK: - Shared buttons
//
// The workspace button hierarchy. Roles are token-driven (typography and
// sizing live in `ScratchLabDesign`); primary / success / secondary /
// tertiary / destructive stay visually obvious. Red (destructive) is reserved
// for the role, never used as decoration. Actions, disabled state and
// accessibility remain owned by SwiftUI `Button`.

enum ScratchLabButtonRole {
    case primary
    case success
    case secondary
    case tertiary
    case destructive
}

/// The Figma Button (node 140:18) as a custom `ButtonStyle` — filled roles in
/// exact semantic colours: cyan primary (dark label), green success (dark
/// label), surface secondary, red destructive (white label). Disabled roles
/// render on `raised` with tertiary text. Red stays reserved for destructive
/// action, never decoration.
private struct ScratchLabFilledButtonStyle: ButtonStyle {
    let role: ScratchLabButtonRole
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var height: CGFloat {
        switch role {
        case .primary, .success, .secondary, .destructive:
            return ScratchLabDesign.Button.primaryHeight
        case .tertiary:
            return ScratchLabDesign.Button.tertiaryHeight
        }
    }

    private var font: Font {
        switch role {
        case .primary, .success: return ScratchLabDesign.Typo.buttonPrimary
        case .secondary: return ScratchLabDesign.Typo.buttonSecondary
        case .tertiary, .destructive: return ScratchLabDesign.Typo.buttonTertiary
        }
    }

    private var foreground: Color {
        guard isEnabled else { return ScratchLabDesign.Sem.textTertiary }
        switch role {
        case .primary, .success: return ScratchLabDesign.Sem.textOnAccent
        case .secondary, .destructive: return ScratchLabDesign.Sem.textPrimary
        case .tertiary: return ScratchLabDesign.Sem.textSecondary
        }
    }

    private var background: Color {
        guard isEnabled else { return ScratchLabDesign.Surface.raised }
        switch role {
        case .primary: return ScratchLabDesign.Sem.accent
        case .success: return ScratchLabDesign.Sem.success
        case .secondary: return ScratchLabDesign.Surface.surface
        case .destructive: return ScratchLabDesign.Sem.danger
        case .tertiary: return .clear
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .tertiary ? 0 : ScratchLabDesign.Spacing.lg)
            .frame(minHeight: height)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isEnabled ? ScratchLabDesign.Border.default : Color.clear, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct ScratchLabButtonStyle: ViewModifier {
    let role: ScratchLabButtonRole
    let fillsWidth: Bool

    func body(content: Content) -> some View {
        content.buttonStyle(ScratchLabFilledButtonStyle(role: role, fillsWidth: fillsWidth))
    }
}

extension View {
    /// One-per-section dominant action.
    func scratchLabPrimaryButton(fillsWidth: Bool = false) -> some View {
        modifier(ScratchLabButtonStyle(role: .primary, fillsWidth: fillsWidth))
    }
    /// Filled success action for a ready-to-start workflow.
    func scratchLabSuccessButton(fillsWidth: Bool = false) -> some View {
        modifier(ScratchLabButtonStyle(role: .success, fillsWidth: fillsWidth))
    }
    /// Bordered medium-weight action.
    func scratchLabSecondaryButton(fillsWidth: Bool = false) -> some View {
        modifier(ScratchLabButtonStyle(role: .secondary, fillsWidth: fillsWidth))
    }
    /// Borderless subtle utility action.
    func scratchLabTertiaryButton() -> some View {
        modifier(ScratchLabButtonStyle(role: .tertiary, fillsWidth: false))
    }
    /// Subtle destructive action (Discard, Reset).
    func scratchLabDestructiveButton() -> some View {
        modifier(ScratchLabButtonStyle(role: .destructive, fillsWidth: false))
    }
}

// MARK: - Card surfaces
//
// Shared SurfaceCard presentation. Owns background, border, corner radius,
// spacing and elevation only — no feature logic.

enum ScratchLabCardStyle {
    case standard
    case pageHeader
    case lessonHero
    case hero
    case stage
    /// Figma SurfaceCard states (node 145:17): elevated + accent border.
    case selected
    /// Figma SurfaceCard warning — muted amber border.
    case warning
    /// Figma SurfaceCard error — muted red border.
    case error
}

private struct ScratchLabCardModifier: ViewModifier {
    let style: ScratchLabCardStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .standard:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    ScratchLabDesign.Surface.card,
                    in: RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }

        case .pageHeader:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.heroCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.heroCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

        case .lessonHero:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    LinearGradient(
                        colors: [
                            ScratchLabDesign.Sem.accent.opacity(0.22),
                            ScratchLabDesign.Surface.card.opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.heroCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.heroCornerRadius,
                        style: .continuous
                    )
                    .stroke(ScratchLabDesign.Sem.accent.opacity(0.30), lineWidth: 1)
                }

        case .hero:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

        case .stage:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.stagePadding)
                .background(
                    ScratchLabDesign.Surface.stageOverlay,
                    in: RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ScratchLabDesign.Card.cornerRadius,
                        style: .continuous
                    )
                    .stroke(ScratchLabDesign.Surface.divider, lineWidth: 1)
                }

        case .selected:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    ScratchLabDesign.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                        .stroke(ScratchLabDesign.Sem.accent, lineWidth: 1)
                }

        case .warning:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    ScratchLabDesign.Surface.surface,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                        .stroke(ScratchLabDesign.Border.warning, lineWidth: 1)
                }

        case .error:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScratchLabDesign.Card.padding)
                .background(
                    ScratchLabDesign.Surface.surface,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
                        .stroke(ScratchLabDesign.Border.error, lineWidth: 1)
                }
        }
    }
}

extension View {
    func scratchLabCard(_ style: ScratchLabCardStyle = .standard) -> some View {
        modifier(ScratchLabCardModifier(style: style))
    }
}

// MARK: - Hardware verification tier
//
// Distinct from readiness. A device can be a KNOWN OPTION (unverified) yet
// currently DETECTED, or VERIFIED but currently LOST. The UI must never fold
// identity / tier / readiness into one boolean or one colour.

enum HardwareVerificationTier: String, CaseIterable, Sendable {
    case verified
    case testedNotYetVerified
    case knownOptionUnverified
    case verifyInEngineering

    var label: String {
        switch self {
        case .verified: return "VERIFIED"
        case .testedNotYetVerified: return "TESTED — NOT YET VERIFIED"
        case .knownOptionUnverified: return "KNOWN OPTION — UNVERIFIED"
        case .verifyInEngineering: return "VERIFY IN ENGINEERING"
        }
    }
}

// MARK: - InputReadinessRow (Figma node 158:38)

/// Semantic readiness of a single capture input — setup/device/platter/DVS/MIDI.
/// `detected` (connected/sensed) is NOT `ready`; a caller derives `ready` from
/// the engine's own usable-signal conditions.
enum InputReadinessState: String, CaseIterable, Sendable {
    case setupRequired
    /// Optional / not-applicable input — grey, non-blocking, no readiness
    /// implication (distinct from `.setupRequired`, which implies the input
    /// MUST be configured before recording).
    case neutral
    case detected
    case ready
    case needsAttention
    case lost

    var label: String {
        switch self {
        case .setupRequired: return "SETUP REQUIRED"
        case .neutral: return "—"
        case .detected: return "DETECTED"
        case .ready: return "READY"
        case .needsAttention: return "NEEDS ATTENTION"
        case .lost: return "LOST"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .setupRequired: return .neutral
        case .neutral: return .neutral
        case .detected: return .info
        case .ready: return .ready
        case .needsAttention: return .warning
        case .lost: return .danger
        }
    }

    /// Whether this state blocks recording (only `.setupRequired`,
    /// `.needsAttention` and `.lost` are blocking; `.neutral` is not).
    var isBlocking: Bool {
        switch self {
        case .setupRequired, .needsAttention, .lost: return true
        case .neutral, .detected, .ready: return false
        }
    }
}

struct InputReadinessRow: View {
    let title: String
    let state: InputReadinessState
    var detail: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            Circle()
                .fill(state.variant.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                if let detail {
                    Text(detail)
                        .font(ScratchLabDesign.Typo.bodySecondary)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: ScratchLabDesign.Spacing.sm)

            Text(state.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(state.variant.color)
                .lineLimit(1)
        }
        .padding(.vertical, ScratchLabDesign.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title): \(state.label)"))
    }
}

// MARK: - HardwareProfile (Figma node 159:49)
//
// Identity, classification, verification tier and readiness are SEPARATE
// inputs — no hardware name is baked into a state variant.

struct HardwareProfileCard: View {
    let name: String
    let classification: String
    let tier: HardwareVerificationTier
    let readiness: InputReadinessState
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
            HStack {
                Text(name)
                    .font(ScratchLabDesign.Typo.title3)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: readiness.label, variant: readiness.variant)
            }

            Text(classification)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(tier.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
        }
        .scratchLabCard(.standard)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name), \(tier.label), \(readiness.label)"))
    }
}

// MARK: - RecoveryCard (Figma node 163:33)

enum RecoveryIssue: String, CaseIterable, Sendable {
    case audioUnavailable
    case timecodeLost
    case recordingIncomplete
    case permissionRequired

    var title: String {
        switch self {
        case .audioUnavailable: return "Audio unavailable"
        case .timecodeLost: return "Timecode lost"
        case .recordingIncomplete: return "Recording incomplete"
        case .permissionRequired: return "Permission required"
        }
    }

    var systemImage: String {
        switch self {
        case .audioUnavailable: return "speaker.slash"
        case .timecodeLost: return "waveform.badge.exclamationmark"
        case .recordingIncomplete: return "record.circle"
        case .permissionRequired: return "lock"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .audioUnavailable, .timecodeLost: return .danger
        case .recordingIncomplete, .permissionRequired: return .warning
        }
    }
}

struct RecoveryCard: View {
    let issue: RecoveryIssue
    var message: String? = nil
    var actionTitle: String = "Retry"
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Image(systemName: issue.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(issue.variant.color)
                Text(issue.title)
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            }

            if let message {
                Text(message)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Button(actionTitle) { action?() }
                    .scratchLabPrimaryButton()
                if let secondaryTitle {
                    Button(secondaryTitle) { secondaryAction?() }
                        .scratchLabSecondaryButton()
                }
            }
        }
        .scratchLabCard(.warning)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - DVS Signal Health (Figma node 252:303)
//
// Carrier detection is NOT DVS ready; DVS ready is NOT capture ready. Each is
// its own state, derived from the timecode pipeline, never from a colour.

enum DVSSignalState: String, CaseIterable, Sendable {
    case noSignal
    case carrierDetected
    case weak
    case clipped
    case channelFault
    case usable
    case lost

    var label: String {
        switch self {
        case .noSignal: return "NO SIGNAL"
        case .carrierDetected: return "CARRIER DETECTED"
        case .weak: return "WEAK"
        case .clipped: return "CLIPPED"
        case .channelFault: return "CHANNEL FAULT"
        case .usable: return "USABLE"
        case .lost: return "LOST"
        }
    }

    /// Whether this state satisfies "DVS ready" — only `.usable` does. Carrier
    /// detection, weak and every other state are explicitly NOT ready.
    var isReady: Bool { self == .usable }

    var variant: StatusBadgeVariant {
        switch self {
        case .noSignal: return .neutral
        case .carrierDetected: return .info
        case .weak: return .warning
        case .clipped: return .warning
        case .channelFault: return .danger
        case .usable: return .ready
        case .lost: return .danger
        }
    }
}

struct DVSSignalHealthCard: View {
    let state: DVSSignalState
    var leftSignal: Double? = nil
    var rightSignal: Double? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack {
                Text("DVS signal")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: state.label, variant: state.variant)
            }
            if let leftSignal, let rightSignal {
                Text(String(format: "L %.1f  ·  R %.1f", leftSignal, rightSignal))
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            if let detail {
                Text(detail)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("DVS signal: \(state.label)"))
    }
}

// MARK: - Controller Mapping (Figma node 253:293)

enum ControllerMappingState: String, CaseIterable, Sendable {
    case noController
    case controllerDetected
    case platterReady
    case crossfaderMappingRequired
    case midiLearned
    case mappingConflict
    case dvsPlusMidiReady

    var label: String {
        switch self {
        case .noController: return "NO CONTROLLER"
        case .controllerDetected: return "CONTROLLER DETECTED"
        case .platterReady: return "PLATTER READY"
        case .crossfaderMappingRequired: return "CROSSFADER MAPPING REQUIRED"
        case .midiLearned: return "MIDI LEARNED"
        case .mappingConflict: return "MAPPING CONFLICT"
        case .dvsPlusMidiReady: return "DVS + MIDI READY"
        }
    }

    /// "DVS + MIDI ready" (the true ready state) is distinct from every
    /// detection/partial state — never inferred from a connected controller.
    var isReady: Bool { self == .dvsPlusMidiReady }

    var variant: StatusBadgeVariant {
        switch self {
        case .noController: return .neutral
        case .controllerDetected: return .info
        case .platterReady: return .ready   // Figma: "Platter Ready" renders the neutral-bone READY badge
        case .crossfaderMappingRequired: return .warning
        case .midiLearned: return .ready
        case .mappingConflict: return .danger
        case .dvsPlusMidiReady: return .success
        }
    }
}

extension ControllerMappingState {
    /// The coarse readiness axis for a hardware profile card. Only
    /// `dvsPlusMidiReady` (the true combined-ready state) is READY; partial and
    /// detection states are DETECTED, and the fixable crossfader/conflict states
    /// are NEEDS ATTENTION. `midiLearned`/`platterReady` are DETECTED here (not
    /// READY) because they are still short of the DVS+MIDI combined-ready gate.
    var inputReadiness: InputReadinessState {
        switch self {
        case .noController: return .setupRequired
        case .controllerDetected, .platterReady, .midiLearned: return .detected
        case .crossfaderMappingRequired, .mappingConflict: return .needsAttention
        case .dvsPlusMidiReady: return .ready
        }
    }
}

struct ControllerMappingCard: View {
    let state: ControllerMappingState
    /// Hardware identity is separate from the mapping state — never baked into
    /// a variant (a `.midiLearned` state must not force a DJM-S11, etc.).
    var controllerName: String? = nil
    var detail: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack {
                Text("MIDI & controller")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: state.label, variant: state.variant)
            }
            if let controllerName {
                Text(controllerName)
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            }
            if let detail {
                Text(detail)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("MIDI & controller: \(state.label)"))
    }
}

// MARK: - CameraDisclosureRow (Figma node 174:23)
//
// Camera is optional and non-blocking. The row is collapsed by default and
// never initialises a preview until opened. This is a camera-specific
// component, not a generic settings row.

enum CameraDisclosureState: String, CaseIterable, Sendable {
    case closed
    case open
    case unavailable

    var isBlocking: Bool { false }   // camera never blocks Practice/Capture

    var label: String {
        switch self {
        case .closed: return "OPTIONAL"
        case .open: return "OPEN"
        case .unavailable: return "UNAVAILABLE"
        }
    }
}

struct CameraDisclosureRow: View {
    let state: CameraDisclosureState
    var isOpen: Bool = false
    var onToggle: (() -> Void)? = nil

    var body: some View {
        Button {
            onToggle?()
        } label: {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Image(systemName: "video")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                Text("Camera")
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Text(state.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            .padding(.vertical, ScratchLabDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Camera, optional"))
        .accessibilityHint(Text("Opens the optional camera preview"))
    }
}

// MARK: - Lesson progress (Figma node 164:130)

enum LessonStage: String, CaseIterable, Sendable {
    case watch
    case listen
    case copy
    case result
    case review

    var label: String {
        switch self {
        case .watch: return "WATCH"
        case .listen: return "LISTEN"
        case .copy: return "COPY"
        case .result: return "RESULT"
        case .review: return "REVIEW"
        }
    }
}

struct LessonProgressIndicator: View {
    let stages: [LessonStage]
    let current: LessonStage

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.xs) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: ScratchLabDesign.Spacing.xxs) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(index == stages.firstIndex(of: current)
                                         ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(index == stages.firstIndex(of: current)
                                                  ? ScratchLabDesign.Sem.accent : Color.clear))
                    Text(stage.label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                if index < stages.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Lesson progress: \(current.label)"))
    }
}

// MARK: - Achievement progress (Figma node 165:29)

/// Persisted achievement state, derived from `ProgressManager` — no separate
/// Achievement model, no fabricated stars.
enum AchievementState: String, CaseIterable, Sendable {
    case empty
    case progress
    case bestResult
    case complete

    var label: String {
        switch self {
        case .empty: return "—"
        case .progress: return "IN PROGRESS"
        case .bestResult: return "BEST RESULT"
        case .complete: return "COMPLETE"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .empty: return .neutral
        case .progress: return .info
        case .bestResult: return .warning
        case .complete: return .success
        }
    }
}

struct AchievementProgressIndicator: View {
    let state: AchievementState
    var title: String = "Achievement"
    var bestAccuracy: Double? = nil
    var stars: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            HStack {
                Text(title)
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                Text(state.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.variant.color)
            }
            if let bestAccuracy {
                Text(String(format: "Best accuracy %.0f%%", bestAccuracy * 100))
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            if let stars {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < stars ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(i < stars ? ScratchLabDesign.Sem.warning : ScratchLabDesign.Sem.textTertiary)
                    }
                }
                .accessibilityLabel(Text("\(stars) of 3 stars"))
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Session summary (Figma node 250:228)

enum SessionSummaryState: String, CaseIterable, Sendable {
    case empty
    case configured
    case ready
    case recording
    case complete
    case incomplete

    var label: String {
        switch self {
        case .empty: return "NO SESSION"
        case .configured: return "CONFIGURED"
        case .ready: return "READY"
        case .recording: return "RECORDING"
        case .complete: return "COMPLETE"
        case .incomplete: return "INCOMPLETE"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .empty: return .neutral
        case .configured: return .info
        case .ready: return .ready
        case .recording: return .danger
        case .complete: return .success
        case .incomplete: return .warning
        }
    }
}

struct SessionSummaryCard: View {
    let state: SessionSummaryState
    var metadata: [(String, String)] = []
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack {
                Text("Session")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: state.label, variant: state.variant)
            }
            ForEach(metadata, id: \.0) { key, value in
                HStack {
                    Text(key)
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    Spacer()
                    Text(value)
                        .font(ScratchLabDesign.Typo.technical)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                }
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Performer Monitor connection (Figma node 253:2451)

enum PerformerMonitorConnectionState: String, CaseIterable, Sendable {
    case searching
    case connected
    case controlledByMac
    case connectionFailed
    case unavailable

    var label: String {
        switch self {
        case .searching: return "SEARCHING"
        case .connected: return "CONNECTED"
        case .controlledByMac: return "CONTROLLED BY MAC"
        case .connectionFailed: return "CONNECTION FAILED"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .searching: return .info
        case .connected: return .ready
        case .controlledByMac: return .ready
        case .connectionFailed: return .danger
        case .unavailable: return .neutral
        }
    }
}

extension PerformerMonitorConnectionState {
    /// Pure: maps a connection-owner status string (when no peer is connected)
    /// to its truthful semantic state, without touching the transport layer.
    ///
    /// - "unable to start …" is the unavailable case (the listener/advertiser
    ///   could not be started at all).
    /// - "paused" / "lost" / "unable to send" are connection failures that need
    ///   the user's attention.
    /// - anything else is still searching/connecting.
    ///
    /// The caller decides whether a *connected* peer maps to `.connected`
    /// (controlling Mac) or `.controlledByMac` (read-only client) — this helper
    /// only classifies the disconnected side.
    static func disconnectedState(fromStatus status: String) -> PerformerMonitorConnectionState {
        let lower = status.lowercased()
        if lower.contains("unable to start") { return .unavailable }
        if lower.contains("paused") || lower.contains("lost") || lower.contains("unable to send") {
            return .connectionFailed
        }
        return .searching
    }
}

struct PerformerMonitorConnectionCard: View {
    let state: PerformerMonitorConnectionState
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack {
                Text("Performer Monitor")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: state.label, variant: state.variant)
            }
            if let detail {
                Text(detail)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Performer Monitor: \(state.label)"))
    }
}

// MARK: - Take list item (Figma node 259:2484)

enum TakeListItemState: String, CaseIterable, Sendable {
    case idle
    case selected
    case ready
    case confirmed
    case incomplete
    case exported

    var label: String {
        switch self {
        case .idle: return "TAKE"
        case .selected: return "SELECTED"
        case .ready: return "READY"
        case .confirmed: return "CONFIRMED"
        case .incomplete: return "INCOMPLETE"
        case .exported: return "EXPORTED"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .idle: return .neutral
        case .selected: return .accent
        case .ready: return .ready
        case .confirmed: return .success
        case .incomplete: return .warning
        case .exported: return .success
        }
    }
}

struct TakeListItem: View {
    let title: String
    let state: TakeListItemState
    var confidence: Double? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    if let confidence {
                        Text(String(format: "Confidence %.0f%%", confidence * 100))
                            .font(ScratchLabDesign.Typo.technical)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    }
                }
                Spacer()
                Text(state.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.variant.color)
            }
            .padding(.vertical, ScratchLabDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title): \(state.label)"))
    }
}

// MARK: - Empty state (Figma node 255:2364)

enum EmptyStateKind: String, CaseIterable, Sendable {
    case noSession
    case noTake
    case noHardware
    case noResults
    case noConnection

    var title: String {
        switch self {
        case .noSession: return "No session"
        case .noTake: return "No take"
        case .noHardware: return "No hardware"
        case .noResults: return "No results"
        case .noConnection: return "No connection"
        }
    }

    var systemImage: String {
        switch self {
        case .noSession: return "square.dashed"
        case .noTake: return "record.circle"
        case .noHardware: return "cable.connector.slash"
        case .noResults: return "chart.bar"
        case .noConnection: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

struct EmptyStateCard: View {
    let kind: EmptyStateKind
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
            Text(kind.title)
                .font(ScratchLabDesign.Typo.title3)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            if let message {
                Text(message)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            if let actionTitle {
                Button(actionTitle) { action?() }
                    .scratchLabSecondaryButton()
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Practice transport (Figma node 254:153)

enum PracticeTransportState: String, CaseIterable, Sendable {
    case ready
    case listening
    case copyActive
    case paused
    case result

    var label: String {
        switch self {
        case .ready: return "READY"
        case .listening: return "LISTENING"
        case .copyActive: return "COPY ACTIVE"
        case .paused: return "PAUSED"
        case .result: return "RESULT"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .ready: return .ready
        case .listening: return .info
        case .copyActive: return .accent
        case .paused: return .warning
        case .result: return .success
        }
    }
}

struct PracticeTransport: View {
    let state: PracticeTransportState
    var primaryTitle: String = "Start"
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            StatusBadge(title: "", value: state.label, variant: state.variant)
            Spacer()
            if let secondaryTitle {
                Button(secondaryTitle) { secondaryAction?() }
                    .scratchLabSecondaryButton()
            }
            Button(primaryTitle) { primaryAction?() }
                .scratchLabPrimaryButton()
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Coaching feedback (Figma node 255:159)

enum CoachingFeedbackKind: String, CaseIterable, Sendable {
    case onTime
    case early
    case late
    case wrongDirection
    case missedFaderAction
    case improvement

    var label: String {
        switch self {
        case .onTime: return "ON TIME"
        case .early: return "EARLY"
        case .late: return "LATE"
        case .wrongDirection: return "WRONG DIRECTION"
        case .missedFaderAction: return "MISSED FADER ACTION"
        case .improvement: return "IMPROVEMENT"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .onTime: return .success
        case .early: return .warning
        case .late: return .warning
        case .wrongDirection: return .danger
        case .missedFaderAction: return .danger
        case .improvement: return .info
        }
    }
}

struct CoachingFeedbackCard: View {
    let kind: CoachingFeedbackKind
    var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            Text(kind.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(kind.variant.color)
            if let message {
                Text(message)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Review & export (Figma node 255:219)

enum ReviewExportState: String, CaseIterable, Sendable {
    case awaitingConfirmation
    case confirmed
    case preparingExport
    case exported
    case exportFailed

    var label: String {
        switch self {
        case .awaitingConfirmation: return "AWAITING CONFIRMATION"
        case .confirmed: return "CONFIRMED"
        case .preparingExport: return "PREPARING EXPORT"
        case .exported: return "EXPORTED"
        case .exportFailed: return "EXPORT FAILED"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .awaitingConfirmation: return .warning
        case .confirmed: return .success
        case .preparingExport: return .info
        case .exported: return .success
        case .exportFailed: return .danger
        }
    }
}

struct ReviewExportCard: View {
    let state: ReviewExportState
    var exportActionTitle: String = "Export"
    var exportAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack {
                Text("Review & export")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                StatusBadge(title: "", value: state.label, variant: state.variant)
            }
            if state == .awaitingConfirmation || state == .confirmed {
                Button(exportActionTitle) { exportAction?() }
                    .scratchLabPrimaryButton()
            }
        }
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metadata field (Figma node 255:2403)

enum MetadataFieldState: String, CaseIterable, Sendable {
    case normal
    case editable
    case selected
    case warning
    case unavailable
    case confirmed

    var variant: StatusBadgeVariant {
        switch self {
        case .normal: return .neutral
        case .editable: return .info
        case .selected: return .accent
        case .warning: return .warning
        case .unavailable: return .neutral
        case .confirmed: return .success
        }
    }
}

struct MetadataField: View {
    let label: String
    let value: String
    var state: MetadataFieldState = .normal
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                Text(value)
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(label): \(value)"))
    }
}

// MARK: - Channel pair selector (Figma node 256:2315)

enum ChannelPairState: String, CaseIterable, Sendable {
    case available
    case selected
    case unavailable
    case signalDetected
    case needsAttention

    var label: String {
        switch self {
        case .available: return "AVAILABLE"
        case .selected: return "SELECTED"
        case .unavailable: return "UNAVAILABLE"
        case .signalDetected: return "SIGNAL DETECTED"
        case .needsAttention: return "NEEDS ATTENTION"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .available: return .neutral
        case .selected: return .accent
        case .unavailable: return .neutral
        case .signalDetected: return .info
        case .needsAttention: return .warning
        }
    }
}

struct ChannelPairSelector: View {
    let title: String
    let state: ChannelPairState
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            HStack {
                Text(title)
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                Text(state.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.variant.color)
            }
            .padding(.vertical, ScratchLabDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title): \(state.label)"))
    }
}

// MARK: - Timecode system selector (Figma node 256:2334)

enum TimecodeSystemOption: String, CaseIterable, Sendable {
    case serato
    case traktor
    case other
    case unknown

    var label: String {
        switch self {
        case .serato: return "Serato"
        case .traktor: return "Traktor"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    /// Only Serato is a known option; Traktor/Other render a VERIFY IN
    /// ENGINEERING tag (a property of the option, not a per-screen decision).
    var isUnverified: Bool { self != .serato }
}

struct TimecodeSystemSelector: View {
    let options: [TimecodeSystemOption]
    let selection: TimecodeSystemOption
    var onSelect: ((TimecodeSystemOption) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Button { onSelect?(option) } label: {
                    HStack {
                        Text(option.label)
                            .font(ScratchLabDesign.Typo.body)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        if option.isUnverified {
                            Text("VERIFY IN ENGINEERING")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                        }
                        Spacer()
                        if option == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ScratchLabDesign.Sem.accent)
                        }
                    }
                    .padding(.vertical, ScratchLabDesign.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Adaptive workspace header (Figma node 248:137)

enum WorkspaceStatus: String, CaseIterable, Sendable {
    case standard
    case ready
    case needsAttention
    case recording
    case complete
    case failed

    var badgeState: StatusBadgeState? {
        switch self {
        case .standard: return nil
        case .ready: return .ready
        case .needsAttention: return .attention
        case .recording: return .recording
        case .complete: return .completed
        case .failed: return .failure
        }
    }
}

struct AdaptiveWorkspaceHeader: View {
    let title: String
    let status: WorkspaceStatus
    var detail: String? = nil

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ScratchLabDesign.Typo.title2)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                if let detail {
                    Text(detail)
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
            }
            Spacer()
            if let badgeState = status.badgeState {
                StatusBadge(title: "", value: badgeState.label, variant: badgeState.variant)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}
