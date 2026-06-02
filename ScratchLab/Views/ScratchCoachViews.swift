import SwiftUI

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

struct ScratchCoachCardContent<Controls: View>: View {
    let instruction: ScratchCoachInstruction
    let demoStatusMessage: String
    let playbackTimeProvider: () -> TimeInterval
    let isPlayingProvider: () -> Bool
    let theme: ScratchCoachCardTheme

    private let controls: Controls
    @State private var showsDetails = false

    init(
        instruction: ScratchCoachInstruction,
        demoStatusMessage: String,
        playbackTimeProvider: @escaping () -> TimeInterval,
        isPlayingProvider: @escaping () -> Bool,
        theme: ScratchCoachCardTheme,
        @ViewBuilder controls: () -> Controls
    ) {
        self.instruction = instruction
        self.demoStatusMessage = demoStatusMessage
        self.playbackTimeProvider = playbackTimeProvider
        self.isPlayingProvider = isPlayingProvider
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
