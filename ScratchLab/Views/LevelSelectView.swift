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
            return CoachCopy.Combo.statusCleared
        }
        let best = Int(comboProgress?.comboAccuracy ?? 0)
        return best > 0 ? CoachCopy.Combo.bestRunPercent(best) : CoachCopy.Combo.statusNoClean
    }

    private var comboStatusValue: String {
        if comboProgress?.comboCompleted == true {
            return CoachCopy.Combo.valueCleared
        }
        return (comboProgress?.comboAccuracy ?? 0) > 0 ? CoachCopy.Combo.valueBuilding : CoachCopy.Combo.valueFresh
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
            Text(CoachCopy.Practice.liveTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text(CoachCopy.Practice.liveSubtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            if FeatureFlags.streakChipEnabled {
                streakChip
                    .padding(.top, 4)
            }
        }
    }

    private var streakChip: some View {
        let streak = progressManager.currentStreak
        let isActive = streak > 0
        let label = isActive
            ? CoachCopy.Progression.streakDay(streak)
            : CoachCopy.Progression.streakStart
        return HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? ScratchLabPalette.demoGold : .white.opacity(0.35))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var practiceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(CoachCopy.Practice.selectScratchHeader)
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
                    Text(CoachCopy.Combo.babyFlowTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text(CoachCopy.Combo.babyFlowBody)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Text(comboProgress?.comboCompleted == true ? CoachCopy.Combo.badgeCleared : CoachCopy.Combo.badgeLive)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(comboProgress?.comboCompleted == true ? .black : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(comboProgress?.comboCompleted == true ? Color(hex: "FFD700") : Color(hex: "263238"))
                    .cornerRadius(999)
            }

            HStack(spacing: 16) {
                StatItem(
                    icon: "link",
                    value: "\(Int(comboProgress?.comboAccuracy ?? 0))%",
                    label: CoachCopy.Combo.bestRunLabel,
                    color: Color(hex: "00BCD4")
                )

                StatItem(
                    icon: comboProgress?.comboCompleted == true ? "checkmark.seal.fill" : "repeat",
                    value: comboStatusValue,
                    label: CoachCopy.Combo.statusLabel,
                    color: Color(hex: "FF9800")
                )
            }

            Text(comboStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))

            Text(CoachCopy.Combo.cuesVisualNote)
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
                    StatItem(
                        icon: "star.fill",
                        value: "\(Int(progressManager.babyScratchProgress?.bestAccuracy ?? 0))%",
                        label: "Best Accuracy",
                        color: Color(hex: "FFD700")
                    )

                    StatItem(
                        icon: "waveform.path.ecg",
                        value: "\(progressManager.babyScratchProgress?.practiceCount ?? 0)",
                        label: "Attempts",
                        color: Color(hex: "4CAF50")
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

// MARK: - Level Card

struct LevelCard: View {
    let level: Level
    let progress: LevelProgress?
    let isUnlocked: Bool
    let onTap: () -> Void
    
    @State private var isPressed = false
    
    private var aiCharacter: AICharacter {
        AICharacter(rawValue: level.aiCharacter) ?? .rookie
    }
    
    var body: some View {
        Button(action: { if isUnlocked { onTap() } }) {
            HStack(spacing: 16) {
                // Level number with character avatar
                ZStack {
                    Circle()
                        .fill(
                            isUnlocked ?
                            LinearGradient(
                                colors: [Color(hex: aiCharacter.primaryColor), Color(hex: aiCharacter.primaryColor).opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ) :
                            LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 60, height: 60)
                    
                    if isUnlocked {
                        Text("\(level.id)")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                
                // Level info
                VStack(alignment: .leading, spacing: 6) {
                    Text(level.name.uppercased())
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(isUnlocked ? .white : .white.opacity(0.4))
                    
                    Text(level.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isUnlocked ? .white.opacity(0.7) : .white.opacity(0.3))
                        .lineLimit(2)
                    
                    // Progress bar
                    if isUnlocked, let prog = progress {
                        HStack(spacing: 8) {
                            // Scratches mastered
                            ProgressIndicator(
                                current: min(prog.scratchesMastered, 1),
                                total: 1,
                                color: Color(hex: aiCharacter.primaryColor)
                            )
                            
                            // Stars
                            HStack(spacing: 2) {
                                ForEach(0..<3) { i in
                                    Image(systemName: i < prog.totalStars ? "star.fill" : "star")
                                        .font(.caption2)
                                        .foregroundColor(Color(hex: "FFD700"))
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // AI Character indicator
                if isUnlocked {
                    VStack(spacing: 4) {
                        Text(aiCharacter == .rookie ? "🎧" : aiCharacter == .flash ? "⚡️" : aiCharacter == .cipher ? "🎤" : aiCharacter == .nova ? "🌟" : "👑")
                            .font(.title2)
                        Text(aiCharacter.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                
                Image(systemName: "chevron.right")
                    .foregroundColor(isUnlocked ? .white.opacity(0.5) : .clear)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isUnlocked ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isUnlocked ? Color(hex: aiCharacter.primaryColor).opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .opacity(isUnlocked ? 1.0 : 0.6)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isUnlocked)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Progress Indicator

struct ProgressIndicator: View {
    let current: Int
    let total: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < current ? color : color.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Level Detail View

struct LevelDetailView: View {
    let level: Level
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var audioEngine: AudioEngine
    
    @State private var selectedScratch: Scratch?
    @State private var showingPractice = false
    
    private var scratches: [Scratch] {
        ScratchLibrary.shared.scratchesForLevel(level.id).filter { $0.id == "baby_scratch" }
    }
    
    private var aiCharacter: AICharacter {
        AICharacter(rawValue: level.aiCharacter) ?? .rookie
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Level header
                        levelHeader
                        
                        // Scratches grid
                        VStack(spacing: 16) {
                            Text("SCRATCHES TO MASTER")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            ForEach(scratches, id: \.id) { scratch in
                                ScratchCard(
                                    scratch: scratch,
                                    progress: progressManager.getProgressForScratch(scratch.id),
                                    isUnlocked: progressManager.isScratchUnlocked(scratch.id),
                                    onTap: {
                                        selectedScratch = scratch
                                        showingPractice = true
                                    }
                                )
                            }
                        }
                        
                        // MVP mode status
                        mvpModeSection
                        
                        Spacer()
                            .frame(height: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Level \(level.id): \(level.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "FFD700"))
                }
            }
            .fullScreenCover(isPresented: $showingPractice) {
                if let scratch = selectedScratch {
                    PracticeModeView(scratch: scratch)
                        .environmentObject(audioEngine)
                        .environmentObject(progressManager)
                }
            }
        }
    }
    
    private var levelHeader: some View {
        VStack(spacing: 16) {
            // AI Character
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: aiCharacter.primaryColor), Color(hex: aiCharacter.primaryColor).opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                
                Text(aiCharacter == .rookie ? "🎧" : aiCharacter == .flash ? "⚡️" : aiCharacter == .cipher ? "🎤" : aiCharacter == .nova ? "🌟" : "👑")
                    .font(.system(size: 40))
            }
            
            VStack(spacing: 4) {
                Text(aiCharacter.rawValue)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                
                Text(aiCharacter.description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 20)
    }
    
    private var mvpModeSection: some View {
        VStack(spacing: 16) {
            Text("CURRENT FOCUS")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "FFD700"))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "checkmark")
                        .font(.title2)
                        .foregroundColor(.black)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Baby Scratch is active")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("Stay with Baby Scratch to lock in timing, fader control, and smooth motion before moving into longer phrases.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: "FFD700").opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color(hex: "FFD700").opacity(0.25), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Scratch Card

struct ScratchCard: View {
    let scratch: Scratch
    let progress: ScratchProgress?
    let isUnlocked: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: { if isUnlocked { onTap() } }) {
            HStack(spacing: 16) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    if let prog = progress, prog.isMastered {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(Color(hex: "4CAF50"))
                    } else if isUnlocked {
                        Text("\(Int(progress?.bestAccuracy ?? 0))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(statusColor)
                    } else {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                
                // Scratch info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(scratch.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isUnlocked ? .white : .white.opacity(0.4))
                        
                        if scratch.faderRequired {
                            Text("FADER")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(hex: "2196F3"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "2196F3").opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(scratch.technique.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    
                    // Progress bar
                    if isUnlocked, let prog = progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 4)
                                    .cornerRadius(2)
                                
                                Rectangle()
                                    .fill(statusColor)
                                    .frame(width: geo.size.width * CGFloat(prog.progressToMastery / 100), height: 4)
                                    .cornerRadius(2)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                
                Spacer()
                
                // Practice count
                if isUnlocked, let prog = progress, prog.practiceCount > 0 {
                    VStack(spacing: 2) {
                        Text("\(prog.practiceCount)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        Text("tries")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                
                if isUnlocked {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isUnlocked)
        .opacity(isUnlocked ? 1.0 : 0.5)
    }
    
    private var statusColor: Color {
        guard let prog = progress else { return Color.gray }
        
        if prog.isMastered {
            return Color(hex: "4CAF50") // Green
        } else if prog.bestAccuracy >= 70 {
            return Color(hex: "FF9800") // Orange
        } else if prog.bestAccuracy > 0 {
            return Color(hex: "F44336") // Red
        } else {
            return Color.gray
        }
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
