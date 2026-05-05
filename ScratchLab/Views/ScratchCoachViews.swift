import SwiftUI
import QuartzCore

struct ScratchCoachCardTheme {
    let accentColor: Color
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let bubbleFill: Color
    let bubbleOutline: Color
    let illustrationFill: Color
    let detailFill: Color
    let controllerFill: Color
    let controllerTrackColor: Color
    let inactiveKnobColor: Color
}

private struct ScratchCoachSpeechBubbleView: View {
    let instruction: ScratchCoachInstruction
    let theme: ScratchCoachCardTheme

    private var speechText: String {
        let candidates = [
            instruction.instructionSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            instruction.coachScript.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }

        return candidates.min(by: { $0.count < $1.count }) ?? instruction.scratchDisplayName
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(theme.accentColor.opacity(0.92))

            VStack(alignment: .leading, spacing: 6) {
                Text(instruction.scratchDisplayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.primaryTextColor)

                Text(speechText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryTextColor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bubbleFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.bubbleOutline, lineWidth: 1)
        }
    }
}

private struct ScratchCoachBoothSurface: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.minY + rect.height * 0.06))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ScratchCoachRigLimb: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color
    let thickness: CGFloat

    var body: some View {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        let angle = Angle(radians: atan2(dy, dx))

        return Capsule()
            .fill(color)
            .frame(width: length, height: thickness)
            .rotationEffect(angle)
            .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }
}

struct ScratchCoachRigGeometry {
    // Clock positions are authored in coach/deck space and converted to front-facing viewer space using 180° rotation.
    static let clockPerspectiveRotationHours: Double = 6
    static let babyScratchHandStartCoachHour: Double = 9
    static let babyScratchHandEndCoachHour: Double = 11
    static let babyScratchStickerStartCoachHour: Double = 12
    static let babyScratchStickerEndCoachHour: Double = 2
    static let babyScratchHandStartAngleDegrees = viewerAngleDegrees(coachHour: babyScratchHandStartCoachHour)
    static let babyScratchHandEndAngleDegrees = viewerAngleDegrees(coachHour: babyScratchHandEndCoachHour)
    static let babyScratchStickerStartAngleDegrees = viewerAngleDegrees(coachHour: babyScratchStickerStartCoachHour)
    static let babyScratchStickerEndAngleDegrees = viewerAngleDegrees(coachHour: babyScratchStickerEndCoachHour)
    static let recordHandRadiusMultiplier: CGFloat = 0.92
    static let recordStickerRadiusMultiplier: CGFloat = 0.72

    static func recordHandUnitPoint(progress: Double) -> CGPoint {
        unitPoint(
            angleDegrees: interpolatedAngle(
                start: babyScratchHandStartAngleDegrees,
                end: babyScratchHandEndAngleDegrees,
                progress: progress
            ),
            radiusMultiplier: recordHandRadiusMultiplier
        )
    }

    static func recordHandPoint(center: CGPoint, radius: CGFloat, progress: Double) -> CGPoint {
        let unitPoint = recordHandUnitPoint(progress: progress)
        return CGPoint(
            x: center.x + radius * unitPoint.x,
            y: center.y + radius * unitPoint.y
        )
    }

    static func recordStickerUnitPoint(progress: Double = 0) -> CGPoint {
        unitPoint(
            angleDegrees: interpolatedAngle(
                start: babyScratchStickerStartAngleDegrees,
                end: babyScratchStickerEndAngleDegrees,
                progress: progress
            ),
            radiusMultiplier: recordStickerRadiusMultiplier
        )
    }

    static func recordStickerRotationDegrees(progress: Double) -> Double {
        interpolatedAngle(
            start: babyScratchStickerStartAngleDegrees,
            end: babyScratchStickerEndAngleDegrees,
            progress: progress
        ) - babyScratchStickerStartAngleDegrees
    }

    static func frontFacingViewerHour(coachHour: Double) -> Double {
        let shiftedHour = coachHour + clockPerspectiveRotationHours
        let wrappedHour = shiftedHour.truncatingRemainder(dividingBy: 12)
        return wrappedHour == 0 ? 12 : wrappedHour
    }

    static func viewerAngleDegrees(coachHour: Double) -> Double {
        let viewerHour = frontFacingViewerHour(coachHour: coachHour)
        return (viewerHour - 3) * 30
    }

    private static func interpolatedAngle(
        start: Double,
        end: Double,
        progress: Double
    ) -> Double {
        let clampedProgress = max(0, min(1, progress))
        return start + ((end - start) * clampedProgress)
    }

    private static func unitPoint(
        angleDegrees: Double,
        radiusMultiplier: CGFloat
    ) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: CGFloat(cos(radians)) * radiusMultiplier,
            y: CGFloat(sin(radians)) * radiusMultiplier
        )
    }
}

struct ScratchCoachRigView: View {
    let instruction: ScratchCoachInstruction
    let playbackTimeProvider: () -> TimeInterval
    let isPlayingProvider: () -> Bool
    let animationStateProvider: ((TimeInterval, Bool) -> ScratchCoachDemoAnimationState?)?
    let theme: ScratchCoachCardTheme

    @State private var demoMotionSampleBuffer: ScratchLabDemoAudioSampleBuffer?
    @State private var loadedDemoMotionAudioFile: String?

    private let sceneHeight: CGFloat = 196
    private static let babyScratchCrossfaderPosition = ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition
    private static let babyScratchLeftHandPose = CGPoint(x: 0.50, y: 0.66)
    private static let recordHandBasePose = ScratchCoachRigGeometry.recordHandUnitPoint(progress: 0)
    private static let recordStickerBasePose = ScratchCoachRigGeometry.recordStickerUnitPoint(progress: 0)
    private static let volumeFaderYRatio: CGFloat = 0.46
    private static let crossfaderYRatio: CGFloat = 0.80

    var body: some View {
        Group {
            if isPlayingProvider() {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                    rigContent(
                        playbackTime: playbackTimeProvider(),
                        isPlaying: isPlayingProvider()
                    )
                }
            } else {
                rigContent(
                    playbackTime: playbackTimeProvider(),
                    isPlaying: false
                )
            }
        }
        .task(id: demoMotionProfileTaskID) {
            await loadDemoMotionProfileIfNeeded()
        }
    }

    private func rigContent(
        playbackTime: TimeInterval,
        isPlaying: Bool
    ) -> some View {
        let updateStartedAt = CACurrentMediaTime()
        let animationState = ScratchLabPerformanceSignpost.withInterval("CoachRigUpdate") {
            resolvedAnimationState(
                playbackTime: playbackTime,
                isPlaying: isPlaying
            )
        }
        let updateDuration = CACurrentMediaTime() - updateStartedAt
        DispatchQueue.main.async {
            ScratchLabRuntimeDiagnostics.shared.recordCoachRigUpdate(
                durationSeconds: updateDuration
            )
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Coach Rig")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryTextColor)

                Spacer()

                Text(isPlaying ? "LIVE" : "READY")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(isPlaying ? theme.primaryTextColor : theme.secondaryTextColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        isPlaying
                            ? theme.accentColor.opacity(0.82)
                            : theme.detailFill,
                        in: Capsule()
                    )
            }

            GeometryReader { geometry in
                rigScene(
                    in: geometry.size,
                    animationState: animationState,
                    isPlaying: isPlaying
                )
            }
            .frame(height: sceneHeight)

            HStack(spacing: 8) {
                Label("Record hand", systemImage: "record.circle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryTextColor)

                Spacer(minLength: 0)

                Label(faderStateLabel(for: animationState), systemImage: animationState.crossfaderOpenState ? "slider.horizontal.3" : "pause.rectangle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryTextColor)
            }

            Text(faderCueText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryTextColor)
        }
        .padding(12)
        .background(theme.controllerFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("scratchlab-coach-rig")
    }

    private var hasCustomAnimationStateProvider: Bool {
        if case .some = animationStateProvider {
            return true
        }
        return false
    }

    private var demoMotionProfileTaskID: String {
        guard !hasCustomAnimationStateProvider, !isBabyScratch else { return "" }
        return Self.normalizedDemoAudioFileName(instruction.demoAudioFile) ?? ""
    }

    private func resolvedAnimationState(
        playbackTime: TimeInterval,
        isPlaying: Bool
    ) -> ScratchCoachDemoAnimationState {
        if let providedState = animationStateProvider?(playbackTime, isPlaying) {
            return providedState
        }

        guard isPlaying else {
            return isBabyScratch ? .babyScratchOpen : .neutral
        }

        if isBabyScratch {
            let pose = BabyScratchDemoPlaybackCoordinator.coachPose(for: playbackTime)
            return BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)
        }

        if Self.normalizedDemoAudioFileName(instruction.demoAudioFile) != nil {
            return demoMotionSampleBuffer?.coachRigAnimationState(
                scratchType: instruction.scratchType,
                playbackTime: playbackTime,
                isPlaying: isPlaying
            ) ?? (isBabyScratch ? .babyScratchOpen : .neutral)
        }

        return ScratchCoachDemoAnimator.state(
            scratchType: instruction.scratchType,
            playbackTime: playbackTime,
            isPlaying: isPlaying
        )
    }

    @MainActor
    private func loadDemoMotionProfileIfNeeded() async {
        guard !hasCustomAnimationStateProvider,
              !isBabyScratch,
              let audioFileName = Self.normalizedDemoAudioFileName(instruction.demoAudioFile) else {
            loadedDemoMotionAudioFile = nil
            demoMotionSampleBuffer = nil
            return
        }

        guard loadedDemoMotionAudioFile != audioFileName || demoMotionSampleBuffer == nil else {
            return
        }

        loadedDemoMotionAudioFile = audioFileName
        demoMotionSampleBuffer = nil

        guard let audioURL = ScratchCoachDemoAudioPlayer.bundledDemoAudioURL(named: audioFileName, in: .main) else {
            return
        }

        let sampleBuffer = await Task.detached(priority: .utility) {
            try? ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        }.value

        guard loadedDemoMotionAudioFile == audioFileName else { return }
        demoMotionSampleBuffer = sampleBuffer
    }

    private static func normalizedDemoAudioFileName(_ audioFileName: String?) -> String? {
        guard let audioFileName else { return nil }
        let trimmedName = audioFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private var isBabyScratch: Bool {
        switch normalizeScratchType(input: instruction.scratchType) {
        case "baby", "babyscratch":
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func rigScene(
        in size: CGSize,
        animationState: ScratchCoachDemoAnimationState,
        isPlaying: Bool
    ) -> some View {
        let normalizedScratchType = normalizeScratchType(input: instruction.scratchType)
        let isBabyScratch = normalizedScratchType == "baby" || normalizedScratchType == "babyscratch"
        let shoulderLineY = size.height * 0.29
        let torsoTopY = size.height * 0.33
        let boothTopY = size.height * 0.50
        let boothHeight = size.height * 0.40
        let platterCenter = CGPoint(x: size.width * 0.26, y: boothTopY + boothHeight * 0.46)
        let platterRadius = min(size.width * 0.14, size.height * 0.16)
        let mixerRect = CGRect(
            x: size.width * 0.56,
            y: boothTopY + boothHeight * 0.17,
            width: size.width * 0.18,
            height: boothHeight * 0.54
        )
        let crossfaderTrack = CGRect(
            x: mixerRect.minX + mixerRect.width * 0.18,
            y: mixerRect.minY + mixerRect.height * Self.crossfaderYRatio,
            width: mixerRect.width * 0.64,
            height: 6
        )
        let crossfaderKnobX = crossfaderTrack.minX + CGFloat(animationState.crossfaderPosition) * crossfaderTrack.width
        let shoulderLeft = CGPoint(x: size.width * 0.44, y: shoulderLineY)
        let shoulderRight = CGPoint(x: size.width * 0.60, y: shoulderLineY)
        let elbowLeft = CGPoint(x: size.width * 0.37, y: size.height * 0.43)
        let elbowRight = CGPoint(x: size.width * 0.67, y: size.height * 0.41)
        let recordHand = recordHandPoint(
            center: platterCenter,
            radius: platterRadius,
            animationState: animationState,
            isBabyScratch: isBabyScratch
        )
        let faderHand = faderHandPoint(
            mixerRect: mixerRect,
            crossfaderTrack: crossfaderTrack,
            crossfaderKnobX: crossfaderKnobX,
            isBabyScratch: isBabyScratch
        )

        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.illustrationFill)

            boothShadow(size: size, boothTopY: boothTopY, boothHeight: boothHeight)

            ScratchCoachBoothSurface()
                .fill(theme.detailFill)
                .frame(width: size.width * 0.88, height: boothHeight)
                .position(x: size.width * 0.5, y: boothTopY + boothHeight * 0.5)
                .overlay {
                    ScratchCoachBoothSurface()
                        .stroke(theme.primaryTextColor.opacity(0.08), lineWidth: 1)
                        .frame(width: size.width * 0.88, height: boothHeight)
                        .position(x: size.width * 0.5, y: boothTopY + boothHeight * 0.5)
                }

            platter(
                center: platterCenter,
                radius: platterRadius,
                animationState: animationState,
                isBabyScratch: isBabyScratch
            )
            mixer(rect: mixerRect, track: crossfaderTrack, knobX: crossfaderKnobX, isOpen: animationState.crossfaderOpenState)

            torso(in: size, shoulderLineY: shoulderLineY, torsoTopY: torsoTopY)

            ScratchCoachRigLimb(
                start: shoulderLeft,
                end: elbowLeft,
                color: theme.primaryTextColor.opacity(0.22),
                thickness: 10
            )
            ScratchCoachRigLimb(
                start: elbowLeft,
                end: recordHand,
                color: theme.primaryTextColor.opacity(0.24),
                thickness: 10
            )
            ScratchCoachRigLimb(
                start: shoulderRight,
                end: elbowRight,
                color: theme.primaryTextColor.opacity(0.22),
                thickness: 10
            )
            ScratchCoachRigLimb(
                start: elbowRight,
                end: faderHand,
                color: theme.primaryTextColor.opacity(0.24),
                thickness: 10
            )

            hand(at: recordHand, active: isPlaying)
            hand(at: faderHand, active: animationState.crossfaderOpenState || normalizedScratchType == "baby")

            if isPlaying {
                cueTrail(
                    from: CGPoint(
                        x: platterCenter.x + platterRadius * (Self.recordHandBasePose.x - 0.08),
                        y: platterCenter.y + platterRadius * Self.recordHandBasePose.y
                    ),
                    to: CGPoint(x: recordHand.x + 10, y: recordHand.y)
                )

                if normalizedScratchType == "chirpflare" {
                    cueTrail(
                        from: CGPoint(x: crossfaderKnobX, y: crossfaderTrack.midY - 6),
                        to: CGPoint(x: crossfaderKnobX, y: crossfaderTrack.midY - 26)
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func recordHandPoint(
        center: CGPoint,
        radius: CGFloat,
        animationState: ScratchCoachDemoAnimationState,
        isBabyScratch: Bool
    ) -> CGPoint {
        if isBabyScratch {
            return ScratchCoachRigGeometry.recordHandPoint(
                center: center,
                radius: radius,
                progress: animationState.recordPosition
            )
        }

        return CGPoint(
            x: center.x + radius * Self.recordHandBasePose.x,
            y: center.y
                + radius * Self.recordHandBasePose.y
                + CGFloat(animationState.recordPosition) * 24
        )
    }

    private func faderHandPoint(
        mixerRect: CGRect,
        crossfaderTrack: CGRect,
        crossfaderKnobX: CGFloat,
        isBabyScratch: Bool
    ) -> CGPoint {
        guard isBabyScratch else {
            return CGPoint(
                x: crossfaderKnobX,
                y: crossfaderTrack.midY - 16
            )
        }

        return CGPoint(
            x: mixerRect.minX + mixerRect.width * Self.babyScratchLeftHandPose.x,
            y: mixerRect.minY + mixerRect.height * Self.babyScratchLeftHandPose.y
        )
    }

    @ViewBuilder
    private func boothShadow(size: CGSize, boothTopY: CGFloat, boothHeight: CGFloat) -> some View {
        LinearGradient(
            colors: [theme.primaryTextColor.opacity(0.08), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: size.width * 0.88, height: boothHeight * 0.24)
        .position(x: size.width * 0.5, y: boothTopY + boothHeight * 0.10)
        .blur(radius: 6)
    }

    @ViewBuilder
    private func platter(
        center: CGPoint,
        radius: CGFloat,
        animationState: ScratchCoachDemoAnimationState,
        isBabyScratch: Bool
    ) -> some View {
        let recordMarkerOffset = recordMarkerOffset(
            radius: radius,
            animationState: animationState,
            isBabyScratch: isBabyScratch
        )

        ZStack {
            Circle()
                .fill(theme.primaryTextColor.opacity(0.06))
                .frame(width: radius * 2.3, height: radius * 2.3)

            Circle()
                .stroke(theme.primaryTextColor.opacity(0.15), lineWidth: 2)
                .frame(width: radius * 2.02, height: radius * 2.02)

            ZStack {
                Circle()
                    .stroke(theme.accentColor.opacity(0.84), lineWidth: 3)
                    .frame(width: radius * 1.68, height: radius * 1.68)

                recordStickerLineMarker(radius: radius)
                    .offset(
                        x: radius * Self.recordStickerBasePose.x,
                        y: radius * Self.recordStickerBasePose.y
                    )
            }
            .rotationEffect(.degrees(animationState.recordRotationDegrees))

            Circle()
                .fill(theme.accentColor.opacity(0.94))
                .frame(width: 10, height: 10)
                .offset(
                    x: recordMarkerOffset.x,
                    y: recordMarkerOffset.y
                )

            Capsule()
                .fill(theme.accentColor.opacity(0.82))
                .frame(width: 20, height: 8)
                .offset(
                    x: recordMarkerOffset.x,
                    y: recordMarkerOffset.y - 2
                )
        }
        .position(center)
    }

    private func recordStickerLineMarker(radius: CGFloat) -> some View {
        Capsule()
            .fill(theme.primaryTextColor.opacity(0.96))
            .frame(width: 5, height: max(14, radius * 0.46))
            .overlay {
                Capsule()
                    .stroke(theme.accentColor.opacity(0.88), lineWidth: 1.5)
            }
    }

    private func recordMarkerOffset(
        radius: CGFloat,
        animationState: ScratchCoachDemoAnimationState,
        isBabyScratch: Bool
    ) -> CGPoint {
        if isBabyScratch {
            let unitPoint = ScratchCoachRigGeometry.recordHandUnitPoint(
                progress: animationState.recordPosition
            )
            return CGPoint(
                x: radius * unitPoint.x,
                y: radius * unitPoint.y
            )
        }

        return CGPoint(
            x: radius * Self.recordHandBasePose.x,
            y: radius * Self.recordHandBasePose.y
                + CGFloat(animationState.recordPosition) * 24
        )
    }

    @ViewBuilder
    private func mixer(
        rect: CGRect,
        track: CGRect,
        knobX: CGFloat,
        isOpen: Bool
    ) -> some View {
        ZStack {
            let volumeFaderHeight = rect.height * 0.34
            let volumeFaderY = rect.height * Self.volumeFaderYRatio
            let crossfaderY = rect.height * Self.crossfaderYRatio
            let localKnobX = knobX - track.minX

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.primaryTextColor.opacity(0.06))
                .frame(width: rect.width, height: rect.height)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.primaryTextColor.opacity(0.08), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)

            HStack(spacing: 10) {
                knob
                knob
                knob
            }
            .position(x: rect.width * 0.5, y: rect.height * 0.19)

            HStack(spacing: 11) {
                channelVolumeFader(active: true, height: volumeFaderHeight)
                channelVolumeFader(active: false, height: volumeFaderHeight)
            }
            .position(x: rect.width * 0.5, y: volumeFaderY)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.controllerTrackColor)
                    .frame(width: track.width, height: 6)

                Circle()
                    .fill(isOpen ? theme.accentColor : theme.inactiveKnobColor)
                    .frame(width: 18, height: 18)
                    .shadow(color: theme.accentColor.opacity(isOpen ? 0.35 : 0), radius: 5, y: 1)
                    .offset(x: localKnobX)
            }
            .position(x: rect.width * 0.5, y: crossfaderY)
        }
        .position(x: rect.midX, y: rect.midY)
    }

    private var knob: some View {
        Circle()
            .fill(theme.primaryTextColor.opacity(0.18))
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .stroke(theme.primaryTextColor.opacity(0.06), lineWidth: 1)
            }
    }

    private func channelVolumeFader(active: Bool, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(theme.detailFill)
            .frame(width: 12, height: height)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(active ? theme.accentColor.opacity(0.86) : theme.primaryTextColor.opacity(0.18))
                    .frame(width: 8, height: active ? height * 0.50 : height * 0.28)
                    .padding(.bottom, 3)
            }
            .overlay {
                Circle()
                    .fill(theme.primaryTextColor.opacity(active ? 0.42 : 0.24))
                    .frame(width: 16, height: 16)
                    .offset(y: active ? -(height * 0.04) : height * 0.18)
            }
    }

    @ViewBuilder
    private func torso(in size: CGSize, shoulderLineY: CGFloat, torsoTopY: CGFloat) -> some View {
        let headCenter = CGPoint(x: size.width * 0.52, y: size.height * 0.14)

        ZStack {
            Circle()
                .fill(theme.primaryTextColor.opacity(0.18))
                .frame(width: 42, height: 42)
                .position(headCenter)

            Capsule()
                .fill(theme.primaryTextColor.opacity(0.10))
                .frame(width: 52, height: 10)
                .position(x: headCenter.x, y: headCenter.y - 20)

            HStack(spacing: 30) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.primaryTextColor.opacity(0.18))
                    .frame(width: 8, height: 16)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.primaryTextColor.opacity(0.18))
                    .frame(width: 8, height: 16)
            }
            .position(x: headCenter.x, y: headCenter.y + 2)

            Path { path in
                path.move(to: CGPoint(x: size.width * 0.41, y: shoulderLineY))
                path.addLine(to: CGPoint(x: size.width * 0.63, y: shoulderLineY))
                path.addLine(to: CGPoint(x: size.width * 0.57, y: size.height * 0.50))
                path.addLine(to: CGPoint(x: size.width * 0.46, y: size.height * 0.50))
                path.closeSubpath()
            }
            .fill(theme.primaryTextColor.opacity(0.12))

            Path { path in
                path.move(to: CGPoint(x: size.width * 0.41, y: shoulderLineY))
                path.addLine(to: CGPoint(x: size.width * 0.63, y: shoulderLineY))
                path.addLine(to: CGPoint(x: size.width * 0.57, y: size.height * 0.50))
                path.addLine(to: CGPoint(x: size.width * 0.46, y: size.height * 0.50))
                path.closeSubpath()
            }
            .stroke(theme.primaryTextColor.opacity(0.08), lineWidth: 1)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentColor.opacity(0.18))
                .frame(width: 44, height: 18)
                .position(x: size.width * 0.52, y: torsoTopY + size.height * 0.10)

            HStack(spacing: 18) {
                Circle()
                    .fill(theme.primaryTextColor.opacity(0.24))
                    .frame(width: 12, height: 12)

                Circle()
                    .fill(theme.primaryTextColor.opacity(0.24))
                    .frame(width: 12, height: 12)
            }
            .position(x: size.width * 0.52, y: shoulderLineY)
        }
    }

    private func hand(at point: CGPoint, active: Bool) -> some View {
        Circle()
            .fill(active ? theme.accentColor.opacity(0.92) : theme.primaryTextColor.opacity(0.26))
            .frame(width: 14, height: 14)
            .overlay {
                Circle()
                    .stroke(theme.primaryTextColor.opacity(0.08), lineWidth: 1)
            }
            .position(point)
    }

    private func cueTrail(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(
            theme.accentColor.opacity(0.46),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5])
        )
    }

    private func faderStateLabel(for animationState: ScratchCoachDemoAnimationState) -> String {
        animationState.crossfaderOpenState ? "Fader open" : "Fader cut"
    }

    private var faderCueText: String {
        switch normalizeScratchType(input: instruction.scratchType) {
        case "baby":
            return "Fader stays open."
        case "chirpflare":
            return "Quick fader click."
        default:
            return "Match the record and fader movement."
        }
    }
}

struct ScratchCoachCardContent<Controls: View>: View {
    let instruction: ScratchCoachInstruction
    let demoStatusMessage: String
    let playbackTimeProvider: () -> TimeInterval
    let isPlayingProvider: () -> Bool
    let animationStateProvider: ((TimeInterval, Bool) -> ScratchCoachDemoAnimationState?)?
    let theme: ScratchCoachCardTheme

    private let controls: Controls
    @State private var showsDetails = false

    init(
        instruction: ScratchCoachInstruction,
        demoStatusMessage: String,
        playbackTimeProvider: @escaping () -> TimeInterval,
        isPlayingProvider: @escaping () -> Bool,
        animationStateProvider: ((TimeInterval, Bool) -> ScratchCoachDemoAnimationState?)? = nil,
        theme: ScratchCoachCardTheme,
        @ViewBuilder controls: () -> Controls
    ) {
        self.instruction = instruction
        self.demoStatusMessage = demoStatusMessage
        self.playbackTimeProvider = playbackTimeProvider
        self.isPlayingProvider = isPlayingProvider
        self.animationStateProvider = animationStateProvider
        self.theme = theme
        self.controls = controls()
    }

    private var difficultyLabel: String? {
        let trimmedDifficulty = instruction.difficulty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDifficulty.isEmpty, trimmedDifficulty.lowercased() != "coach" else { return nil }
        return trimmedDifficulty.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("ScratchLab Coach")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(theme.primaryTextColor)

                Spacer()

                if let difficultyLabel {
                    Text(difficultyLabel)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(theme.primaryTextColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.detailFill, in: Capsule())
                }
            }

            ScratchCoachSpeechBubbleView(
                instruction: instruction,
                theme: theme
            )

            ScratchCoachRigView(
                instruction: instruction,
                playbackTimeProvider: playbackTimeProvider,
                isPlayingProvider: isPlayingProvider,
                animationStateProvider: animationStateProvider,
                theme: theme
            )

            controls

            Text(demoStatusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)

            if instruction.showsStructuredCoaching {
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !instruction.steps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(instruction.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1).")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.primaryTextColor)

                                        Text(step)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(theme.secondaryTextColor)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        if !instruction.commonMistake.isEmpty {
                            detailBlock(
                                title: "Common Mistake",
                                detail: instruction.commonMistake
                            )
                        }

                        if !instruction.practiceChallenge.isEmpty {
                            detailBlock(
                                title: "Practice Challenge",
                                detail: instruction.practiceChallenge
                            )
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showsDetails ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                            .foregroundStyle(theme.accentColor)

                        Text("Steps & Tips")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.primaryTextColor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailBlock(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.primaryTextColor)

            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(theme.detailFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
