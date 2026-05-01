import SwiftUI

#if os(iOS) && canImport(RealityKit)
import RealityKit

private enum CoachPreviewConstants {
    static let entityName = "Coach"
    static let resourceName = "Coach"
    static let resourceExtension = "usdz"
    static let normalizedHeightRange: ClosedRange<Float> = 0.9 ... 2.6
    static let targetNormalizedHeight: Float = 1.7
    static let minimumScaleFactor: Float = 0.65
    static let maximumScaleFactor: Float = 2.5
    static let cameraFieldOfViewDegrees: Float = 60
    static let verticalPaddingMultiplier: Float = 1.05
    static let horizontalPaddingMultiplier: Float = 1.1
    static let fallbackCameraDistance: Float = 1.35
    static let platterRadius: Float = 0.28
    static let platterHeight: Float = 0.04
    static let platterSurfaceHeight: Float = 0.006
    static let platterAccentHeight: Float = 0.003
    static let platterMarkerLength: Float = 0.22
    static let platterMarkerWidth: Float = 0.028
    static let platterWaistHeightRatio: Float = 0.57
    static let platterForwardGap: Float = 0.18
    static let platterTargetScreenWidthRatio: Float = 0.35
    static let minimumPlatterDistanceFromCamera: Float = 1.02
    static let maximumPlatterDistanceFromCamera: Float = 1.48
    static let platterRotationLimitDegrees: Float = 180
    static let scratchVelocityClamp: Double = 6.5
    static let scratchPhysicsStepNanoseconds: UInt64 = 16_000_000
    static let releaseInertiaDuration: Double = 0.18
    static let releaseDecelerationPerSecond: Double = 8.5
    static let releaseSpringStiffness: Double = 28
    static let releaseSpringDamping: Double = 12
    static let releaseEdgeVelocityDamping: Double = 0.32
    static let scratchSettlePositionThreshold: Double = 0.006
    static let scratchSettleVelocityThreshold: Double = 0.04
    static let motionPulseTravelMilliseconds: UInt64 = 220
    static let motionPulseHoldMilliseconds: UInt64 = 90
    static let motionDemoForwardMilliseconds: UInt64 = 520
    static let motionDemoBackMilliseconds: UInt64 = 520
    static let motionDemoReturnMilliseconds: UInt64 = 440
    static let motionDemoCenterPauseMilliseconds: UInt64 = 120
    static let fallbackBounds = BoundingBox(
        min: SIMD3<Float>(-0.35, -0.8, -0.2),
        max: SIMD3<Float>(0.35, 0.8, 0.2)
    )
}

private enum CoachPreviewError: LocalizedError {
    case missingBundleURL
    case missingBundleFile(URL)

    var errorDescription: String? {
        switch self {
        case .missingBundleURL:
            return "Coach preview is unavailable right now."
        case .missingBundleFile:
            return "Coach preview could not be loaded."
        }
    }
}

private struct CoachPreviewState: Equatable {
    enum Phase: String {
        case waiting = "Waiting"
        case loading = "Loading"
        case loaded = "Loaded"
        case failed = "Failed"
    }

    let phase: Phase
    let message: String
    let animationCount: Int?
    let scale: Float?
    let modelHeight: Float?

    static let idle = CoachPreviewState(
        phase: .waiting,
        message: "Waiting to load coach preview.",
        animationCount: nil,
        scale: nil,
        modelHeight: nil
    )

    var summaryLine: String {
        var parts = [phase.rawValue]

        if let animationCount {
            parts.append("\(animationCount) anim")
        }

        if let scale {
            parts.append("\(CoachPreviewLoader.formatDecimal(scale))x scale")
        }

        if let modelHeight {
            parts.append("~\(CoachPreviewLoader.formatDecimal(modelHeight)) high")
        }

        return parts.joined(separator: " | ")
    }
}

private struct LoadedCoachEntity {
    let entity: Entity
    let resolvedEntityName: String
    let animationCount: Int
    let startedAnimation: Bool
    let animationController: AnimationPlaybackController?
    let averageScale: Float
    let modelHeight: Float?
    let visualBounds: BoundingBox
}

private enum CoachMotionMode: String, CaseIterable, Identifiable {
    case idleLoop = "Idle Loop"
    case forwardScratch = "Forward Scratch"
    case backScratch = "Back Scratch"
    case babyScratchDemo = "Baby Scratch Demo"

    var id: String { rawValue }

    var idleAnimationSpeed: Float {
        switch self {
        case .idleLoop:
            return 1
        case .forwardScratch, .backScratch:
            return 0.45
        case .babyScratchDemo:
            return 0.6
        }
    }
}

private enum CoachScratchDirection: String {
    case backward = "back"
    case neutral = "center"
    case forward = "forward"

    var label: String {
        switch self {
        case .backward:
            return "Back"
        case .neutral:
            return "Center"
        case .forward:
            return "Forward"
        }
    }
}

private enum CoachPreviewAnimationMode: Equatable {
    case pausedForScratch
    case looping(speed: Float)
}

private struct CoachScratchSample {
    let timestamp: TimeInterval
    let value: Double
}

private struct CoachTrainerLogSnapshot: Equatable {
    let scratchBucket: Int
    let velocityBucket: Int
    let direction: CoachScratchDirection
}

private struct CoachTrainer3DLogSnapshot: Equatable {
    let scratchBucket: Int
    let rotationBucket: Int
}

private enum CoachPreviewLoader {
    @MainActor
    static func loadCoachEntity(viewportSize: CGSize) async throws -> LoadedCoachEntity {
        guard let bundleURL = Bundle.main.url(
            forResource: CoachPreviewConstants.resourceName,
            withExtension: CoachPreviewConstants.resourceExtension
        ) else {
            print("[CoachPreview] bundleURL=nil")
            throw CoachPreviewError.missingBundleURL
        }

        let fileExists = FileManager.default.fileExists(atPath: bundleURL.path)
        print("[CoachPreview] bundleURL=\(bundleURL.absoluteString)")
        print("[CoachPreview] fileExists=\(fileExists)")

        guard fileExists else {
            throw CoachPreviewError.missingBundleFile(bundleURL)
        }

        let rootEntity = try await Entity(
            contentsOf: bundleURL,
            withName: CoachPreviewConstants.resourceName
        )
        let rootName = displayName(for: rootEntity, fallback: "\(CoachPreviewConstants.resourceName).usdz root")
        let rootChildNames = flattenedChildNames(from: rootEntity)

        print("[CoachPreview] rootEntity.name=\(rootName)")
        print("[CoachPreview] rootEntity.childNames=\(rootChildNames.joined(separator: ", "))")

        do {
            let namedEntity = try await Entity(named: CoachPreviewConstants.entityName, in: Bundle.main)
            let namedEntityName = displayName(for: namedEntity, fallback: "<unnamed named entity>")
            print("[CoachPreview] namedEntity.loadSucceeded=true")
            print("[CoachPreview] namedEntity.name=\(namedEntityName)")
            print("[CoachPreview] namedEntity.childNames=\(flattenedChildNames(from: namedEntity).joined(separator: ", "))")
        } catch {
            print("[CoachPreview] namedEntity.loadSucceeded=false error=\(String(reflecting: error))")
            print("[CoachPreview] namedEntity.fallback=rootEntity")
        }

        var coachEntity = rootEntity
        let initialBounds = coachEntity.visualBounds(relativeTo: nil)
        logBounds(label: "initialBounds", bounds: initialBounds)

        let initialHeight = initialBounds.isEmpty ? nil : initialBounds.extents.y
        let scaleFactor = normalizedScaleFactor(for: initialHeight)
        let initialScale = coachEntity.scale
        coachEntity.scale = SIMD3<Float>(
            initialScale.x * scaleFactor,
            initialScale.y * scaleFactor,
            initialScale.z * scaleFactor
        )

        let scaledBounds = coachEntity.visualBounds(relativeTo: nil)
        logBounds(label: "scaledBounds", bounds: scaledBounds)

        let effectiveBounds = scaledBounds.isEmpty ? CoachPreviewConstants.fallbackBounds : scaledBounds
        let framedBounds = applyPreviewFraming(
            to: &coachEntity,
            bounds: effectiveBounds,
            viewportSize: viewportSize
        )
        logBounds(label: "finalBounds", bounds: framedBounds)

        let animationCount = coachEntity.availableAnimations.count
        print("[CoachPreview] loadSucceeded=true")
        print("[CoachPreview] resolvedEntityName=\(rootName)")
        print("[CoachPreview] availableAnimations.count=\(animationCount)")

        var startedAnimation = false
        var animationController: AnimationPlaybackController?
        if let firstAnimation = coachEntity.availableAnimations.first {
            animationController = coachEntity.playAnimation(
                firstAnimation.repeat(),
                transitionDuration: 0.2,
                startsPaused: false
            )
            startedAnimation = true
            print("[CoachPreview] animationRepeatStarted=true")
        } else {
            print("[CoachPreview] animationRepeatStarted=false")
        }

        let finalTransform = coachEntity.transform
        print("[CoachPreview] finalScale=\(formatVector(finalTransform.scale))")
        print("[CoachPreview] finalTranslation=\(formatVector(finalTransform.translation))")
        print("[CoachPreview] finalRotation=\(formatQuaternion(finalTransform.rotation))")

        return LoadedCoachEntity(
            entity: coachEntity,
            resolvedEntityName: rootName,
            animationCount: animationCount,
            startedAnimation: startedAnimation,
            animationController: animationController,
            averageScale: averageScale(of: finalTransform.scale),
            modelHeight: framedBounds.isEmpty ? nil : framedBounds.extents.y,
            visualBounds: framedBounds
        )
    }

    @MainActor
    private static func applyPreviewFraming(
        to entity: inout Entity,
        bounds: BoundingBox,
        viewportSize: CGSize
    ) -> BoundingBox {
        let aspectRatio = max(Float(viewportSize.width / max(viewportSize.height, 1)), 0.75)
        let verticalFieldOfView = CoachPreviewConstants.cameraFieldOfViewDegrees * .pi / 180
        let horizontalFieldOfView = 2 * atan(tan(verticalFieldOfView / 2) * aspectRatio)

        let halfHeight = max(bounds.extents.y / 2, 0.01)
        let halfWidth = max(bounds.extents.x / 2, 0.01)
        let halfDepth = max(bounds.extents.z / 2, 0.01)

        let distanceForHeight = (halfHeight * CoachPreviewConstants.verticalPaddingMultiplier) / tan(verticalFieldOfView / 2)
        let distanceForWidth = (halfWidth * CoachPreviewConstants.horizontalPaddingMultiplier) / tan(horizontalFieldOfView / 2)
        let distance = max(distanceForHeight, distanceForWidth) + halfDepth

        entity.position = SIMD3<Float>(
            -bounds.center.x,
            -bounds.center.y,
            -bounds.center.z - max(distance, CoachPreviewConstants.fallbackCameraDistance)
        )

        return entity.visualBounds(relativeTo: nil)
    }

    static func failureStatus(for error: Error) -> CoachPreviewState {
        return CoachPreviewState(
            phase: .failed,
            message: error.localizedDescription,
            animationCount: nil,
            scale: nil,
            modelHeight: nil
        )
    }

    static func loadingStatus() -> CoachPreviewState {
        CoachPreviewState(
            phase: .loading,
            message: "Loading coach preview.",
            animationCount: nil,
            scale: nil,
            modelHeight: nil
        )
    }

    static func loadedStatus(for loadedCoach: LoadedCoachEntity) -> CoachPreviewState {
        return CoachPreviewState(
            phase: .loaded,
            message: loadedCoach.startedAnimation
                ? "Coach animation is ready."
                : "Coach preview is ready.",
            animationCount: loadedCoach.animationCount,
            scale: loadedCoach.averageScale,
            modelHeight: loadedCoach.modelHeight
        )
    }

    static func formatDecimal(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private static func normalizedScaleFactor(for height: Float?) -> Float {
        guard let height, height > 0 else { return 1 }
        guard !CoachPreviewConstants.normalizedHeightRange.contains(height) else { return 1 }

        let rawScale = CoachPreviewConstants.targetNormalizedHeight / height
        return min(max(rawScale, CoachPreviewConstants.minimumScaleFactor), CoachPreviewConstants.maximumScaleFactor)
    }

    private static func displayName(for entity: Entity, fallback: String) -> String {
        let trimmedName = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? fallback : trimmedName
    }

    private static func flattenedChildNames(from entity: Entity, limit: Int = 16) -> [String] {
        var names: [String] = []

        func visit(_ currentEntity: Entity) {
            guard names.count < limit else { return }

            for child in currentEntity.children {
                guard names.count < limit else { break }
                names.append(displayName(for: child, fallback: "<unnamed child>"))
                visit(child)
            }
        }

        visit(entity)
        return names
    }

    private static func averageScale(of scale: SIMD3<Float>) -> Float {
        (scale.x + scale.y + scale.z) / 3
    }

    private static func logBounds(label: String, bounds: BoundingBox) {
        print("[CoachPreview] \(label).min=\(formatVector(bounds.min))")
        print("[CoachPreview] \(label).max=\(formatVector(bounds.max))")
        print("[CoachPreview] \(label).center=\(formatVector(bounds.center))")
        print("[CoachPreview] \(label).extents=\(formatVector(bounds.extents))")
    }

    static func formatVector(_ vector: SIMD3<Float>) -> String {
        "(\(formatDecimal(vector.x)), \(formatDecimal(vector.y)), \(formatDecimal(vector.z)))"
    }

    private static func formatQuaternion(_ quaternion: simd_quatf) -> String {
        let vector = quaternion.vector
        return "(\(formatDecimal(vector.x)), \(formatDecimal(vector.y)), \(formatDecimal(vector.z)), \(formatDecimal(vector.w)))"
    }
}

struct CoachPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioEngine: AudioEngine
    @State private var status = CoachPreviewState.idle
    @State private var motionMode: CoachMotionMode = .idleLoop
    @State private var motionDemoTask: Task<Void, Never>?
    @State private var motionDemoToken = 0
    @State private var scratchValue = 0.0
    @State private var scratchVelocityApprox = 0.0
    @State private var scratchDirection: CoachScratchDirection = .neutral
    @State private var platterRotationDegrees = 0.0
    @State private var isScratchPadActive = false
    @State private var scratchReleaseTask: Task<Void, Never>?
    @State private var scratchReleaseToken = 0
    @State private var lastScratchSample: CoachScratchSample?
    @State private var lastLoggedScratchSnapshot: CoachTrainerLogSnapshot?
    @State private var startedAudioEngineForPreview = false
    @State private var inputSourceBeforePreview: AudioInputSource?

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    previewSurface
                    trainerCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("3D Coach Demo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prepareAudioMonitoringIfNeeded()
        }
        .onDisappear {
            cancelActiveMotionDemo()
            cancelScratchReleaseMotion()
            teardownAudioMonitoringIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var animationMode: CoachPreviewAnimationMode {
        if isScratchPadActive {
            return .pausedForScratch
        }

        return .looping(speed: motionMode.idleAnimationSpeed)
    }

    private var previewSurface: some View {
        GeometryReader { geometry in
            CoachPreviewARViewContainer(
                viewportSize: geometry.size,
                animationMode: animationMode,
                scratchValue: scratchValue,
                scratchVelocityApprox: scratchVelocityApprox
            ) { status = $0 }
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    previewBadge
                }
        }
        .frame(height: 400)
    }

    private var trainerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Motion")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "FBBF24"))

                Spacer(minLength: 12)

                Text(motionMode.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CoachMotionMode.allCases) { mode in
                    Button {
                        applyMotionMode(mode)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(mode == .idleLoop ? "Loop" : "Motion")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(mode == motionMode ? 0.82 : 0.6))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(mode == motionMode ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(mode == motionMode ? summaryColor(for: status.phase).opacity(0.9) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            platterFeedback
            audioMotionCard
            scratchPadSection
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var platterFeedback: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.04))

                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 8)
                    .padding(10)

                Capsule()
                    .fill(summaryColor(for: status.phase))
                    .frame(width: 7, height: 32)
                    .offset(y: -16)
                    .rotationEffect(.degrees(platterRotationDegrees))

                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
            }
            .frame(width: 94, height: 94)

            VStack(alignment: .leading, spacing: 7) {
                Text(formattedScratchValue(scratchValue))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    trainerBadge(title: "Direction", value: scratchDirection.label)
                    trainerBadge(title: "Velocity", value: "\(formattedSignedMeasurement(scratchVelocityApprox))/s")
                }
            }
        }
    }

    private var audioMotionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Audio Motion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                Text(audioMotionBalanceText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(audioMotionColor, in: Capsule())
            }

            HStack(spacing: 10) {
                ForEach(previewInputSources, id: \.self) { source in
                    Button {
                        audioEngine.selectInputSource(source)
                    } label: {
                        Text(source.practiceLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(audioEngine.currentInputSource == source ? .black : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(
                                audioEngine.currentInputSource == source
                                    ? Color(hex: "FFD700")
                                    : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                trainerBadge(title: "Route", value: audioEngine.activeInputName)
                trainerBadge(title: "Direction", value: audioEngine.scratchMotionDirection.label)
                trainerBadge(title: "Envelope", value: audioEnvelopeDisplayText)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                trainerBadge(title: "Forward", value: audioForwardDurationText)
                trainerBadge(title: "Back", value: audioBackwardDurationText)
                trainerBadge(title: "Timing Error", value: audioTimingErrorText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))

                    Capsule()
                        .fill(audioMotionColor.opacity(0.95))
                        .frame(width: geometry.size.width * audioEnvelopeFillRatio)
                }
            }
            .frame(height: 8)
        }
    }

    private var scratchPadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scratch Pad")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                Text("Direction \(scratchDirection.label)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(summaryColor(for: status.phase))
                    .monospacedDigit()
            }

            scratchPadSurface

            HStack {
                Text("-1.00")
                Spacer()
                Text("0.00")
                Spacer()
                Text("+1.00")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.48))
            .monospacedDigit()
        }
    }

    private var scratchPadSurface: some View {
        GeometryReader { geometry in
            let maxOffset = max((geometry.size.width - 44) / 2, 1)
            let handleOffset = CGFloat(scratchValue) * maxOffset

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)

                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 10)
                    .padding(.horizontal, 18)

                if abs(handleOffset) > 0.5 {
                    Capsule()
                        .fill(summaryColor(for: status.phase).opacity(0.38))
                        .frame(width: abs(handleOffset), height: 10)
                        .offset(x: handleOffset / 2)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: 44)

                Circle()
                    .fill(Color.white)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
                    .offset(x: handleOffset)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        handleScratchPadDrag(gesture, availableWidth: geometry.size.width)
                    }
                    .onEnded { _ in
                        endScratchPadDrag()
                    }
            )
        }
        .frame(height: 92)
    }

    private var previewBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.summaryLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(summaryColor(for: status.phase))

            if status.phase == .failed {
                Text(status.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(14)
    }

    private func summaryColor(for phase: CoachPreviewState.Phase) -> Color {
        switch phase {
        case .waiting:
            return .white.opacity(0.68)
        case .loading:
            return Color(hex: "7DD3FC")
        case .loaded:
            return Color(hex: "34D399")
        case .failed:
            return Color(hex: "FCA5A5")
        }
    }

    private var previewInputSources: [AudioInputSource] {
        var sources: [AudioInputSource] = [.microphone]
        if audioEngine.hasExternalPracticeInput {
            sources.append(.lineIn)
        }
        return sources
    }

    private var audioMotionBalanceText: String {
        audioEngine.scratchMotionFeedback?.balance.rawValue ?? ScratchMotionBalance.listening.rawValue
    }

    private var audioMotionColor: Color {
        switch audioEngine.scratchMotionFeedback?.balance ?? .listening {
        case .listening:
            return Color(hex: "38BDF8")
        case .balanced:
            return Color(hex: "22C55E")
        case .unbalanced:
            return Color(hex: "EF4444")
        }
    }

    private var audioForwardDurationText: String {
        formattedDuration(audioEngine.scratchMotionFeedback?.forwardDuration)
    }

    private var audioBackwardDurationText: String {
        formattedDuration(audioEngine.scratchMotionFeedback?.backwardDuration)
    }

    private var audioTimingErrorText: String {
        guard let timingErrorMilliseconds = audioEngine.scratchMotionFeedback?.timingErrorMilliseconds else {
            return "—"
        }
        return "\(timingErrorMilliseconds) ms"
    }

    private var audioEnvelopeFillRatio: CGFloat {
        CGFloat(min(max(Double(audioEngine.inputLevel) * 60, 0), 1).squareRoot())
    }

    private var audioEnvelopeDisplayText: String {
        "\(Int((audioEnvelopeFillRatio * 100).rounded()))%"
    }

    private func trainerBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.5))

            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func handleScratchPadDrag(_ gesture: DragGesture.Value, availableWidth: CGFloat) {
        if motionDemoTask != nil {
            cancelActiveMotionDemo()
        }
        if scratchReleaseTask != nil {
            cancelScratchReleaseMotion()
        }
        let maxOffset = max((availableWidth - 32) / 2, 1)
        let centeredX = max(min(gesture.location.x - (availableWidth / 2), maxOffset), -maxOffset)
        let normalizedValue = Double(centeredX / maxOffset)
        let timestamp = Date().timeIntervalSinceReferenceDate

        let velocityApprox: Double
        if let lastScratchSample {
            let deltaTime = max(timestamp - lastScratchSample.timestamp, 0.0001)
            velocityApprox = (normalizedValue - lastScratchSample.value) / deltaTime
        } else {
            velocityApprox = 0
        }

        lastScratchSample = CoachScratchSample(timestamp: timestamp, value: normalizedValue)
        updateScratchTrainer(value: normalizedValue, velocityApprox: velocityApprox, isActive: true)
    }

    private func endScratchPadDrag() {
        lastScratchSample = nil
        isScratchPadActive = false
        let releaseVelocity = clamp(
            scratchVelocityApprox,
            minimum: -CoachPreviewConstants.scratchVelocityClamp,
            maximum: CoachPreviewConstants.scratchVelocityClamp
        )
        let releaseValue = scratchValue

        guard abs(releaseValue) > CoachPreviewConstants.scratchSettlePositionThreshold
            || abs(releaseVelocity) > CoachPreviewConstants.scratchSettleVelocityThreshold
        else {
            resetTrainerToNeutral()
            return
        }

        let releaseToken = beginScratchRelease()
        scratchReleaseTask = Task { @MainActor in
            await runScratchRelease(
                initialValue: releaseValue,
                initialVelocity: releaseVelocity,
                releaseToken: releaseToken
            )
        }
    }

    private func applyMotionMode(_ mode: CoachMotionMode) {
        cancelScratchReleaseMotion()
        cancelActiveMotionDemo()
        motionMode = mode
        lastScratchSample = nil
        resetTrainerToNeutral(animated: false)

        switch mode {
        case .idleLoop:
            resetTrainerToNeutral()
        case .forwardScratch:
            print("[CoachTrainerMode] Forward Scratch")
            let demoToken = beginMotionDemo()
            motionDemoTask = Task { @MainActor in
                await runScratchPulse(
                    targetValue: 1,
                    demoToken: demoToken
                )
            }
        case .backScratch:
            print("[CoachTrainerMode] Back Scratch")
            let demoToken = beginMotionDemo()
            motionDemoTask = Task { @MainActor in
                await runScratchPulse(
                    targetValue: -1,
                    demoToken: demoToken
                )
            }
        case .babyScratchDemo:
            print("[CoachTrainerMode] Baby Scratch Demo started")
            let demoToken = beginMotionDemo()
            motionDemoTask = Task { @MainActor in
                await runBabyScratchDemo(demoToken: demoToken)
            }
        }
    }

    private func cancelActiveMotionDemo() {
        motionDemoTask?.cancel()
        motionDemoTask = nil
        motionDemoToken += 1
        lastScratchSample = nil
    }

    private func cancelScratchReleaseMotion() {
        scratchReleaseTask?.cancel()
        scratchReleaseTask = nil
        scratchReleaseToken += 1
    }

    private func beginMotionDemo() -> Int {
        motionDemoToken += 1
        return motionDemoToken
    }

    private func beginScratchRelease() -> Int {
        scratchReleaseToken += 1
        return scratchReleaseToken
    }

    @MainActor
    private func runScratchPulse(
        targetValue: Double,
        demoToken: Int
    ) async {
        guard isCurrentMotionDemo(demoToken) else { return }

        guard await animateScratchValue(
            to: targetValue,
            durationMilliseconds: CoachPreviewConstants.motionPulseTravelMilliseconds,
            isActive: false,
            shouldContinue: { isCurrentMotionDemo(demoToken) }
        ) else {
            finishMotionDemoIfCurrent(demoToken)
            return
        }

        guard await waitForMotionDemoStep(
            milliseconds: CoachPreviewConstants.motionPulseHoldMilliseconds,
            demoToken: demoToken
        ) else {
            finishMotionDemoIfCurrent(demoToken)
            return
        }

        guard await settleScratchToNeutral(
            initialValue: scratchValue,
            initialVelocity: 0,
            includeInertia: false,
            shouldContinue: { isCurrentMotionDemo(demoToken) }
        ) else {
            finishMotionDemoIfCurrent(demoToken)
            return
        }

        finishMotionDemoIfCurrent(demoToken)
    }

    @MainActor
    private func runBabyScratchDemo(demoToken: Int) async {
        let forwardStrokeMilliseconds: UInt64 = CoachPreviewConstants.motionDemoForwardMilliseconds
        let backStrokeMilliseconds: UInt64 = CoachPreviewConstants.motionDemoBackMilliseconds
        let returnStrokeMilliseconds: UInt64 = CoachPreviewConstants.motionDemoReturnMilliseconds
        let centerPauseMilliseconds: UInt64 = CoachPreviewConstants.motionDemoCenterPauseMilliseconds

        for _ in 0..<2 {
            guard await waitForMotionDemoStep(
                milliseconds: centerPauseMilliseconds,
                demoToken: demoToken
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }

            guard await animateScratchValue(
                to: 1,
                durationMilliseconds: forwardStrokeMilliseconds,
                isActive: false,
                shouldContinue: { isCurrentMotionDemo(demoToken) }
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }

            guard await animateScratchValue(
                to: 0,
                durationMilliseconds: returnStrokeMilliseconds,
                isActive: false,
                shouldContinue: { isCurrentMotionDemo(demoToken) }
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }

            guard await waitForMotionDemoStep(
                milliseconds: centerPauseMilliseconds,
                demoToken: demoToken
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }

            guard await animateScratchValue(
                to: -1,
                durationMilliseconds: backStrokeMilliseconds,
                isActive: false,
                shouldContinue: { isCurrentMotionDemo(demoToken) }
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }

            guard await animateScratchValue(
                to: 0,
                durationMilliseconds: returnStrokeMilliseconds,
                isActive: false,
                shouldContinue: { isCurrentMotionDemo(demoToken) }
            ) else {
                finishMotionDemoIfCurrent(demoToken)
                return
            }
        }

        print("[CoachTrainerMode] Baby Scratch Demo completed")
        finishMotionDemoIfCurrent(demoToken)
    }

    @MainActor
    private func resetTrainerToNeutral(animated: Bool = true) {
        updateScratchTrainerState(
            value: 0,
            velocityApprox: 0,
            isActive: false,
            animated: animated
        )
    }

    @MainActor
    private func updateScratchTrainerState(
        value: Double,
        velocityApprox: Double,
        isActive: Bool,
        animated: Bool = true
    ) {
        lastLoggedScratchSnapshot = nil

        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                updateScratchTrainer(value: value, velocityApprox: velocityApprox, isActive: isActive)
            }
        } else {
            updateScratchTrainer(value: value, velocityApprox: velocityApprox, isActive: isActive)
        }
    }

    @MainActor
    private func finishMotionDemoIfCurrent(_ demoToken: Int) {
        guard motionDemoToken == demoToken else { return }
        motionDemoTask = nil
    }

    @MainActor
    private func finishScratchReleaseIfCurrent(_ releaseToken: Int) {
        guard scratchReleaseToken == releaseToken else { return }
        scratchReleaseTask = nil
    }

    private func isCurrentMotionDemo(_ demoToken: Int) -> Bool {
        motionDemoToken == demoToken && !Task.isCancelled
    }

    private func isCurrentScratchRelease(_ releaseToken: Int) -> Bool {
        scratchReleaseToken == releaseToken && !Task.isCancelled
    }

    private func waitForMotionDemoStep(milliseconds: UInt64, demoToken: Int) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        } catch {
            return false
        }

        return isCurrentMotionDemo(demoToken)
    }

    private func waitForScratchPhysicsFrame() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: CoachPreviewConstants.scratchPhysicsStepNanoseconds)
        } catch {
            return false
        }

        return !Task.isCancelled
    }

    @MainActor
    private func runScratchRelease(
        initialValue: Double,
        initialVelocity: Double,
        releaseToken: Int
    ) async {
        guard isCurrentScratchRelease(releaseToken) else { return }

        let didSettle = await settleScratchToNeutral(
            initialValue: initialValue,
            initialVelocity: initialVelocity,
            includeInertia: true,
            shouldContinue: { isCurrentScratchRelease(releaseToken) }
        )

        guard didSettle else {
            finishScratchReleaseIfCurrent(releaseToken)
            return
        }

        finishScratchReleaseIfCurrent(releaseToken)
    }

    @MainActor
    private func animateScratchValue(
        to targetValue: Double,
        durationMilliseconds: UInt64,
        isActive: Bool,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard shouldContinue() else { return false }

        let timeStep = Double(CoachPreviewConstants.scratchPhysicsStepNanoseconds) / 1_000_000_000
        let durationSeconds = max(Double(durationMilliseconds) / 1_000, timeStep)
        let frameCount = max(Int((durationSeconds / timeStep).rounded(.up)), 1)
        let startValue = scratchValue
        var previousValue = startValue

        for frame in 1...frameCount {
            guard shouldContinue() else { return false }

            let progress = Double(frame) / Double(frameCount)
            let easedProgress = easeInOutCubic(progress)
            let currentValue = startValue + ((targetValue - startValue) * easedProgress)
            let currentVelocity = clamp(
                (currentValue - previousValue) / timeStep,
                minimum: -CoachPreviewConstants.scratchVelocityClamp,
                maximum: CoachPreviewConstants.scratchVelocityClamp
            )

            updateScratchTrainer(
                value: currentValue,
                velocityApprox: currentVelocity,
                isActive: isActive
            )
            previousValue = currentValue

            if frame < frameCount {
                guard await waitForScratchPhysicsFrame(), shouldContinue() else { return false }
            }
        }

        updateScratchTrainer(value: targetValue, velocityApprox: 0, isActive: isActive)
        return shouldContinue()
    }

    @MainActor
    private func settleScratchToNeutral(
        initialValue: Double,
        initialVelocity: Double,
        includeInertia: Bool,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard shouldContinue() else { return false }

        let timeStep = Double(CoachPreviewConstants.scratchPhysicsStepNanoseconds) / 1_000_000_000
        var position = clamp(initialValue, minimum: -1, maximum: 1)
        var velocity = clamp(
            initialVelocity,
            minimum: -CoachPreviewConstants.scratchVelocityClamp,
            maximum: CoachPreviewConstants.scratchVelocityClamp
        )
        var inertiaElapsed = 0.0

        while shouldContinue() {
            if includeInertia && inertiaElapsed < CoachPreviewConstants.releaseInertiaDuration {
                position += velocity * timeStep
                velocity *= exp(-CoachPreviewConstants.releaseDecelerationPerSecond * timeStep)
                inertiaElapsed += timeStep
            } else {
                let acceleration = (-CoachPreviewConstants.releaseSpringStiffness * position)
                    - (CoachPreviewConstants.releaseSpringDamping * velocity)
                velocity += acceleration * timeStep
                position += velocity * timeStep
            }

            if position >= 1 {
                position = 1
                velocity = min(velocity, 0) * CoachPreviewConstants.releaseEdgeVelocityDamping
            } else if position <= -1 {
                position = -1
                velocity = max(velocity, 0) * CoachPreviewConstants.releaseEdgeVelocityDamping
            }

            updateScratchTrainer(value: position, velocityApprox: velocity, isActive: false)

            if inertiaElapsed >= CoachPreviewConstants.releaseInertiaDuration
                && abs(position) < CoachPreviewConstants.scratchSettlePositionThreshold
                && abs(velocity) < CoachPreviewConstants.scratchSettleVelocityThreshold {
                break
            }

            guard await waitForScratchPhysicsFrame(), shouldContinue() else { return false }
        }

        guard shouldContinue() else { return false }
        updateScratchTrainer(value: 0, velocityApprox: 0, isActive: false)
        return true
    }

    private func easeInOutCubic(_ progress: Double) -> Double {
        if progress < 0.5 {
            return 4 * progress * progress * progress
        }

        let inverse = (-2 * progress) + 2
        return 1 - ((inverse * inverse * inverse) / 2)
    }

    private func updateScratchTrainer(value: Double, velocityApprox: Double, isActive: Bool) {
        let clampedValue = clamp(value, minimum: -1, maximum: 1)
        let normalizedValue = abs(clampedValue) < 0.015 ? 0 : clampedValue
        let normalizedVelocity = abs(velocityApprox) < 0.05 ? 0 : clamp(
            velocityApprox,
            minimum: -CoachPreviewConstants.scratchVelocityClamp,
            maximum: CoachPreviewConstants.scratchVelocityClamp
        )
        let direction = scratchDirection(for: normalizedValue)

        scratchValue = normalizedValue
        scratchVelocityApprox = normalizedVelocity
        scratchDirection = direction
        platterRotationDegrees = normalizedValue * 120
        isScratchPadActive = isActive

        logScratchDiagnosticsIfNeeded(
            value: normalizedValue,
            direction: direction,
            velocityApprox: normalizedVelocity
        )
    }

    private func logScratchDiagnosticsIfNeeded(
        value: Double,
        direction: CoachScratchDirection,
        velocityApprox: Double
    ) {
        let snapshot = CoachTrainerLogSnapshot(
            scratchBucket: Int((value * 100).rounded()),
            velocityBucket: Int((velocityApprox * 10).rounded()),
            direction: direction
        )

        guard snapshot != lastLoggedScratchSnapshot else { return }
        lastLoggedScratchSnapshot = snapshot
        logScratchDiagnostics(value: value, direction: direction, velocityApprox: velocityApprox)
    }

    private func logScratchDiagnostics(
        value: Double,
        direction: CoachScratchDirection,
        velocityApprox: Double
    ) {
        print("[CoachTrainer] scratchValue=\(formattedScratchValue(value))")
        print("[CoachTrainer] direction=\(direction.rawValue)")
        print("[CoachTrainer] velocityApprox=\(formattedSignedMeasurement(velocityApprox))")
    }

    private func scratchDirection(for value: Double) -> CoachScratchDirection {
        if value > 0.015 {
            return .forward
        }

        if value < -0.015 {
            return .backward
        }

        return .neutral
    }

    private func formattedScratchValue(_ value: Double) -> String {
        if abs(value) < 0.005 {
            return "0.00"
        }

        return String(format: "%+.2f", value)
    }

    private func formattedSignedMeasurement(_ value: Double) -> String {
        if abs(value) < 0.005 {
            return "0.00"
        }

        return String(format: "%+.2f", value)
    }

    private func formattedDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return "\(Int((duration * 1_000).rounded())) ms"
    }

    private func prepareAudioMonitoringIfNeeded() {
        if inputSourceBeforePreview == nil {
            inputSourceBeforePreview = audioEngine.currentInputSource
        }

        guard !audioEngine.isRunning else { return }
        startedAudioEngineForPreview = true
        audioEngine.start()
    }

    private func teardownAudioMonitoringIfNeeded() {
        if let inputSourceBeforePreview,
           inputSourceBeforePreview != audioEngine.currentInputSource {
            audioEngine.selectInputSource(inputSourceBeforePreview)
        }
        inputSourceBeforePreview = nil

        guard startedAudioEngineForPreview else { return }
        audioEngine.stop()
        startedAudioEngineForPreview = false
    }

    private func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}

private struct CoachPreviewARViewContainer: UIViewRepresentable {
    let viewportSize: CGSize
    let animationMode: CoachPreviewAnimationMode
    let scratchValue: Double
    let scratchVelocityApprox: Double
    var onStatusChange: ((CoachPreviewState) -> Void)? = nil

    final class Coordinator {
        var loadTask: Task<Void, Never>?
        var animationController: AnimationPlaybackController?
        var platterEntity: Entity?
        var lastAnimationMode: CoachPreviewAnimationMode?
        var lastPlatterSnapshot: CoachTrainer3DLogSnapshot?

        @MainActor
        func apply(animationMode: CoachPreviewAnimationMode) {
            guard lastAnimationMode != animationMode else { return }
            lastAnimationMode = animationMode

            guard let animationController, animationController.isValid else { return }

            switch animationMode {
            case .pausedForScratch:
                animationController.pause()
            case .looping(let speed):
                animationController.speed = speed
                animationController.resume()
            }
        }

        @MainActor
        func applyPlatterState(scratchValue: Double, scratchVelocityApprox: Double) {
            guard let platterEntity else { return }

            let baseRotation = Float(scratchValue) * 132
            let velocityContribution = Float(scratchVelocityApprox) * 12
            let rotationDegrees = max(
                min(baseRotation + velocityContribution, CoachPreviewConstants.platterRotationLimitDegrees),
                -CoachPreviewConstants.platterRotationLimitDegrees
            )

            var platterTransform = platterEntity.transform
            platterTransform.rotation = simd_quatf(
                angle: rotationDegrees * .pi / 180,
                axis: SIMD3<Float>(0, 1, 0)
            )
            platterEntity.transform = platterTransform

            let snapshot = CoachTrainer3DLogSnapshot(
                scratchBucket: Int((scratchValue * 100).rounded()),
                rotationBucket: Int(rotationDegrees.rounded())
            )

            guard snapshot != lastPlatterSnapshot else { return }
            lastPlatterSnapshot = snapshot

            print("[CoachTrainer3D] platterRotation=\(CoachPreviewLoader.formatDecimal(rotationDegrees))")
            print("[CoachTrainer3D] scratchValue=\(String(format: "%+.2f", scratchValue))")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        configure(arView)
        DispatchQueue.main.async { [weak arView] in
            guard let arView else { return }
            disableStatisticsOverlay(on: arView)
        }

        context.coordinator.loadTask = Task { @MainActor in
            publish(CoachPreviewLoader.loadingStatus())

            do {
                let loadedCoach = try await CoachPreviewLoader.loadCoachEntity(viewportSize: viewportSize)
                let anchor = AnchorEntity(world: .zero)
                anchor.addChild(loadedCoach.entity)
                let platterEntity = makeTrainerPlatter(
                    around: loadedCoach.visualBounds,
                    viewportSize: viewportSize
                )
                anchor.addChild(platterEntity)
                context.coordinator.animationController = loadedCoach.animationController
                context.coordinator.platterEntity = platterEntity

                arView.scene.anchors.removeAll()
                arView.scene.addAnchor(anchor)
                context.coordinator.apply(animationMode: animationMode)
                context.coordinator.applyPlatterState(
                    scratchValue: scratchValue,
                    scratchVelocityApprox: scratchVelocityApprox
                )

                publish(CoachPreviewLoader.loadedStatus(for: loadedCoach))
            } catch {
                print("[CoachPreview] loadSucceeded=false error=\(String(reflecting: error))")
                publish(CoachPreviewLoader.failureStatus(for: error))
            }
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        configure(uiView)
        context.coordinator.apply(animationMode: animationMode)
        context.coordinator.applyPlatterState(
            scratchValue: scratchValue,
            scratchVelocityApprox: scratchVelocityApprox
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
    }

    @MainActor
    private func publish(_ status: CoachPreviewState) {
        onStatusChange?(status)
    }

    private func configure(_ arView: ARView) {
        disableStatisticsOverlay(on: arView)
        arView.debugOptions = []
        arView.debugOptions.remove(.showStatistics)
        arView.__statisticsOptions = []
        arView.__disableStatisticsRendering = true
        disableShowStatisticsSelectorIfAvailable(on: arView)
        arView.environment.background = .color(.black)
    }

    private func disableStatisticsOverlay(on arView: ARView) {
        arView.debugOptions = []
        arView.debugOptions.remove(.showStatistics)
        arView.__statisticsOptions = []
        arView.__disableStatisticsRendering = true
        disableShowStatisticsSelectorIfAvailable(on: arView)
    }

    private func disableShowStatisticsSelectorIfAvailable(on arView: ARView) {
        let selector = NSSelectorFromString("setShowStatistics:")
        guard arView.responds(to: selector) else { return }
        (arView as NSObject).setValue(false, forKey: "showStatistics")
    }

    @MainActor
    private func makeTrainerPlatter(around coachBounds: BoundingBox, viewportSize: CGSize) -> Entity {
        let baseMaterial = SimpleMaterial(
            color: UIColor(white: 0.76, alpha: 1),
            roughness: 0.08,
            isMetallic: true
        )
        let topSurfaceMaterial = SimpleMaterial(
            color: UIColor(white: 0.9, alpha: 1),
            roughness: 0.12,
            isMetallic: true
        )
        let accentSurfaceMaterial = UnlitMaterial(
            color: UIColor(red: 0.96, green: 0.97, blue: 1, alpha: 1)
        )
        let pedestalMaterial = SimpleMaterial(
            color: UIColor(white: 0.09, alpha: 1),
            roughness: 0.5,
            isMetallic: false
        )
        let markerMaterial = UnlitMaterial(
            color: UIColor(red: 0.97, green: 0.72, blue: 0.14, alpha: 1),
        )
        let spindleMaterial = SimpleMaterial(
            color: UIColor(white: 0.98, alpha: 1),
            roughness: 0.04,
            isMetallic: true
        )

        let platterEntity = ModelEntity(
            mesh: .generateCylinder(
                height: CoachPreviewConstants.platterHeight,
                radius: CoachPreviewConstants.platterRadius
            ),
            materials: [baseMaterial]
        )
        platterEntity.name = "CoachTrainerPlatter"
        platterEntity.position = platterPosition(for: coachBounds, viewportSize: viewportSize)

        let pedestal = ModelEntity(
            mesh: .generateCylinder(
                height: CoachPreviewConstants.platterHeight * 0.9,
                radius: CoachPreviewConstants.platterRadius * 1.12
            ),
            materials: [pedestalMaterial]
        )
        pedestal.position.y = -(CoachPreviewConstants.platterHeight * 0.18)
        platterEntity.addChild(pedestal)

        let topSurface = ModelEntity(
            mesh: .generateCylinder(
                height: CoachPreviewConstants.platterSurfaceHeight,
                radius: CoachPreviewConstants.platterRadius * 0.84
            ),
            materials: [topSurfaceMaterial]
        )
        topSurface.position.y = (CoachPreviewConstants.platterHeight + CoachPreviewConstants.platterSurfaceHeight) / 2
        platterEntity.addChild(topSurface)

        let accentSurface = ModelEntity(
            mesh: .generateCylinder(
                height: CoachPreviewConstants.platterAccentHeight,
                radius: CoachPreviewConstants.platterRadius * 0.68
            ),
            materials: [accentSurfaceMaterial]
        )
        accentSurface.position.y = (
            CoachPreviewConstants.platterHeight
            + CoachPreviewConstants.platterSurfaceHeight
            + CoachPreviewConstants.platterAccentHeight
        ) / 2 + 0.001
        platterEntity.addChild(accentSurface)

        let spindle = ModelEntity(
            mesh: .generateCylinder(
                height: CoachPreviewConstants.platterHeight * 0.7,
                radius: 0.02
            ),
            materials: [spindleMaterial]
        )
        spindle.position.y = CoachPreviewConstants.platterHeight * 0.48
        platterEntity.addChild(spindle)

        let marker = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(
                    CoachPreviewConstants.platterMarkerWidth,
                    CoachPreviewConstants.platterSurfaceHeight,
                    CoachPreviewConstants.platterMarkerLength
                ),
                cornerRadius: 0.002
            ),
            materials: [markerMaterial]
        )
        marker.position = SIMD3<Float>(
            0,
            (CoachPreviewConstants.platterHeight + CoachPreviewConstants.platterSurfaceHeight) / 2 + 0.002,
            -(CoachPreviewConstants.platterRadius * 0.36)
        )
        platterEntity.addChild(marker)

        print("[CoachPreview] platter.diameter=\(CoachPreviewLoader.formatDecimal(CoachPreviewConstants.platterRadius * 2))")
        print("[CoachPreview] platter.position=\(CoachPreviewLoader.formatVector(platterEntity.position))")
        return platterEntity
    }

    private func platterPosition(for coachBounds: BoundingBox, viewportSize: CGSize) -> SIMD3<Float> {
        let waistHeight = coachBounds.min.y + (coachBounds.extents.y * CoachPreviewConstants.platterWaistHeightRatio)
        let targetDistance = platterDistanceFromCamera(for: viewportSize)
        let coachForwardLimit = coachBounds.max.z + CoachPreviewConstants.platterForwardGap
        let minimumDistanceZ = -CoachPreviewConstants.minimumPlatterDistanceFromCamera
        let preferredPlatterZ = max(-targetDistance, coachForwardLimit)
        let platterZ = min(preferredPlatterZ, minimumDistanceZ)

        return SIMD3<Float>(coachBounds.center.x, waistHeight, platterZ)
    }

    private func platterDistanceFromCamera(for viewportSize: CGSize) -> Float {
        let aspectRatio = max(Float(viewportSize.width / max(viewportSize.height, 1)), 0.75)
        let verticalFieldOfView = CoachPreviewConstants.cameraFieldOfViewDegrees * .pi / 180
        let horizontalFieldOfView = 2 * atan(tan(verticalFieldOfView / 2) * aspectRatio)
        let targetRatio = max(CoachPreviewConstants.platterTargetScreenWidthRatio, 0.01)
        let targetDistance = CoachPreviewConstants.platterRadius / (targetRatio * tan(horizontalFieldOfView / 2))

        return min(
            max(targetDistance, CoachPreviewConstants.minimumPlatterDistanceFromCamera),
            CoachPreviewConstants.maximumPlatterDistanceFromCamera
        )
    }
}

#if DEBUG
struct CoachPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CoachPreviewView()
        }
    }
}
#endif

#endif
