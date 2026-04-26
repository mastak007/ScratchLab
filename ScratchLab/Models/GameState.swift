// GameState.swift
// ScratchLab - Core Game State Management
// Manages overall game state, modes, and session data

import Foundation
import SwiftUI
import Combine

// MARK: - Game Mode
enum GameMode: String, CaseIterable {
    case practice = "Practice"
    case aiChallenge = "AI Challenge"
    case onlineBattle = "Online Battle"
    case tutorial = "Tutorial"
}

// MARK: - Game State
@MainActor
class GameState: ObservableObject {
    // Current mode and session
    @Published var currentMode: GameMode = .practice
    @Published var isInSession: Bool = false
    @Published var isPaused: Bool = false
    
    // Current scratch being practiced/played
    @Published var currentScratch: Scratch?
    @Published var currentLevel: Int = 1
    
    // Session timing
    @Published var sessionDuration: TimeInterval = 300 // Default 5 minutes
    @Published var sessionTimeRemaining: TimeInterval = 300
    @Published var sessionStartTime: Date?
    
    // Scoring
    @Published var currentScore: Int = 0
    @Published var currentAccuracy: Double = 0.0
    @Published var currentStreak: Int = 0
    @Published var bestStreak: Int = 0
    
    // Battle mode
    @Published var currentBattle: BattleSession?
    @Published var isMyTurn: Bool = true
    
    // AI Character
    @Published var currentAICharacter: AICharacter = .rookie
    
    // Timer
    private var sessionTimer: Timer?
    
    // MARK: - Session Management
    
    func startSession(mode: GameMode, scratch: Scratch?, duration: TimeInterval = 300) {
        currentMode = mode
        currentScratch = scratch
        sessionDuration = duration
        sessionTimeRemaining = duration
        currentScore = 0
        currentAccuracy = 0.0
        currentStreak = 0
        isInSession = true
        isPaused = false
        sessionStartTime = Date()
        
        // Start timer for timed modes
        if mode != .tutorial {
            startTimer()
        }
    }
    
    func pauseSession() {
        guard isInSession else { return }
        isPaused = true
        sessionTimer?.invalidate()
    }
    
    func resumeSession() {
        guard isInSession && isPaused else { return }
        isPaused = false
        startTimer()
    }
    
    func endSession() -> SessionResult {
        sessionTimer?.invalidate()
        isInSession = false
        
        let result = SessionResult(
            mode: currentMode,
            scratch: currentScratch,
            totalScore: currentScore,
            finalAccuracy: currentAccuracy,
            bestStreak: bestStreak,
            duration: sessionDuration - sessionTimeRemaining,
            timestamp: Date()
        )
        
        // Reset state
        currentScore = 0
        currentAccuracy = 0.0
        currentStreak = 0
        bestStreak = 0
        
        return result
    }
    
    // MARK: - Timer
    
    private func startTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isPaused else { return }
                
                if self.sessionTimeRemaining > 0 {
                    self.sessionTimeRemaining -= 1
                } else {
                    _ = self.endSession()
                }
            }
        }
    }
    
    // MARK: - Scoring
    
    func recordScratchAttempt(accuracy: Double) {
        // Calculate points based on accuracy
        let basePoints = 100
        let accuracyMultiplier = accuracy / 100.0
        let streakMultiplier = 1.0 + (Double(currentStreak) * 0.1)
        
        let points = Int(Double(basePoints) * accuracyMultiplier * streakMultiplier)
        currentScore += points
        
        // Update accuracy (running average)
        if currentAccuracy == 0 {
            currentAccuracy = accuracy
        } else {
            currentAccuracy = (currentAccuracy + accuracy) / 2
        }
        
        // Update streak
        if accuracy >= 70 {
            currentStreak += 1
            if currentStreak > bestStreak {
                bestStreak = currentStreak
            }
        } else {
            currentStreak = 0
        }
    }
}

// MARK: - Session Result
struct SessionResult: Codable, Identifiable {
    let id: UUID
    let mode: String
    let scratchID: String?
    let scratchName: String?
    let totalScore: Int
    let finalAccuracy: Double
    let bestStreak: Int
    let duration: TimeInterval
    let timestamp: Date
    
    init(mode: GameMode, scratch: Scratch?, totalScore: Int, finalAccuracy: Double, bestStreak: Int, duration: TimeInterval, timestamp: Date) {
        self.id = UUID()
        self.mode = mode.rawValue
        self.scratchID = scratch?.id
        self.scratchName = scratch?.name
        self.totalScore = totalScore
        self.finalAccuracy = finalAccuracy
        self.bestStreak = bestStreak
        self.duration = duration
        self.timestamp = timestamp
    }
}

// MARK: - Battle Session
struct BattleSession: Codable, Identifiable {
    let id: UUID
    let scratchID: String
    let roundDuration: TimeInterval // 90 seconds
    var player1ID: String
    var player2ID: String
    var player1Score: Int
    var player2Score: Int
    var player1Accuracy: Double
    var player2Accuracy: Double
    var player1VideoURL: URL?
    var player2VideoURL: URL?
    var currentRound: Int
    var totalRounds: Int
    var status: BattleStatus
    var createdAt: Date
    var updatedAt: Date
    
    enum BattleStatus: String, Codable {
        case waiting = "Waiting for opponent"
        case player1Turn = "Player 1's turn"
        case player2Turn = "Player 2's turn"
        case completed = "Completed"
        case cancelled = "Cancelled"
    }
    
    init(scratchID: String, player1ID: String) {
        self.id = UUID()
        self.scratchID = scratchID
        self.roundDuration = 90
        self.player1ID = player1ID
        self.player2ID = ""
        self.player1Score = 0
        self.player2Score = 0
        self.player1Accuracy = 0
        self.player2Accuracy = 0
        self.currentRound = 1
        self.totalRounds = 1
        self.status = .waiting
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - AI Character
enum AICharacter: String, CaseIterable, Codable {
    case rookie = "DJ Rookie"
    case flash = "Flash Gordon"
    case cipher = "MC Cipher"
    case nova = "DJ Nova"
    case legend = "Grand Master L"
    
    var level: Int {
        switch self {
        case .rookie: return 1
        case .flash: return 2
        case .cipher: return 3
        case .nova: return 4
        case .legend: return 5
        }
    }
    
    var description: String {
        switch self {
        case .rookie: return "Just starting out. Perfect for learning the basics."
        case .flash: return "Quick hands, building skills. A worthy practice partner."
        case .cipher: return "Seasoned battler with solid fader work."
        case .nova: return "Rising star with creative combinations."
        case .legend: return "The ultimate challenge. Decades of experience."
        }
    }
    
    var avatarImageName: String {
        return self.rawValue.lowercased().replacingOccurrences(of: " ", with: "_")
    }
    
    var primaryColor: String {
        switch self {
        case .rookie: return "4CAF50"
        case .flash: return "2196F3"
        case .cipher: return "FF9800"
        case .nova: return "E91E63"
        case .legend: return "9C27B0"
        }
    }
    
    var skillMultiplier: Double {
        switch self {
        case .rookie: return 0.6
        case .flash: return 0.75
        case .cipher: return 0.85
        case .nova: return 0.92
        case .legend: return 0.98
        }
    }
}

// MARK: - Player Profile
struct PlayerProfile: Codable, Identifiable {
    let id: String
    var displayName: String
    var avatarEmoji: String
    var city: String?
    var country: String?
    var totalScore: Int
    var level: Int
    var experience: Int
    var battlesWon: Int
    var battlesLost: Int
    var scratchesMastered: [String]
    var joinedDate: Date
    var lastActiveDate: Date
    
    init(id: String = UUID().uuidString, displayName: String) {
        self.id = id
        self.displayName = displayName
        self.avatarEmoji = "🎧"
        self.totalScore = 0
        self.level = 1
        self.experience = 0
        self.battlesWon = 0
        self.battlesLost = 0
        self.scratchesMastered = []
        self.joinedDate = Date()
        self.lastActiveDate = Date()
    }
    
    var winRate: Double {
        let total = battlesWon + battlesLost
        guard total > 0 else { return 0 }
        return Double(battlesWon) / Double(total) * 100
    }
}

// MARK: - Level Definition
struct Level: Identifiable, Codable {
    let id: Int
    let name: String
    let description: String
    let requiredAccuracy: Double // 90% to pass
    let scratchIDs: [String]
    let comboScratchID: String
    let aiCharacter: String
    let unlockRequirement: String
    
    var isComboUnlocked: Bool {
        // This would be computed based on player progress
        return false
    }
}

// MARK: - Level Definitions
extension Level {
    static let allLevels: [Level] = [
        Level(
            id: 1,
            name: "Foundation",
            description: "Master the basics of record movement",
            requiredAccuracy: 90,
            scratchIDs: ["baby_scratch", "forward_scratch", "backward_scratch", "release_scratch"],
            comboScratchID: "combo_l1",
            aiCharacter: AICharacter.rookie.rawValue,
            unlockRequirement: "Available from start"
        ),
        Level(
            id: 2,
            name: "Control",
            description: "Develop precision and introduce the fader",
            requiredAccuracy: 90,
            scratchIDs: ["tear", "chirp", "scribble", "stab"],
            comboScratchID: "combo_l2",
            aiCharacter: AICharacter.flash.rawValue,
            unlockRequirement: "Complete Level 1 combo with 90% accuracy"
        ),
        Level(
            id: 3,
            name: "Fader Mastery",
            description: "Advanced fader techniques and combinations",
            requiredAccuracy: 90,
            scratchIDs: ["transform", "crab", "flare_1click", "orbit"],
            comboScratchID: "combo_l3",
            aiCharacter: AICharacter.cipher.rawValue,
            unlockRequirement: "Complete Level 2 combo with 90% accuracy"
        ),
        Level(
            id: 4,
            name: "Advanced",
            description: "Complex scratches for serious DJs",
            requiredAccuracy: 90,
            scratchIDs: ["flare_2click", "twiddle", "boomerang", "hydroplane"],
            comboScratchID: "combo_l4",
            aiCharacter: AICharacter.nova.rawValue,
            unlockRequirement: "Complete Level 3 combo with 90% accuracy"
        ),
        Level(
            id: 5,
            name: "Master",
            description: "Competition-level techniques",
            requiredAccuracy: 90,
            scratchIDs: ["flare_3click", "autobahn", "military", "prizm"],
            comboScratchID: "combo_l5",
            aiCharacter: AICharacter.legend.rawValue,
            unlockRequirement: "Complete Level 4 combo with 90% accuracy"
        )
    ]
    
    static func level(_ id: Int) -> Level? {
        return allLevels.first { $0.id == id }
    }
}
