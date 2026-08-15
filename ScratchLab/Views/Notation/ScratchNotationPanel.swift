import SwiftUI

// The canonical cross-platform ScratchNotationPanel — the shared TARGET / MY
// PERFORMANCE notation card approved in Figma (component `ScratchNotationPanel`,
// node 25:46, four variants: Lane × {Target, Performance}, Presentation ×
// {Standard, Compact}).
//
// This view owns presentation ONLY — the label, the card chrome, and which
// `ScratchNotationPanelPresentation` size is shown. It contributes no notation
// geometry or drawing of its own: the lane itself is `ScratchPhraseChartView`,
// the existing renderer both platforms already compile against
// (`ScratchStrokeGeometry` → `ScratchMotionRenderer`, turnaround anchors,
// direction cues, binary OPEN/CLOSED fader rails, playhead). Because macOS,
// iPhone, and iPad all draw through that one implementation, a panel means the
// same thing everywhere by construction — there is no per-platform notation
// renderer to keep in sync.

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

    private var isCompact: Bool { presentation == .compact }

    private var laneTitle: String {
        switch lane {
        case .target:      return "TARGET"
        case .performance: return "MY PERFORMANCE"
        }
    }

    private var laneColor: Color {
        switch lane {
        case .target:      return ScratchLabDesign.Sem.accent
        case .performance: return ScratchLabDesign.Sem.success
        }
    }

    // Figma specifies a 72pt inner-lane height for Compact, but that mock
    // draws no OPEN/CLOSED text. `ScratchPhraseChartView`'s fader-lane rail
    // labels sit at fixed fractions of the canvas height (topY/bottomY at
    // 0.745H/0.964H for a 30% fader-lane-fraction); the OPEN/CLOSED text
    // (measured line height 9pt at the chart's fixed 7.5pt font) needs
    // 0.219H ≥ 20pt of separation to avoid colliding, i.e. H ≥ ~91.3pt.
    // Measured by rendering H = 72...100 in 4pt steps: labels visibly
    // overlap through H=88, are just legible at H=92, and are cleanly
    // separated from H=96 on. 96pt is the smallest measured height with a
    // comfortable margin — this is a presentation-only choice inside this
    // wrapper; `ScratchPhraseChartView`'s own layout is unmodified and every
    // other (non-compact) consumer is unaffected. See the Phase 2 Compact
    // geometry reconciliation report: the true fix is a Figma spec
    // correction (72×126 compact contract → recommend a taller inner lane),
    // not a code workaround.
    private var canvasHeight: CGFloat { isCompact ? 96 : 118 }

    private var cornerRadius: CGFloat {
        isCompact ? ScratchLabDesign.Card.compactCornerRadius : ScratchLabDesign.Card.cornerRadius
    }

    private var cardPadding: CGFloat {
        isCompact ? ScratchLabDesign.Card.compactPadding : ScratchLabDesign.Card.padding
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
                performedFrame: performedFrame
            )
            .frame(height: canvasHeight)
            .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Card.compactCornerRadius, style: .continuous))
        }
        .padding(cardPadding)
        .background(
            ScratchLabDesign.Surface.card,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(ScratchLabDesign.Surface.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(laneTitle) notation"))
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
