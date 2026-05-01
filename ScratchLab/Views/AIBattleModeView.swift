// AIBattleModeView.swift
// ScratchLab - AI Battle Mode
// Battle against AI opponents with increasing difficulty

import SwiftUI

// MARK: - AI Battle Setup View
struct AIBattleSetupView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var gameState: GameState
    
    @State private var selectedCharacter: AICharacter = .rookie
    @State private var selectedScratch: Scratch?
    @State private var showingBattle = false
    
    var body: some View {
        ZStack {
            BackgroundView()
            
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 8) {
                        Text("AI BATTLE")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Challenge an AI opponent")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 20)
                    
                    // Character selection
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CHOOSE OPPONENT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 20)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(AICharacter.allCases, id: \.self) { character in
                                    AICharacterCard(
                                        character: character,
                                        isSelected: selectedCharacter == character,
                                        isUnlocked: isCharacterUnlocked(character),
                                        onSelect: {
                                            if isCharacterUnlocked(character) {
                                                selectedCharacter = character
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    
                    // Scratch selection
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SELECT SCRATCH")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 20)
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(availableScratches, id: \.id) { scratch in
                                ScratchSelectionCard(
                                    scratch: scratch,
                                    isSelected: selectedScratch?.id == scratch.id,
                                    onSelect: { selectedScratch = scratch }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    
                    // Battle button
                    Button(action: { showingBattle = true }) {
                        HStack {
                            Image(systemName: "flame.fill")
                            Text("START BATTLE")
                        }
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                    }
                    .disabled(selectedScratch == nil)
                    .opacity(selectedScratch == nil ? 0.5 : 1.0)
                    .padding(.horizontal, 20)
                    
                    Spacer()
                        .frame(height: 40)
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
        .fullScreenCover(isPresented: $showingBattle) {
            if let scratch = selectedScratch {
                AIBattleView(scratch: scratch, opponent: selectedCharacter)
            }
        }
    }
    
    private func isCharacterUnlocked(_ character: AICharacter) -> Bool {
        return progressManager.isLevelUnlocked(character.level)
    }
    
    private var availableScratches: [Scratch] {
        // Return scratches the user has mastered
        return ScratchLibrary.shared.allScratches.filter { scratch in
            progressManager.isScratchMastered(scratch.id)
        }
    }
}

// MARK: - AI Character Card
struct AICharacterCard: View {
    let character: AICharacter
    let isSelected: Bool
    let isUnlocked: Bool
    let onSelect: () -> Void
    
    private var emoji: String {
        switch character {
        case .rookie: return "🎧"
        case .flash: return "⚡️"
        case .cipher: return "🎤"
        case .nova: return "🌟"
        case .legend: return "👑"
        }
    }
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 12) {
                // Character avatar
                ZStack {
                    Circle()
                        .fill(
                            isUnlocked ?
                            LinearGradient(
                                colors: [Color(hex: character.primaryColor), Color(hex: character.primaryColor).opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ) :
                            LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 80, height: 80)
                    
                    if isUnlocked {
                        Text(emoji)
                            .font(.system(size: 36))
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    // Selection ring
                    if isSelected {
                        Circle()
                            .stroke(Color(hex: "FFD700"), lineWidth: 3)
                            .frame(width: 86, height: 86)
                    }
                }
                
                // Character name
                Text(character.rawValue)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isUnlocked ? .white : .white.opacity(0.4))
                
                // Difficulty indicator
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(i < character.level ? Color(hex: character.primaryColor) : Color.white.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color(hex: character.primaryColor).opacity(0.15) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isUnlocked)
    }
}

// MARK: - Scratch Selection Card
struct ScratchSelectionCard: View {
    let scratch: Scratch
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(scratch.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "4CAF50"))
                    }
                }
                
                Text("Level \(scratch.level)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color(hex: "4CAF50").opacity(0.15) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color(hex: "4CAF50").opacity(0.3) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - AI Battle View
struct AIBattleView: View {
    let scratch: Scratch
    let opponent: AICharacter
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var progressManager: ProgressManager
    
    // Battle state
    @State private var battlePhase: BattlePhase = .intro
    @State private var playerScore: Int = 0
    @State private var aiScore: Int = 0
    @State private var currentRound: Int = 1
    @State private var totalRounds: Int = 3
    @State private var timeRemaining: TimeInterval = 30
    @State private var timer: Timer?
    
    // Player stats
    @State private var playerAccuracy: Double = 0
    @State private var playerAttempts: Int = 0
    
    // Animation
    @State private var showCountdown = false
    @State private var countdownNumber = 3
    
    enum BattlePhase {
        case intro
        case countdown
        case playerTurn
        case aiTurn
        case roundResult
        case finalResult
    }
    
    private var opponentEmoji: String {
        switch opponent {
        case .rookie: return "🎧"
        case .flash: return "⚡️"
        case .cipher: return "🎤"
        case .nova: return "🌟"
        case .legend: return "👑"
        }
    }
    
    var body: some View {
        ZStack {
            // Camera background during player turn
            if battlePhase == .playerTurn {
                CameraPreviewView()
                    .ignoresSafeArea()
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            } else {
                BackgroundView()
            }
            
            VStack {
                // Header with scores
                battleHeader
                
                Spacer()
                
                // Main content based on phase
                switch battlePhase {
                case .intro:
                    introView
                case .countdown:
                    countdownView
                case .playerTurn:
                    playerTurnView
                case .aiTurn:
                    aiTurnView
                case .roundResult:
                    roundResultView
                case .finalResult:
                    finalResultView
                }
                
                Spacer()
            }
        }
        .onAppear {
            setupBattle()
        }
        .onDisappear {
            timer?.invalidate()
            audioEngine.stopAnalyzing()
        }
    }
    
    // MARK: - Header
    
    private var battleHeader: some View {
        HStack {
            // Player score
            VStack(spacing: 4) {
                Text("YOU")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                Text("\(playerScore)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            
            // VS / Round indicator
            VStack(spacing: 4) {
                Text("ROUND \(currentRound)/\(totalRounds)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "FFD700"))
                
                Text("VS")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                
                Text(scratch.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            // AI score
            VStack(spacing: 4) {
                Text(opponent.rawValue.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: opponent.primaryColor).opacity(0.8))
                Text("\(aiScore)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(Color(hex: opponent.primaryColor))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.5))
    }
    
    // MARK: - Intro View
    
    private var introView: some View {
        VStack(spacing: 32) {
            // Opponent avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: opponent.primaryColor), Color(hex: opponent.primaryColor).opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Text(opponentEmoji)
                    .font(.system(size: 60))
            }
            
            VStack(spacing: 8) {
                Text(opponent.rawValue)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                Text(opponent.description)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            // Battle info
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "music.note")
                    Text("Scratch: \(scratch.name)")
                }
                HStack {
                    Image(systemName: "clock")
                    Text("30 seconds per turn")
                }
                HStack {
                    Image(systemName: "flag.checkered")
                    Text("\(totalRounds) rounds")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
            
            // Start button
            Button(action: { startBattle() }) {
                Text("BATTLE!")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 200)
                    .padding(.vertical, 16)
                    .background(Color(hex: "FFD700"))
                    .cornerRadius(30)
            }
            
            Button(action: { dismiss() }) {
                Text("Back")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
    
    // MARK: - Countdown View
    
    private var countdownView: some View {
        VStack(spacing: 20) {
            Text("GET READY!")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            Text("\(countdownNumber)")
                .font(.system(size: 120, weight: .bold))
                .foregroundColor(Color(hex: "FFD700"))
        }
    }
    
    // MARK: - Player Turn View
    
    private var playerTurnView: some View {
        VStack(spacing: 24) {
            // Timer
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 8)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: CGFloat(timeRemaining / 30))
                    .stroke(Color(hex: "FFD700"), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                
                Text("\(Int(timeRemaining))")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Text("YOUR TURN")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(hex: "FFD700"))
            
            Text("Perform the \(scratch.name) scratch!")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            
            // Live stats
            HStack(spacing: 40) {
                VStack {
                    Text("\(Int(playerAccuracy))%")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    Text("Accuracy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                VStack {
                    Text("\(playerAttempts)")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    Text("Attempts")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(20)
            .background(Color.black.opacity(0.5))
            .cornerRadius(16)
        }
    }
    
    // MARK: - AI Turn View
    
    private var aiTurnView: some View {
        VStack(spacing: 32) {
            // AI avatar with animation
            ZStack {
                // Pulsing rings
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color(hex: opponent.primaryColor).opacity(0.3), lineWidth: 2)
                        .frame(width: CGFloat(140 + i * 30), height: CGFloat(140 + i * 30))
                }
                
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: opponent.primaryColor), Color(hex: opponent.primaryColor).opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Text(opponentEmoji)
                    .font(.system(size: 60))
            }
            
            VStack(spacing: 8) {
                Text("\(opponent.rawValue.uppercased())'S TURN")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(hex: opponent.primaryColor))
                
                Text("Watch and learn...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // Progress indicator
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: opponent.primaryColor)))
                .scaleEffect(1.5)
        }
    }
    
    // MARK: - Round Result View
    
    private var roundResultView: some View {
        let playerWonRound = playerScore > aiScore
        
        return VStack(spacing: 32) {
            Text(playerWonRound ? "🔥" : "😤")
                .font(.system(size: 80))
            
            Text(playerWonRound ? "ROUND WIN!" : "ROUND LOST")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(playerWonRound ? Color(hex: "4CAF50") : Color(hex: "F44336"))
            
            // Score comparison
            HStack(spacing: 40) {
                VStack {
                    Text("YOU")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text("\(playerScore)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Text("-")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white.opacity(0.3))
                
                VStack {
                    Text(opponent.rawValue.uppercased())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: opponent.primaryColor).opacity(0.8))
                    Text("\(aiScore)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(Color(hex: opponent.primaryColor))
                }
            }
            
            if currentRound < totalRounds {
                Button(action: { nextRound() }) {
                    Text("NEXT ROUND")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 200)
                        .padding(.vertical, 16)
                        .background(Color(hex: "FFD700"))
                        .cornerRadius(30)
                }
            }
        }
    }
    
    // MARK: - Final Result View
    
    private var finalResultView: some View {
        let playerWon = playerScore > aiScore
        
        return VStack(spacing: 32) {
            Text(playerWon ? "🏆" : "💪")
                .font(.system(size: 100))
            
            Text(playerWon ? "VICTORY!" : "DEFEAT")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(playerWon ? Color(hex: "FFD700") : Color(hex: "F44336"))
            
            if playerWon {
                Text("You defeated \(opponent.rawValue)!")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text("\(opponent.rawValue) wins this time")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Final scores
            HStack(spacing: 60) {
                VStack {
                    Text("YOU")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text("\(playerScore)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                }
                
                VStack {
                    Text(opponent.rawValue.uppercased())
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: opponent.primaryColor).opacity(0.8))
                    Text("\(aiScore)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(Color(hex: opponent.primaryColor))
                }
            }
            
            VStack(spacing: 12) {
                Button(action: { resetBattle() }) {
                    Text("REMATCH")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 200)
                        .padding(.vertical, 16)
                        .background(Color(hex: "FFD700"))
                        .cornerRadius(30)
                }
                
                Button(action: { dismiss() }) {
                    Text("Back to Menu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }
    
    // MARK: - Battle Logic
    
    private func setupBattle() {
        audioEngine.start()
        audioEngine.onScratchDetected = { result in
            handleScratchDetected(result)
        }
    }
    
    private func startBattle() {
        battlePhase = .countdown
        countdownNumber = 3
        
        // Countdown timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if countdownNumber > 1 {
                countdownNumber -= 1
            } else {
                timer.invalidate()
                startPlayerTurn()
            }
        }
    }
    
    private func startPlayerTurn() {
        battlePhase = .playerTurn
        timeRemaining = 30
        playerAccuracy = 0
        playerAttempts = 0
        
        audioEngine.startAnalyzing(for: scratch)
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                endPlayerTurn()
            }
        }
    }
    
    private func endPlayerTurn() {
        timer?.invalidate()
        audioEngine.stopAnalyzing()
        
        // Calculate player's round score
        let roundScore = Int(playerAccuracy * Double(playerAttempts) * 10)
        playerScore += roundScore
        
        // Start AI turn
        battlePhase = .aiTurn
        simulateAITurn()
    }
    
    private func simulateAITurn() {
        // Simulate AI performance based on skill level
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let aiAccuracy = Double.random(in: (opponent.skillMultiplier * 70)...(opponent.skillMultiplier * 100))
            let aiAttempts = Int.random(in: 8...15)
            let aiRoundScore = Int(aiAccuracy * Double(aiAttempts) * 10 * opponent.skillMultiplier)
            aiScore += aiRoundScore
            
            battlePhase = .roundResult
        }
    }
    
    private func nextRound() {
        currentRound += 1
        startBattle()
    }
    
    private func handleScratchDetected(_ result: ScratchAnalysisResult) {
        playerAttempts += 1
        
        if playerAccuracy == 0 {
            playerAccuracy = result.accuracy
        } else {
            playerAccuracy = (playerAccuracy * Double(playerAttempts - 1) + result.accuracy) / Double(playerAttempts)
        }
    }
    
    private func resetBattle() {
        currentRound = 1
        playerScore = 0
        aiScore = 0
        battlePhase = .intro
    }
}

#if DEBUG
struct AIBattleSetupView_Previews: PreviewProvider {
    static var previews: some View {
        AIBattleSetupView()
            .environmentObject(GameState())
            .environmentObject(AudioEngine())
            .environmentObject(ProgressManager())
    }
}
#endif
