import SwiftUI

struct CaptureGuideEditModel {
    static let normalizedBounds = CGRect(x: 0.01, y: 0.02, width: 0.98, height: 0.96)

    /// Minimum visible margin (in points) between a draggable overlay edge and
    /// the canvas edge.  Shared by all three zones (left deck, mixer, right deck).
    static let canvasInset: CGFloat = 12

    /// Clamp a pixel-space rectangle so every edge stays within `canvasSize`
    /// with at least `inset` points of visible margin.
    ///
    /// When the overlay is larger than the inset-reduced canvas the rectangle
    /// is centered in the tightest available axis rather than producing NaN or
    /// inverted ranges.
    static func clampRect(_ rect: CGRect, to canvasSize: CGSize, inset: CGFloat) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let minX = inset
        let maxX = canvasSize.width - inset
        let minY = inset
        let maxY = canvasSize.height - inset

        let availableWidth = maxX - minX
        let availableHeight = maxY - minY

        // If the overlay is wider than the available canvas, center it
        // horizontally so we don't produce an inverted range.
        let clampedX: CGFloat
        if rect.width >= availableWidth {
            clampedX = minX + (availableWidth - rect.width) / 2
        } else {
            clampedX = min(max(rect.minX, minX), maxX - rect.width)
        }

        // Same for height — center if the overlay is taller than the canvas.
        let clampedY: CGFloat
        if rect.height >= availableHeight {
            clampedY = minY + (availableHeight - rect.height) / 2
        } else {
            clampedY = min(max(rect.minY, minY), maxY - rect.height)
        }

        return CGRect(x: clampedX, y: clampedY, width: rect.width, height: rect.height)
    }

    /// Compute normalized-offset deltas from a pixel-space drag operation.
    ///
    /// Takes a pixel-space snapshot rect (the overlay's position at drag-start,
    /// from `convert(zone.boundingBox)`), the total gesture translation, and
    /// the canvas size + inset, then returns the (dx, dy) deltas to add to the
    /// snapshot `ZoneAdjustment.offsetX` / `.offsetY`.
    ///
    /// With zero translation this returns (0, 0) — no jump.
    static func pixelDragDeltas(
        pixelSnapshot: CGRect,
        translation: CGSize,
        canvasSize: CGSize,
        inset: CGFloat
    ) -> (dx: Double, dy: Double) {
        let proposedRect = pixelSnapshot.offsetBy(
            dx: translation.width,
            dy: translation.height
        )
        let clampedRect = clampRect(proposedRect, to: canvasSize, inset: inset)
        let dx = Double((clampedRect.midX - pixelSnapshot.midX) / max(canvasSize.width, 1))
        let dy = Double(-(clampedRect.midY - pixelSnapshot.midY) / max(canvasSize.height, 1))
        return (dx, dy)
    }

    static func isEditable(
        showRigGuides: Bool,
        calibrationLocked: Bool,
        isUsingManualRigGuide: Bool
    ) -> Bool {
        showRigGuides && (!calibrationLocked || isUsingManualRigGuide)
    }

    /// Pure presentation calculation for the zone-guide opacity — extracted
    /// so it's unit-testable directly instead of via SwiftUI view
    /// introspection. Full opacity while editable; `lockedOpacity` (a
    /// per-call-site parameter, ~0.15–0.20 for a subtle, non-obstructive
    /// guide) otherwise. `DeckGamificationOverlay`'s own default
    /// (`lockedOpacity: 0`) preserves the exact prior fully-invisible
    /// behavior for callers that don't opt into a visible locked state.
    static func guideOpacity(isEditable: Bool, lockedOpacity: Double) -> Double {
        isEditable ? 1.0 : lockedOpacity
    }

    /// Pure recording-guard decision, extracted from `handleRoutineRecordingButton`
    /// for direct unit testing. True exactly when starting a take must be
    /// refused because calibration editing is still open — never fires
    /// while already recording (that's a Stop, not a Start).
    static func recordActionIsBlockedByCalibration(isRoutineRecording: Bool, calibrationLocked: Bool) -> Bool {
        !isRoutineRecording && !calibrationLocked
    }

    static func movedAdjustment(
        from snapshot: MacCaptureEngine.ZoneAdjustment,
        translation: CGSize,
        boundingBox: CGRect,
        canvasSize: CGSize,
        offsetRange: ClosedRange<Double>,
        scaleRange: ClosedRange<Double>
    ) -> MacCaptureEngine.ZoneAdjustment {
        let deltaX = Double(translation.width / max(canvasSize.width, 1))
        let deltaY = Double(-translation.height / max(canvasSize.height, 1))
        let proposed = MacCaptureEngine.ZoneAdjustment(
            offsetX: snapshot.offsetX + deltaX,
            offsetY: snapshot.offsetY + deltaY,
            widthScale: snapshot.widthScale,
            heightScale: snapshot.heightScale
        )
        return clampedAdjustment(
            proposed,
            boundingBox: boundingBox,
            offsetRange: offsetRange,
            scaleRange: scaleRange
        )
    }

    static func resizedAdjustment(
        from snapshot: ZoneResizeSnapshot,
        translation: CGSize,
        canvasSize: CGSize,
        offsetRange: ClosedRange<Double>,
        scaleRange: ClosedRange<Double>
    ) -> MacCaptureEngine.ZoneAdjustment {
        let deltaWidth = Double(translation.width / max(canvasSize.width, 1))
        let deltaHeight = Double(translation.height / max(canvasSize.height, 1))
        let currentWidth = max(Double(snapshot.boundingBox.width), 0.08)
        let currentHeight = max(Double(snapshot.boundingBox.height), 0.08)
        let targetWidth = max(currentWidth + deltaWidth, 0.18)
        let targetHeight = max(currentHeight + deltaHeight, 0.18)

        let proposed = MacCaptureEngine.ZoneAdjustment(
            offsetX: snapshot.adjustment.offsetX + (deltaWidth / 2),
            offsetY: snapshot.adjustment.offsetY - (deltaHeight / 2),
            widthScale: snapshot.adjustment.widthScale * (targetWidth / currentWidth),
            heightScale: snapshot.adjustment.heightScale * (targetHeight / currentHeight)
        )
        return clampedAdjustment(
            proposed,
            boundingBox: snapshot.boundingBox,
            offsetRange: offsetRange,
            scaleRange: scaleRange
        )
    }

    private static func clampedAdjustment(
        _ adjustment: MacCaptureEngine.ZoneAdjustment,
        boundingBox: CGRect,
        offsetRange: ClosedRange<Double>,
        scaleRange: ClosedRange<Double>
    ) -> MacCaptureEngine.ZoneAdjustment {
        let widthScale = clamp(adjustment.widthScale, within: scaleRange)
        let heightScale = clamp(adjustment.heightScale, within: scaleRange)
        let scaledWidth = min(max(Double(boundingBox.width) * widthScale, 0.05), Double(normalizedBounds.width))
        let scaledHeight = min(max(Double(boundingBox.height) * heightScale, 0.05), Double(normalizedBounds.height))

        let unclampedCenterX = Double(boundingBox.midX) + adjustment.offsetX
        let unclampedCenterY = Double(boundingBox.midY) + adjustment.offsetY
        let minCenterX = Double(normalizedBounds.minX) + (scaledWidth / 2)
        let maxCenterX = Double(normalizedBounds.maxX) - (scaledWidth / 2)
        let minCenterY = Double(normalizedBounds.minY) + (scaledHeight / 2)
        let maxCenterY = Double(normalizedBounds.maxY) - (scaledHeight / 2)

        let clampedCenterX = min(max(unclampedCenterX, minCenterX), maxCenterX)
        let clampedCenterY = min(max(unclampedCenterY, minCenterY), maxCenterY)

        return MacCaptureEngine.ZoneAdjustment(
            offsetX: clamp(clampedCenterX - Double(boundingBox.midX), within: offsetRange),
            offsetY: clamp(clampedCenterY - Double(boundingBox.midY), within: offsetRange),
            widthScale: widthScale,
            heightScale: heightScale
        )
    }

    private static func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct DeckGamificationOverlay: View {
    @ObservedObject var detector: MacCaptureEngine
    /// Opacity for the zone guides while calibration is locked. Default `0`
    /// preserves the exact prior fully-invisible-when-locked behavior — the
    /// Performer Monitor call site never even reaches this branch (its own
    /// `if captureEngine.showRigGuides` wrapper already omits this view
    /// entirely while locked, unchanged). Practice/Capture's
    /// `CalibrationCameraOverlay` passes ~0.15–0.20 for a subtle,
    /// non-obstructive persistent guide instead.
    var lockedOpacity: Double = 0
    // Slice X.1.1: this used to be a hardcoded `false`, which collapsed
    // every overlay box to opacity 0 and disabled hit-testing — meaning
    // the deck/mixer calibration boxes were INVISIBLE everywhere even
    // when calibration was unlocked, making no-watch capture
    // unconfigurable. Restore the original intent by deriving edit mode
    // from the same `CaptureGuideEditModel.isEditable` helper that gates
    // the interactive layer.
    private var isCalibrationEditMode: Bool {
        CaptureGuideEditModel.isEditable(
            showRigGuides: detector.showRigGuides,
            calibrationLocked: detector.calibrationLocked,
            isUsingManualRigGuide: detector.isUsingManualRigGuide
        )
    }
    @State private var zoneMoveSnapshots: [DJRigZone.Role: MacCaptureEngine.ZoneAdjustment] = [:]
    @State private var zoneMovePixelSnapshots: [DJRigZone.Role: CGRect] = [:]
    @State private var zoneResizeSnapshots: [DJRigZone.Role: ZoneResizeSnapshot] = [:]
    @State private var activeZoneInteraction: ZoneInteraction?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let layout = detector.rigLayout {
                    overlayContent(layout: layout, size: proxy.size)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rig guide waiting")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Show both decks and the mixer to build a playable overlay over your setup.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
                }

                topHud
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
    }

    private var isInteractiveCalibrationVisible: Bool {
        CaptureGuideEditModel.isEditable(
            showRigGuides: detector.showRigGuides,
            calibrationLocked: detector.calibrationLocked,
            isUsingManualRigGuide: detector.isUsingManualRigGuide
        )
    }

    private func overlayContent(layout: DJRigLayout, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                ForEach(layout.zones) { zone in
                    let rect = convert(zone.boundingBox, in: size)
                    let isHighlighted = detector.highlightedZoneRole == zone.role
                    // Guides render whenever a rig layout exists, not only
                    // while `showRigGuides` (unlocked) — this is what keeps
                    // them visible-but-faint at `lockedOpacity` when locked,
                    // instead of disappearing entirely. Performer Monitor is
                    // unaffected: its own call site only instantiates this
                    // whole view while `showRigGuides` (unlocked) is true.
                    let editMode = isInteractiveCalibrationVisible
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(zoneColor(for: zone.role), lineWidth: isHighlighted ? 4 : (editMode ? 2.5 : 1.2))
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(zoneColor(for: zone.role).opacity(isHighlighted ? 0.16 : (editMode ? 0.08 : 0.03)))
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    if editMode {
                        // Minimal labels are editable-only — locked mode
                        // shows no label chrome at all, per the "minimal
                        // labels when locked" requirement.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(zone.role.title)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)

                            Text(zoneHint(for: zone.role))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .position(x: rect.midX, y: max(rect.minY + 28, 32))
                    }
                }
            }
            .allowsHitTesting(false)
            .opacity(CaptureGuideEditModel.guideOpacity(isEditable: isCalibrationEditMode, lockedOpacity: lockedOpacity))
            .allowsHitTesting(isCalibrationEditMode)

            if isInteractiveCalibrationVisible {
                interactiveZoneCalibrationLayer(layout: layout, size: size)
                    .opacity(isCalibrationEditMode ? 1 : 0)
                    .allowsHitTesting(isCalibrationEditMode)
            }
        }
    }

    private func interactiveZoneCalibrationLayer(layout: DJRigLayout, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.zones) { zone in
                let rect = convert(zone.boundingBox, in: size)
                interactiveZoneControls(for: zone, rect: rect, size: size)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(2)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(interactiveCalibrationGesture(layout: layout, size: size))
    }

    private var topHud: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: index < detector.visibleStarCount ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(index < detector.visibleStarCount ? Color(nsColor: .systemGreen) : Color.white.opacity(0.35))
                }
            }

            Text("Stars won: \(detector.sessionStars)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.7), in: Capsule())
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: detector.sessionStars)
    }

    /// Pure coordinate conversion from normalized Vision space (origin
    /// bottom-left) to SwiftUI pixel space (origin top-left).  No clamping —
    /// the clamp is applied inside the drag gesture at the pixel level so the
    /// rendered rect always matches the underlying data.
    private func convert(_ normalizedRect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * size.width,
            y: (1 - normalizedRect.maxY) * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        )
    }

    private func zoneColor(for role: DJRigZone.Role) -> Color {
        switch role {
        case .leftDeck:
            return Color(nsColor: .systemBlue)
        case .mixer:
            return Color(nsColor: .systemOrange)
        case .rightDeck:
            return Color(nsColor: .systemPink)
        }
    }

    private func zoneHint(for role: DJRigZone.Role) -> String {
        switch role {
        case .leftDeck:
            return "Scratch surface"
        case .mixer:
            return "Crossfader lane"
        case .rightDeck:
            return "Cue / second deck"
        }
    }

    private func calibrationBadge(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.92), in: Capsule())
        .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 4)
    }

    private func interactiveZoneControls(for zone: DJRigZone, rect: CGRect, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Dashed outline
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, dash: [10, 6]))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.015))
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Label badge (non-interactive — informational only)
            calibrationBadge(title: zone.role.title, systemImage: "move.3d")
                .position(x: rect.midX, y: max(rect.minY - 18, 28))

            // Move handle — visible grab affordance at the top of each overlay.
            // Only this area + the resize handle are interactive.
            moveHandlePill(for: zone, rect: rect)
                .position(x: rect.midX, y: rect.minY + 22)

            // Resize handle (bottom-right corner)
            Circle()
                .fill(Color.white)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 3)
                .position(x: rect.maxX - 10, y: rect.maxY - 10)
        }
    }

    /// A small pill-shaped handle at the top of each overlay that signals
    /// "drag here to move."  Uses a contrasting semi-transparent look so it is
    /// visible over both light and dark camera feeds.
    private func moveHandlePill(for zone: DJRigZone, rect: CGRect) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 9, weight: .bold))
            Text("Drag to move")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.5), lineWidth: 0.8)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
    }

    private func interactiveCalibrationGesture(layout: DJRigLayout, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeZoneInteraction == nil {
                    activeZoneInteraction = zoneInteraction(at: value.startLocation, layout: layout, size: size)
                }

                guard let activeZoneInteraction else { return }

                switch activeZoneInteraction.kind {
                case .move:
                    applyZoneMoveDrag(value, role: activeZoneInteraction.role, size: size)
                case .resize:
                    guard let zone = layout.zone(for: activeZoneInteraction.role) else { return }
                    applyZoneResizeDrag(value, zone: zone, size: size)
                }
            }
            .onEnded { _ in
                if let activeZoneInteraction {
                    zoneMoveSnapshots[activeZoneInteraction.role] = nil
                    zoneMovePixelSnapshots[activeZoneInteraction.role] = nil
                    zoneResizeSnapshots[activeZoneInteraction.role] = nil
                }
                activeZoneInteraction = nil
                // Persist the final position once, after the drag ends.
                detector.persistCurrentZoneAdjustments()
            }
    }

    /// Determines which zone and interaction kind the given point (in the
    /// canvas's local pixel coordinate space) maps to.
    ///
    /// Priority order:
    /// 1. Resize handle (bottom-right 36×36 area of each zone)
    /// 2. Move handle (top-center pill, ~144×36 pt area)
    ///
    /// The body of the overlay is intentionally NOT a move target — only the
    /// dedicated handle areas trigger interactions.
    private func zoneInteraction(at point: CGPoint, layout: DJRigLayout, size: CGSize) -> ZoneInteraction? {
        let zoneRects = layout.zones.map { zone in
            (zone: zone, rect: convert(zone.boundingBox, in: size))
        }

        for zoneRect in zoneRects.reversed() {
            // Resize handle: bottom-right corner
            let resizeHandleRect = CGRect(
                x: zoneRect.rect.maxX - 28,
                y: zoneRect.rect.maxY - 28,
                width: 36,
                height: 36
            )
            if resizeHandleRect.contains(point) {
                return ZoneInteraction(role: zoneRect.zone.role, kind: .resize)
            }

            // Move handle: top-center pill area
            let moveHandleWidth: CGFloat = min(zoneRect.rect.width * 0.65, 160)
            let moveHandleHeight: CGFloat = 36
            let moveHandleRect = CGRect(
                x: zoneRect.rect.midX - moveHandleWidth / 2,
                y: zoneRect.rect.minY,
                width: moveHandleWidth,
                height: moveHandleHeight
            )
            if moveHandleRect.contains(point) {
                return ZoneInteraction(role: zoneRect.zone.role, kind: .move)
            }
        }

        return nil
    }

    /// Applies a move-drag by operating in pixel space, clamping with the
    /// shared `clampRect` helper, then converting the clamped delta back to
    /// a normalized zone-adjustment change.
    ///
    /// This avoids the jump that would occur if the rendered pixel rect
    /// (possibly clamped by different margins) were out of sync with the
    /// underlying normalized `zone.boundingBox`.
    private func applyZoneMoveDrag(_ value: DragGesture.Value, role: DJRigZone.Role, size: CGSize) {
        guard let zone = detector.rigLayout?.zone(for: role) else { return }

        // First tick: snapshot the current adjustment AND the current pixel rect.
        if zoneMoveSnapshots[role] == nil {
            zoneMoveSnapshots[role] = detector.zoneAdjustment(for: role)
            zoneMovePixelSnapshots[role] = convert(zone.boundingBox, in: size)
        }

        guard let adjustmentSnapshot = zoneMoveSnapshots[role],
              let pixelSnapshot = zoneMovePixelSnapshots[role] else { return }

        let (deltaX, deltaY) = CaptureGuideEditModel.pixelDragDeltas(
            pixelSnapshot: pixelSnapshot,
            translation: value.translation,
            canvasSize: size,
            inset: CaptureGuideEditModel.canvasInset
        )

        detector.updateZoneAdjustmentTransient(for: role) { adjustment in
            adjustment.offsetX = adjustmentSnapshot.offsetX + deltaX
            adjustment.offsetY = adjustmentSnapshot.offsetY + deltaY
            adjustment.widthScale = adjustmentSnapshot.widthScale
            adjustment.heightScale = adjustmentSnapshot.heightScale
        }
    }

    /// Resize drag — unchanged from the original implementation.  The resize
    /// handle is the dedicated bottom-right corner circle.
    private func applyZoneResizeDrag(_ value: DragGesture.Value, zone: DJRigZone, size: CGSize) {
        let snapshot = zoneResizeSnapshots[zone.role] ?? ZoneResizeSnapshot(
            adjustment: detector.zoneAdjustment(for: zone.role),
            boundingBox: zone.boundingBox
        )
        zoneResizeSnapshots[zone.role] = snapshot

        detector.updateZoneAdjustmentTransient(for: zone.role) { adjustment in
            adjustment = CaptureGuideEditModel.resizedAdjustment(
                from: snapshot,
                translation: value.translation,
                canvasSize: size,
                offsetRange: detector.calibrationOffsetRange,
                scaleRange: detector.calibrationScaleRange
            )
        }
    }
}

struct ZoneResizeSnapshot {
    let adjustment: MacCaptureEngine.ZoneAdjustment
    let boundingBox: CGRect
}

private struct ZoneInteraction {
    enum Kind {
        case move
        case resize
    }

    let role: DJRigZone.Role
    let kind: Kind
}
