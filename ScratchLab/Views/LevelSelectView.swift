// LevelSelectView.swift
// ScratchLab - Level Selection
// Visual level map showing progress through all 5 levels

import SwiftUI

struct LevelSelectView: View {
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var gameState: GameState
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedLevel: Int?
    @State private var showingLevelDetail = false
    
    var body: some View {
        ZStack {
            BackgroundView()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerView
                        .padding(.top, 20)
                    
                    // Level cards
                    ForEach(Level.allLevels, id: \.id) { level in
                        LevelCard(
                            level: level,
                            progress: progressManager.getProgressForLevel(level.id),
                            isUnlocked: progressManager.isLevelUnlocked(level.id),
                            onTap: {
                                selectedLevel = level.id
                                showingLevelDetail = true
                            }
                        )
                    }
                    
                    // Bottom padding
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.horizontal, 20)
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
        .sheet(isPresented: $showingLevelDetail) {
            if let levelID = selectedLevel, let level = Level.level(levelID) {
                LevelDetailView(level: level)
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("SELECT LEVEL")
                .font(.custom("Futura-Bold", size: 28))
                .foregroundColor(.white)
            
            Text("Master all 4 scratches to unlock the combo challenge")
                .font(.custom("Futura-Medium", size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
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
                            .font(.custom("Futura-Bold", size: 28))
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
                        .font(.custom("Futura-Bold", size: 18))
                        .foregroundColor(isUnlocked ? .white : .white.opacity(0.4))
                    
                    Text(level.description)
                        .font(.custom("Futura-Medium", size: 12))
                        .foregroundColor(isUnlocked ? .white.opacity(0.7) : .white.opacity(0.3))
                        .lineLimit(2)
                    
                    // Progress bar
                    if isUnlocked, let prog = progress {
                        HStack(spacing: 8) {
                            // Scratches mastered
                            ProgressIndicator(
                                current: prog.scratchesMastered,
                                total: 4,
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
                            .font(.custom("Futura-Medium", size: 9))
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
    
    @State private var selectedScratch: Scratch?
    @State private var showingPractice = false
    
    private var scratches: [Scratch] {
        ScratchLibrary.shared.scratchesForLevel(level.id)
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
                                .font(.custom("Futura-Bold", size: 14))
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
                        
                        // Combo challenge
                        comboSection
                        
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
                    .font(.custom("Futura-Bold", size: 20))
                    .foregroundColor(.white)
                
                Text(aiCharacter.description)
                    .font(.custom("Futura-Medium", size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 20)
    }
    
    private var comboSection: some View {
        VStack(spacing: 16) {
            Text("COMBO CHALLENGE")
                .font(.custom("Futura-Bold", size: 14))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            let isComboAvailable = progressManager.isComboAvailable(level.id)
            let comboProgress = progressManager.getProgressForLevel(level.id)
            
            Button(action: {
                // Start combo challenge
            }) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(isComboAvailable ? Color(hex: "FFD700") : Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                        
                        if isComboAvailable {
                            Image(systemName: "bolt.fill")
                                .font(.title2)
                                .foregroundColor(.black)
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ScratchLibrary.shared.comboForLevel(level.id)?.name ?? "Level Combo")
                            .font(.custom("Futura-Bold", size: 16))
                            .foregroundColor(isComboAvailable ? .white : .white.opacity(0.4))
                        
                        if isComboAvailable {
                            if let combo = comboProgress, combo.comboCompleted {
                                Text("Completed! Best: \(Int(combo.comboAccuracy))%")
                                    .font(.custom("Futura-Medium", size: 12))
                                    .foregroundColor(Color(hex: "4CAF50"))
                            } else {
                                Text("Chain all 4 scratches with 90% accuracy")
                                    .font(.custom("Futura-Medium", size: 12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        } else {
                            Text("Master all scratches to unlock")
                                .font(.custom("Futura-Medium", size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    
                    Spacer()
                    
                    if isComboAvailable {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isComboAvailable ? Color(hex: "FFD700").opacity(0.15) : Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isComboAvailable ? Color(hex: "FFD700").opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!isComboAvailable)
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
                            .font(.custom("Futura-Bold", size: 12))
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
                            .font(.custom("Futura-Bold", size: 16))
                            .foregroundColor(isUnlocked ? .white : .white.opacity(0.4))
                        
                        if scratch.faderRequired {
                            Text("FADER")
                                .font(.custom("Futura-Bold", size: 8))
                                .foregroundColor(Color(hex: "2196F3"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "2196F3").opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(scratch.technique.rawValue)
                        .font(.custom("Futura-Medium", size: 11))
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
                            .font(.custom("Futura-Bold", size: 14))
                            .foregroundColor(.white.opacity(0.6))
                        Text("tries")
                            .font(.custom("Futura-Medium", size: 9))
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

#Preview {
    NavigationStack {
        LevelSelectView()
    }
    .environmentObject(GameState())
    .environmentObject(AudioEngine())
    .environmentObject(ProgressManager())
}
