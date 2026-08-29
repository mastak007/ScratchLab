import SwiftUI

// The canonical cross-platform ScratchNotationPanel — the shared TARGET / MY
// PERFORMANCE notation card approved in Figma (component `ScratchNotationPanel`,
// node 148:123; three modes Target / Live / Review; presentation Standard /
// Compact).
//
// This view owns presentation ONLY — the mode header, the lane label, the
// transparent spacing envelope, and which `ScratchNotationPanelPresentation`
// size is shown. It
// contributes no notation geometry or drawing of its own: the lane itself is
// `ScratchPhraseChartView`, the single renderer both platforms already compile
// against (`ScratchStrokeGeometry` → `ScratchMotionRenderer`, turnaround
// anchors, direction cues, binary OPEN/CLOSED fader rails, playhead). Because
// macOS, iPhone, and iPad all draw through that one implementation, a panel
// means the same thing everywhere by construction — there is no per-platform
// notation renderer to keep in sync.

/// Which side of the Target/Performance comparison a panel instance shows.
/// Governs the label text and accent color only; the actual data drawn is
/// supplied via `source`.
enum ScratchNotationPanelLane: Equatable, Sendable {
    case target
    case performance
}

/// Panel density — Standard (full detail) or Compact (narrower device chrome).
enum ScratchNotationPanelPresentation: Equatable, Sendable {
    case standard
    case compact
}

/// Panel mode — the Figma variant axis. Target = a single reference lane;
/// Live = target + live performance; Review = target + captured performance.
/// Governs the composed header and the performance lane's label.
enum ScratchNotationPanelMode: Equatable, Sendable {
    case targetReference
    case liveComparison
    case reviewComparison

    var headerTitle: String {
        switch self {
        case .targetReference: return "TARGET REFERENCE"
        case .liveComparison:  return "LIVE COMPARISON"
        case .reviewComparison: return "REVIEW COMPARISON"
        }
    }

    /// The performance lane's label. `.target` lanes are mode-independent.
    var performanceLabel: String {
        switch self {
        case .liveComparison: return "MY PERFORMANCE — LIVE"
        case .targetReference, .reviewComparison: return "MY PERFORMANCE — CAPTURED"
        }
    }
}

struct ScratchNotationPanel: View {
    let lane: ScratchNotationPanelLane
    let presentation: ScratchNotationPanelPresentation
    let source: ScratchPhraseChartView.ChartSource
    var bpm: Double = 90
    /// The shared comparison-domain window (`ScratchPhraseChartComparisonDomain
    /// .commonDomain(targetDuration:)`), applied as `targetWindow` when
    /// `lane == .target` and `capturedWindow` when `lane == .performance` — so
    /// a stacked Target/Performance pair passing the SAME `domain` always maps
    /// identical musical time to identical x, without either panel deriving
    /// its own window. `nil` renders the source's own full span.
    var domain: ClosedRange<TimeInterval>? = nil
    /// Captured fader spans for a `.performedPlatter` source. Ignored by
    /// `.target`, `.captured`, and `.empty` sources.
    var performedFaderSpans: [LaneFaderSpan] = []
    /// The TARGET's raw vertical frame, passed to a `.performedPlatter` source
    /// so both rows of a stacked comparison share one platter Y frame.
    var performedFrame: ClosedRange<CGFloat>? = nil
    var comparisonOverlay: ScratchComparisonOverlay? = nil
    /// Shared playhead time, in the same seconds domain as `domain`. `nil`
    /// hides the playhead — this view never derives its own clock/time state.
    var playheadTime: TimeInterval? = nil
    /// Mode used to resolve the performance lane's label; `.target` lanes are
    /// mode-independent ("TARGET — COPY THIS").
    var mode: ScratchNotationPanelMode = .reviewComparison

    private var isCompact: Bool { presentation == .compact }

    private var laneTitle: String {
        switch lane {
        case .target:      return "TARGET — COPY THIS"
        case .performance: return mode.performanceLabel
        }
    }

    /// Lane label colour follows the Figma trace identity: muted bone for the
    /// target, strong cyan for the performance. Never a status colour.
    private var laneColor: Color {
        switch lane {
        case .target:      return ScratchLabDesign.Notation.targetTrace
        case .performance: return ScratchLabDesign.Notation.performanceTrace
        }
    }

    /// Figma-aligned notation is drawn without a backing card/canvas. Target
    /// and performance remain distinct through their trace tokens and labels,
    /// not through opaque rectangles that obscure live camera context.
    private var laneBackground: Color {
        .clear
    }

    // Figma specifies a 72pt inner-lane height for Compact, but that mock
    // draws no OPEN/CLOSED text. `ScratchPhraseChartView`'s fader-lane rail
    // labels sit at fixed fractions of the canvas height (topY/bottomY at
    // 0.745H/0.964H for a 30% fader-lane-fraction); the OPEN/CLOSED text
    // needs ~20pt of separation to avoid colliding. 96pt is the smallest
    // measured height with a comfortable margin — a presentation-only choice
    // inside this wrapper; `ScratchPhraseChartView`'s own layout is unmodified.
    /// Optional container-driven lane height — e.g. the macOS dominant teaching
    /// surface asks for a taller lane than the Standard/Compact card defaults.
    /// `nil` falls back to the Standard/Compact heights.
    var canvasHeightOverride: CGFloat? = nil
    private var canvasHeight: CGFloat { canvasHeightOverride ?? (isCompact ? 96 : 118) }

    private var cardPadding: CGFloat {
        isCompact ? ScratchLabDesign.Card.compactPadding : ScratchLabDesign.Card.padding
    }

    /// Descriptive, non-colour accessibility summary of what this lane shows —
    /// VoiceOver reads the lane identity plus what the source contains, never a
    /// colour.
    private var accessibilitySummary: String {
        switch source {
        case .target: return "\(laneTitle) — target reference notation"
        case .performedPlatter: return "\(laneTitle) — measured performance"
        case .captured: return "\(laneTitle) — captured evidence"
        case .empty(let message): return "Notation unavailable — \(message)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
            Text(laneTitle)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(laneColor)
                .lineLimit(1)

            ScratchPhraseChartView(
                source: source,
                bpm: bpm,
                targetWindow: Self.chartWindow(lane: lane, domain: domain).target,
                capturedWindow: Self.chartWindow(lane: lane, domain: domain).captured,
                playheadTime: playheadTime ?? 0,
                showPlayhead: playheadTime != nil,
                comparisonOverlay: comparisonOverlay,
                performedFaderSpans: performedFaderSpans,
                performedFrame: performedFrame,
                backgroundColor: laneBackground
            )
            .frame(height: canvasHeight)
            .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Card.compactCornerRadius, style: .continuous))
        }
        .padding(cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text("Canonical scratch notation: platter lane above the fader lane, with one playhead"))
    }

    /// Pure routing of the shared comparison `domain` into `ScratchPhraseChartView`'s
    /// two window parameters — `.target` sources read `targetWindow`, every
    /// other source reads `capturedWindow`. Exposed so the routing itself
    /// (not just the rendered pixels) is directly testable.
    static func chartWindow(
        lane: ScratchNotationPanelLane,
        domain: ClosedRange<TimeInterval>?
    ) -> (target: ClosedRange<TimeInterval>?, captured: ClosedRange<TimeInterval>?) {
        switch lane {
        case .target:      return (domain, nil)
        case .performance: return (nil, domain)
        }
    }
}

// MARK: - Composed comparison panel

/// The Figma `ScratchNotationPanel` in its Target / Live / Review composition:
/// a mode header plus one (Target) or two (Live/Review) stacked lanes sharing
/// one time domain. This is a pure presentation wrapper over `ScratchNotationPanel`
/// — it derives no state and owns no clock; callers supply the target notation,
/// optional performed evidence, and shared playhead time.
struct ScratchNotationComparisonPanel: View {
    let mode: ScratchNotationPanelMode
    let presentation: ScratchNotationPanelPresentation
    let target: ScratchNotation
    /// Measured performed strokes for the `.performance` lane. `nil` renders
    /// the target lane only (`.targetReference`).
    let performed: [CaptureCore.DetectedNotationRecordMovementEvent]?
    var bpm: Double = 90
    var domain: ClosedRange<TimeInterval>? = nil
    var performedFaderSpans: [LaneFaderSpan] = []
    var performedFrame: ClosedRange<CGFloat>? = nil
    var comparisonOverlay: ScratchComparisonOverlay? = nil
    var playheadTime: TimeInterval? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Text(mode.headerTitle)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            ScratchNotationPanel(
                lane: .target,
                presentation: presentation,
                source: .target(target),
                bpm: bpm,
                domain: domain,
                comparisonOverlay: comparisonOverlay,
                playheadTime: playheadTime,
                mode: mode
            )

            if let performed {
                ScratchNotationPanel(
                    lane: .performance,
                    presentation: presentation,
                    source: .performedPlatter(performed),
                    bpm: bpm,
                    domain: domain,
                    performedFaderSpans: performedFaderSpans,
                    performedFrame: performedFrame,
                    playheadTime: playheadTime,
                    mode: mode
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}
