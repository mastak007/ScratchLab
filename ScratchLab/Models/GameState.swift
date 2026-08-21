// GameState.swift
// ScratchLab - Core Game State Management
// Manages overall game state, modes, and session data

import Foundation
import SwiftUI
import Combine

// MARK: - Game Mode
enum GameMode: String, CaseIterable {
    case practice = "Practice"
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
        self.scratchesMastered = []
        self.joinedDate = Date()
        self.lastActiveDate = Date()
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
            unlockRequirement: "Available from start"
        ),
        Level(
            id: 2,
            name: "Control",
            description: "Develop precision and introduce the fader",
            requiredAccuracy: 90,
            scratchIDs: ["tear", "chirp", "scribble", "stab"],
            comboScratchID: "combo_l2",
            unlockRequirement: "Complete Level 1 combo with 90% accuracy"
        ),
        Level(
            id: 3,
            name: "Fader Mastery",
            description: "Advanced fader techniques and combinations",
            requiredAccuracy: 90,
            scratchIDs: ["transform", "crab", "flare_1click", "orbit"],
            comboScratchID: "combo_l3",
            unlockRequirement: "Complete Level 2 combo with 90% accuracy"
        ),
        Level(
            id: 4,
            name: "Advanced",
            description: "Complex scratches for serious DJs",
            requiredAccuracy: 90,
            scratchIDs: ["flare_2click", "twiddle", "boomerang", "hydroplane"],
            comboScratchID: "combo_l4",
            unlockRequirement: "Complete Level 3 combo with 90% accuracy"
        ),
        Level(
            id: 5,
            name: "Master",
            description: "Competition-level techniques",
            requiredAccuracy: 90,
            scratchIDs: ["flare_3click", "autobahn", "military", "prizm"],
            comboScratchID: "combo_l5",
            unlockRequirement: "Complete Level 4 combo with 90% accuracy"
        )
    ]
    
    static func level(_ id: Int) -> Level? {
        return allLevels.first { $0.id == id }
    }
}
