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

enum ScratchLabDesign {

    // MARK: Spacing

    enum Spacing {
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
        // V3.2 locked semantic accent — Figma `--scratchlab-color-bg-accent` /
        // `--scratchlab-color-icon-accent` (#0EA5E9). Deliberately an explicit
        // RGB literal, NOT `.accentColor`: this app's system AccentColor asset
        // is gold (matches the app icon) — a separate, legacy system-tint
        // concern this semantic token must stay decoupled from, so it resolves
        // identically on macOS, iPhone, and iPad.
        static let accent: Color   = Color(red: 14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0)
        static let success: Color  = Color.platformSuccess
        static let warning: Color  = Color(red: 1.00, green: 0.72, blue: 0.10)   // ≈ #FFB81A
        static let danger: Color   = Color.platformDanger
        static let info: Color     = Color(red: 0.55, green: 0.75, blue: 1.00)   // ≈ #8CBFFF
        static let muted: Color    = Color(white: 0.52)

        // Text hierarchy, aliased to SwiftUI's semantic label colors so the
        // token layer names every role without introducing a second palette.
        static let textPrimary: Color   = .primary
        static let textSecondary: Color = .secondary
    }

    // MARK: Surface colors

    enum Surface {
        static let canvas: Color       = .black
        static let card: Color         = Color.platformRaisedSurface
        static let window: Color       = Color.platformBackground
        static let stageOverlay: Color = Color.white.opacity(0.05)
        static let divider: Color      = Color.white.opacity(0.10)
    }

    // MARK: Notation palette (shared by notation + review surfaces)

    enum Notation {
        static let forward       = Color(red: 0.20, green: 0.88, blue: 0.55)
        static let backward      = Color(red: 1.00, green: 0.55, blue: 0.10)
        static let audioInferred = Color(red: 1.00, green: 0.72, blue: 0.10)
        static let audioBurst    = Color(red: 0.55, green: 0.75, blue: 1.00)
        static let cut           = Color(red: 1.00, green: 0.72, blue: 0.10)
        static let fader         = Color(red: 1.00, green: 0.50, blue: 0.20)
        static let silence       = Color(white: 0.38)
        static let holdLine      = Color(white: 0.40)
        static let dot           = Color(white: 0.82)
        static let canvasBg      = Color(white: 0.10)
        static let gridMajor     = Color(white: 0.22)
        static let gridMinor     = Color(white: 0.14)
    }

    // MARK: Buttons

    enum Button {
        // V3.2: Figma's Button component states a 44pt minimum touch target
        // explicitly; 36pt was below both that spec and Apple's HIG minimum.
        // Applies to `.primary` and `.success` roles (the two call-to-action
        // roles); secondary/tertiary/destructive are unchanged (not part of
        // this correction).
        static let primaryHeight: CGFloat = 44
        static let secondaryHeight: CGFloat = 30
        static let tertiaryHeight: CGFloat = 26
        static let destructiveHeight: CGFloat = 26
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

enum StatusBadgeVariant {
    case neutral
    case success
    case warning
    case danger
    case info
    case accent
    case custom(Color)

    var color: Color {
        switch self {
        case .neutral:            return .secondary
        case .success:            return ScratchLabDesign.Sem.success
        case .warning:            return ScratchLabDesign.Sem.warning
        case .danger:             return ScratchLabDesign.Sem.danger
        case .info:               return ScratchLabDesign.Sem.info
        case .accent:             return ScratchLabDesign.Sem.accent
        case .custom(let color):  return color
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

struct ScratchLabButtonStyle: ViewModifier {
    let role: ScratchLabButtonRole
    let fillsWidth: Bool

    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .font(ScratchLabDesign.Typo.buttonPrimary)
                .frame(minHeight: ScratchLabDesign.Button.primaryHeight)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // `.borderedProminent` fills from the ambient SwiftUI tint,
                // not from `Sem.accent` directly — without this the button
                // silently renders in the system AccentColor (gold) instead
                // of the V3.2 semantic accent, even though `Sem.accent` is
                // itself correct.
                .tint(ScratchLabDesign.Sem.accent)
        case .success:
            content
                .font(ScratchLabDesign.Typo.buttonPrimary)
                .foregroundStyle(Color.black)
                .frame(minHeight: ScratchLabDesign.Button.primaryHeight)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(
                    ScratchLabDesign.Sem.success,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        case .secondary:
            content
                .font(ScratchLabDesign.Typo.buttonSecondary)
                .frame(minHeight: ScratchLabDesign.Button.secondaryHeight)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        case .tertiary:
            content
                .font(ScratchLabDesign.Typo.buttonTertiary)
                .frame(minHeight: ScratchLabDesign.Button.tertiaryHeight)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        case .destructive:
            content
                .font(ScratchLabDesign.Typo.buttonTertiary)
                .frame(minHeight: ScratchLabDesign.Button.destructiveHeight)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(ScratchLabDesign.Sem.danger)
        }
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
        }
    }
}

extension View {
    func scratchLabCard(_ style: ScratchLabCardStyle = .standard) -> some View {
        modifier(ScratchLabCardModifier(style: style))
    }
}
