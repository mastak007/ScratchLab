// LevelSelectView.swift
// ScratchLab - Level Selection
// Live practice scratch selection

import SwiftUI

struct LevelSelectView: View {
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var audioEngine: AudioEngine
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedPracticeScratch: Scratch?
    @State private var showingComboChallenge = false

    private var babyScratch: Scratch {
        ScratchLibrary.shared.scratch(byID: "baby_scratch") ?? ScratchLibrary.shared.allScratches[0]
    }

    private var chirpFlareScratch: Scratch {
        Scratch(
            id: "chirp_flare",
            name: "Chirp Flare",
            level: 3,
            description: "Blend a chirp-style record move with one light flare click so the cut stays tight while the record hand keeps moving.",
            difficulty: .advanced,
            technique: .combination,
            faderRequired: true,
            patternSignature: PatternSignature(
                waveformPattern: [0.0, 0.92, 0.18, -0.74, 0.0],
                expectedDuration: 0.34,
                peakCount: 2,
                crossfaderClicks: 2,
                rhythmPattern: [0.45, 0.55],
                frequencyProfile: .init(
                    dominantFrequencyRange: 350...3200,
                    hasSharpAttack: true,
                    hasReverseSound: true
                )
            ),
            referenceAudioName: nil,
            backingTrackName: "boom_bap_95bpm",
            tips: [
                "Start with a clean chirp before you add the flare click.",
                "Keep the crossfader click light so the pattern stays even.",
                "Match the forward and pullback distance before you speed up."
            ]
        )
    }

    private var practiceScratchOptions: [Scratch] {
        [babyScratch, chirpFlareScratch]
    }

    private var babyComboChallenge: ComboScratch {
        ComboScratch(
            id: "combo_mvp_baby_flow",
            name: "Baby Flow",
            level: 1,
            componentScratchIDs: Array(repeating: "baby_scratch", count: 4),
            description: "Land 4 baby scratches in one clean loop before the timer runs out.",
            bonusPoints: 300
        )
    }

    private var babyComboTimeline: ScratchRenderTimeline {
        ScratchRenderTimeline(
            events: (0..<4).map { index in
                ScratchRenderEvent(
                    scratchID: "baby_scratch",
                    startBeat: Double(index),
                    durationBeats: 1.0,
                    direction: .forward
                )
            },
            totalBeats: 4
        )
    }

    private var comboProgress: LevelProgress? {
        progressManager.babyComboProgress
    }

    private var comboStatusText: String {
        if comboProgress?.comboCompleted == true {
            return "Challenge cleared"
        }
        let best = Int(comboProgress?.comboAccuracy ?? 0)
        return best > 0 ? "Best run \(best)%" : "No clean loop yet"
    }

    private var comboStatusValue: String {
        if comboProgress?.comboCompleted == true {
            return "Cleared"
        }
        return (comboProgress?.comboAccuracy ?? 0) > 0 ? "Building" : "Fresh"
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundView()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        headerView

                        VStack(spacing: 20) {
                            practiceSelectionSection
                            comboCard
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, geometry.safeAreaInsets.top + 12)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 20) + 20)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Menu")
                    }
                    .foregroundColor(ScratchLabDesign.Sem.accent)
                }
            }
        }
        .fullScreenCover(item: $selectedPracticeScratch) { scratch in
            PracticeModeView(scratch: scratch, usesBackingTrack: false)
                .environmentObject(audioEngine)
                .environmentObject(progressManager)
        }
        .fullScreenCover(isPresented: $showingComboChallenge) {
            PracticeModeView(
                scratch: babyScratch,
                drillTimeline: babyComboTimeline,
                drillBPM: 100,
                comboChallenge: babyComboChallenge,
                usesBackingTrack: false
            )
            .environmentObject(audioEngine)
            .environmentObject(progressManager)
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("LIVE PRACTICE")
                .font(ScratchLabDesign.Typo.pageTitle)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

            Text("Pick a scratch first, then open the existing live setup with optional beat guidance and ScratchLab Coach.")
                .font(ScratchLabDesign.Typo.pageSubtitle)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var practiceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SELECT A SCRATCH")
                .font(ScratchLabDesign.Typo.pageEyebrow)
                .foregroundColor(ScratchLabDesign.Sem.textTertiary)

            ForEach(practiceScratchOptions) { scratch in
                practiceScratchCard(for: scratch)
            }
        }
    }

    private var comboCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BABY FLOW")
                        .font(ScratchLabDesign.Typo.title2)
                        .foregroundColor(ScratchLabDesign.Sem.textPrimary)

                    Text("Visual combo challenge: lock 4 baby scratches in one loop at 100 BPM with optional beat guidance or live audio only.")
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                }

                Spacer()

                Text(comboProgress?.comboCompleted == true ? "CLEARED" : "LIVE")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundColor(comboProgress?.comboCompleted == true ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(comboProgress?.comboCompleted == true ? ScratchLabDesign.Sem.success : ScratchLabDesign.Surface.subtleFill)
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                StatusBadge(
                    title: "Best Run",
                    value: "\(Int(comboProgress?.comboAccuracy ?? 0))%",
                    variant: .info,
                    systemImage: "link"
                )

                StatusBadge(
                    title: "Status",
                    value: comboStatusValue,
                    variant: comboProgress?.comboCompleted == true ? .success : .info,
                    systemImage: comboProgress?.comboCompleted == true ? "checkmark.seal.fill" : "repeat"
                )
            }

            Text(comboStatusText)
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Text("The cue stays visual here too, so the analyzer keeps following your live input without loading a beat.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Text(progressManager.isScratchMastered("baby_scratch")
                ? "You’ve got the core motion. Now clear one full phrase."
                : "You can test the challenge now, but the cleanest runs come after Baby Scratch starts feeling automatic.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Button(action: { showingComboChallenge = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    Text(comboProgress?.comboCompleted == true ? "Run Combo Again" : "Start Combo Challenge")
                }
            }
            .scratchLabPrimaryButton(fillsWidth: true)
        }
        .scratchLabCard(.standard)
    }

    @ViewBuilder
    private func practiceScratchCard(for scratch: Scratch) -> some View {
        let isBabyScratch = scratch.id == babyScratch.id

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scratch.name.uppercased())
                        .font(ScratchLabDesign.Typo.title2)
                        .foregroundColor(ScratchLabDesign.Sem.textPrimary)

                    Text(scratch.description)
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(isBabyScratch ? "FOUNDATION" : "COACH")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundColor(isBabyScratch ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isBabyScratch ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.subtleFill)
                    .clipShape(Capsule())
            }

            if isBabyScratch {
                HStack(spacing: 16) {
                    StatusBadge(
                        title: "Best estimate",
                        value: "\(Int(progressManager.babyScratchProgress?.bestAccuracy ?? 0))%",
                        variant: .info,
                        systemImage: "star.fill"
                    )

                    StatusBadge(
                        title: "Attempts",
                        value: "\(progressManager.babyScratchProgress?.practiceCount ?? 0)",
                        variant: .info,
                        systemImage: "waveform.path.ecg"
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coach card and local demo audio load in the same setup overlay after you pick this scratch.")
                        .font(ScratchLabDesign.Typo.bodySecondary)
                        .foregroundColor(ScratchLabDesign.Sem.textSecondary)

                    Text("Baby Scratch remains the tracked foundation drill. Chirp Flare opens the same live setup without forcing a Baby-only route.")
                        .font(ScratchLabDesign.Typo.bodySecondary)
                        .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                }
            }

            Button(action: { selectedPracticeScratch = scratch }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(isBabyScratch ? "Start Baby Scratch" : "Start Chirp Flare")
                }
            }
            .scratchLabPrimaryButton()
        }
        .scratchLabCard(isBabyScratch ? .selected : .standard)
    }
}

#if DEBUG
struct LevelSelectView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            LevelSelectView()
        }
        .environmentObject(GameState())
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
    }
}
#endif
