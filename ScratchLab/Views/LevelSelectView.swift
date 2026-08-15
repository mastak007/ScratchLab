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
                    .foregroundColor(Color(hex: "FFD700"))
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
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
            
            Text("Pick a scratch first, then open the existing live setup with optional beat guidance and ScratchLab Coach.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var practiceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SELECT A SCRATCH")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.5))

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
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text("Visual combo challenge: lock 4 baby scratches in one loop at 100 BPM with optional beat guidance or live audio only.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Text(comboProgress?.comboCompleted == true ? "CLEARED" : "LIVE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(comboProgress?.comboCompleted == true ? .black : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(comboProgress?.comboCompleted == true ? Color(hex: "FFD700") : Color(hex: "263238"))
                    .cornerRadius(999)
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
                    variant: .warning,
                    systemImage: comboProgress?.comboCompleted == true ? "checkmark.seal.fill" : "repeat"
                )
            }

            Text(comboStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))

            Text("The cue stays visual here too, so the analyzer keeps following your live input without loading a beat.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))

            Text(progressManager.isScratchMastered("baby_scratch")
                ? "You’ve got the core motion. Now clear one full phrase."
                : "You can test the challenge now, but the cleanest runs come after Baby Scratch starts feeling automatic.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))

            Button(action: { showingComboChallenge = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    Text(comboProgress?.comboCompleted == true ? "Run Combo Again" : "Start Combo Challenge")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "FFD700"), Color(hex: "FF9800")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(14)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "FFD700").opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(16)
    }

    @ViewBuilder
    private func practiceScratchCard(for scratch: Scratch) -> some View {
        let isBabyScratch = scratch.id == babyScratch.id

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scratch.name.uppercased())
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text(scratch.description)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(isBabyScratch ? "FOUNDATION" : "COACH")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isBabyScratch ? .black : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isBabyScratch ? Color(hex: "FFD700") : Color(hex: "263238"))
                    .cornerRadius(999)
            }

            if isBabyScratch {
                HStack(spacing: 16) {
                    StatusBadge(
                        title: "Best estimate",
                        value: "\(Int(progressManager.babyScratchProgress?.bestAccuracy ?? 0))%",
                        variant: .warning,
                        systemImage: "star.fill"
                    )

                    StatusBadge(
                        title: "Attempts",
                        value: "\(progressManager.babyScratchProgress?.practiceCount ?? 0)",
                        variant: .success,
                        systemImage: "waveform.path.ecg"
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coach card and local demo audio load in the same setup overlay after you pick this scratch.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))

                    Text("Baby Scratch remains the tracked foundation drill. Chirp Flare opens the same live setup without forcing a Baby-only route.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
            }

            Button(action: { selectedPracticeScratch = scratch }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(isBabyScratch ? "Start Baby Scratch" : "Start Chirp Flare")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: isBabyScratch
                            ? [Color(hex: "4CAF50"), Color(hex: "2E7D32")]
                            : [Color(hex: "0EA5E9"), Color(hex: "1D4ED8")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(14)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isBabyScratch ? Color(hex: "FFD700").opacity(0.18) : Color(hex: "0EA5E9").opacity(0.22),
                    lineWidth: 1
                )
        )
        .cornerRadius(16)
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
