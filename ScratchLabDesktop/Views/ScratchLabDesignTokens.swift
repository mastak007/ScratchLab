import SwiftUI

// MARK: - ScratchLab macOS design tokens
//
// Single source of truth for the macOS app's spacing, typography, palette, and
// reusable controls. Values come from the project's "ScratchLab macOS Design
// System" doc. New code should import these tokens rather than hard-coding
// literal padding / colors / font sizes.
//
// Convention: tokens live in `ScratchLabDesign.*` so they show up grouped in
// auto-complete. Components live at the top level (StatusPill, Chip).

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

    // MARK: Sidebar widths

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

    enum Sem {
        static let accent: Color   = .accentColor
        static let success: Color  = Color(nsColor: .systemGreen)
        static let warning: Color  = Color(red: 1.00, green: 0.72, blue: 0.10)   // ≈ #FFB81A
        static let danger: Color   = Color(nsColor: .systemRed)
        static let info: Color     = Color(red: 0.55, green: 0.75, blue: 1.00)   // ≈ #8CBFFF
        static let muted: Color    = Color(white: 0.52)
    }

    // MARK: Surface colors

    enum Surface {
        static let canvas: Color       = .black
        static let card: Color         = Color(nsColor: .controlBackgroundColor)
        static let window: Color       = Color(nsColor: .windowBackgroundColor)
        static let stageOverlay: Color = Color.white.opacity(0.05)
        static let divider: Color      = Color.white.opacity(0.10)
    }

    // MARK: Notation palette (used by ScratchPhraseChartView and CapturedNotationDisplayView)

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
        static let primaryHeight: CGFloat = 36
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

    // MARK: Status pill (display-only badge)

    enum Pill {
        static let cornerRadius: CGFloat = 6
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 3
    }
}

// MARK: - StatusPill
//
// Reusable badge with the canonical "TITLE · VALUE" grammar. Sanitises the
// value at display time so callers cannot produce repeated-word output like
// "Audio · Audio Ready" — the title prefix is stripped from the value if it
// repeats. Optional leading SF Symbol.

struct StatusPill: View {
    let title: String
    let value: String
    let systemImage: String?
    let color: Color

    init(title: String, value: String, systemImage: String? = nil, color: Color = .secondary) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title.uppercased())
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, ScratchLabDesign.Pill.horizontalPadding)
        .padding(.vertical, ScratchLabDesign.Pill.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Pill.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    /// Strip the title word from the value to avoid "Audio · Audio Ready" patterns.
    /// The raw `value` from the engine may already include the title (legacy
    /// strings like "Audio Ready"); the pill drops the leading title token if
    /// it repeats so the displayed grammar stays "TITLE · STATE".
    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()
        let lowerValue = trimmed.lowercased()
        if lowerValue.hasPrefix(lowerTitle + " ") {
            return String(trimmed.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
        }
        if lowerValue == lowerTitle {
            return "—"
        }
        return trimmed.isEmpty ? "—" : trimmed
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

// MARK: - Card surfaces

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

// MARK: - StepHeader
//
// Numbered workflow-step caption ("① SET UP THE SESSION") used by the Capture
// sidebar's configure → readiness → record → review sequence. Number badge
// uses the accent role; the title reuses the metric-label eyebrow type role.

struct ScratchLabStepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(ScratchLabDesign.Sem.accent.opacity(0.16)))
                .overlay(Circle().stroke(ScratchLabDesign.Sem.accent.opacity(0.35), lineWidth: 1))

            Text(title.uppercased())
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(.secondary)
                .kerning(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)")
    }
}

// MARK: - SemanticErrorListView
//
// Reusable list of the formal TIMING / PLATTER / FADER semantic errors
// (`SemanticError`, from `ScratchPerformanceComparison`). Renders only the
// most actionable errors first — the derivation already sorts timing →
// platter → fader — each as one concise row: a monospaced family eyebrow, a
// direct kind label, and the performed-side explanation. The expected
// behaviour stays available as a hover tooltip so the full expected →
// performed pair is reachable without cluttering the row. Family colour is a
// restrained accent, never a full-red wash.

struct SemanticErrorListView: View {
    let errors: [SemanticError]
    var maxErrors: Int = 4

    private var visible: [SemanticError] {
        Array(errors.prefix(maxErrors))
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, error in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(error.familyLabel)
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(Self.familyColor(error.family))
                            .kerning(0.4)
                        Text(error.kindLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(error.performed)
                            .font(ScratchLabDesign.Typo.bodySecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(error.expected)
                }
            }
        }
    }

    private static func familyColor(_ family: SemanticError.Family) -> Color {
        switch family {
        case .timing: return ScratchLabDesign.Sem.warning
        case .platter: return ScratchLabDesign.Sem.info
        case .fader:  return ScratchLabDesign.Notation.fader
        }
    }
}
