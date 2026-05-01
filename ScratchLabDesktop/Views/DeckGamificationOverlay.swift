import SwiftUI

struct DeckGamificationOverlay: View {
    @ObservedObject var detector: MacCaptureEngine
    @State private var zoneMoveSnapshots: [DJRigZone.Role: MacCaptureEngine.ZoneAdjustment] = [:]
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

                if detector.showRigGuides {
                    rigStatusCard
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var isInteractiveCalibrationVisible: Bool {
        detector.showRigGuides && !detector.calibrationLocked
    }

    private func overlayContent(layout: DJRigLayout, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                ForEach(layout.zones) { zone in
                    let rect = convert(zone.boundingBox, in: size)
                    let isHighlighted = detector.highlightedZoneRole == zone.role

                    if detector.showRigGuides {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(zoneColor(for: zone.role), lineWidth: isHighlighted ? 5 : 3)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(zoneColor(for: zone.role).opacity(isHighlighted ? 0.18 : 0.08))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)

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

                    if isHighlighted {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .bold))
                            Text(detector.showRigGuides ? "Next scratch target" : "Target")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .systemGreen), in: Capsule())
                        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
                        .position(x: rect.midX, y: min(rect.maxY - 24, size.height - 24))
                    }
                }

                if let walkerPoint = characterPoint(in: layout, size: size) {
                    Image(systemName: "figure.walk.circle.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
                        .position(walkerPoint)
                        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: detector.highlightedZoneRole)
                }
            }
            .allowsHitTesting(false)

            if isInteractiveCalibrationVisible {
                interactiveZoneCalibrationLayer(layout: layout, size: size)
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

    private var rigStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detector.rigStatusTitle)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

            Text(detector.rigStatusDetail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func characterPoint(in layout: DJRigLayout, size: CGSize) -> CGPoint? {
        guard let zone = layout.zone(for: detector.highlightedZoneRole) else { return nil }
        let rect = convert(zone.boundingBox, in: size)
        return CGPoint(x: rect.midX, y: min(rect.maxY - 18, size.height - 24))
    }

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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, dash: [10, 6]))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.015))
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            calibrationBadge(title: "Position \(zone.role.title)", systemImage: "move.3d")
                .position(x: rect.midX, y: max(rect.minY - 18, 28))

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
                    zoneResizeSnapshots[activeZoneInteraction.role] = nil
                }
                activeZoneInteraction = nil
            }
    }

    private func zoneInteraction(at point: CGPoint, layout: DJRigLayout, size: CGSize) -> ZoneInteraction? {
        let zoneRects = layout.zones.map { zone in
            (zone: zone, rect: convert(zone.boundingBox, in: size))
        }

        for zoneRect in zoneRects.reversed() {
            let handleRect = CGRect(
                x: zoneRect.rect.maxX - 28,
                y: zoneRect.rect.maxY - 28,
                width: 36,
                height: 36
            )
            if handleRect.contains(point) {
                return ZoneInteraction(role: zoneRect.zone.role, kind: .resize)
            }
        }

        if let matchingZone = zoneRects.first(where: { $0.rect.contains(point) }) {
            return ZoneInteraction(role: matchingZone.zone.role, kind: .move)
        }

        return nil
    }

    private func applyZoneMoveDrag(_ value: DragGesture.Value, role: DJRigZone.Role, size: CGSize) {
        let snapshot = zoneMoveSnapshots[role] ?? detector.zoneAdjustment(for: role)
        zoneMoveSnapshots[role] = snapshot

        let deltaX = Double(value.translation.width / max(size.width, 1))
        let deltaY = Double(-value.translation.height / max(size.height, 1))

        detector.updateZoneAdjustment(for: role) { adjustment in
            adjustment.offsetX = clamp(snapshot.offsetX + deltaX, within: detector.calibrationOffsetRange)
            adjustment.offsetY = clamp(snapshot.offsetY + deltaY, within: detector.calibrationOffsetRange)
        }
    }

    private func applyZoneResizeDrag(_ value: DragGesture.Value, zone: DJRigZone, size: CGSize) {
        let snapshot = zoneResizeSnapshots[zone.role] ?? ZoneResizeSnapshot(
            adjustment: detector.zoneAdjustment(for: zone.role),
            boundingBox: zone.boundingBox
        )
        zoneResizeSnapshots[zone.role] = snapshot

        let deltaWidth = Double(value.translation.width / max(size.width, 1))
        let deltaHeight = Double(value.translation.height / max(size.height, 1))
        let currentWidth = max(Double(snapshot.boundingBox.width), 0.08)
        let currentHeight = max(Double(snapshot.boundingBox.height), 0.08)
        let targetWidth = max(currentWidth + deltaWidth, 0.18)
        let targetHeight = max(currentHeight + deltaHeight, 0.18)

        detector.updateZoneAdjustment(for: zone.role) { adjustment in
            adjustment.widthScale = clamp(
                snapshot.adjustment.widthScale * (targetWidth / currentWidth),
                within: detector.calibrationScaleRange
            )
            adjustment.heightScale = clamp(
                snapshot.adjustment.heightScale * (targetHeight / currentHeight),
                within: detector.calibrationScaleRange
            )
            adjustment.offsetX = clamp(
                snapshot.adjustment.offsetX + (deltaWidth / 2),
                within: detector.calibrationOffsetRange
            )
            adjustment.offsetY = clamp(
                snapshot.adjustment.offsetY - (deltaHeight / 2),
                within: detector.calibrationOffsetRange
            )
        }
    }

    private func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct ZoneResizeSnapshot {
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
