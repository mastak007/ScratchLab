// ProgressManager.swift
// ScratchLab - User Progress Management
// Handles saving/loading progress, achievements, and stats

import Foundation
import SwiftUI
import GameKit

// MARK: - Progress Manager
@MainActor
class ProgressManager: ObservableObject {
    // Player profile
    @Published var playerProfile: PlayerProfile?
    
    // Scratch progress
    @Published var scratchProgress: [String: ScratchProgress] = [:]
    
    // Level progress
    @Published var levelProgress: [Int: LevelProgress] = [:]
    
    // Stats
    @Published var totalPracticeTime: TimeInterval = 0
    @Published var totalScratchAttempts: Int = 0
    @Published var currentStreak: Int = 0 // Days practiced in a row
    @Published var lastPracticeDate: Date?
    
    // Session history
    @Published var sessionHistory: [SessionResult] = []
    
    // Game Center
    @Published var isGameCenterEnabled: Bool = false
    @Published var gameCenterPlayerID: String?
    
    // UserDefaults keys
    private let profileKey = "playerProfile"
    private let scratchProgressKey = "scratchProgress"
    private let levelProgressKey = "levelProgress"
    private let statsKey = "playerStats"
    private let historyKey = "sessionHistory"
    
    init() {
        loadProgress()
        setupGameCenter()
    }
    
    // MARK: - Profile Management
    
    func createProfile(displayName: String) {
        playerProfile = PlayerProfile(displayName: displayName)
        initializeProgress()
        saveProgress()
    }
    
    func updateProfile(displayName: String? = nil, avatarEmoji: String? = nil, city: String? = nil) {
        if let name = displayName {
            playerProfile?.displayName = name
        }
        if let emoji = avatarEmoji {
            playerProfile?.avatarEmoji = emoji
        }
        if let city = city {
            playerProfile?.city = city
        }
        saveProgress()
    }
    
    // MARK: - Progress Initialization
    
    private func initializeProgress() {
        // Initialize scratch progress for all scratches
        for scratch in ScratchLibrary.shared.allScratches {
            if scratchProgress[scratch.id] == nil {
                scratchProgress[scratch.id] = ScratchProgress(
                    scratchID: scratch.id,
                    isUnlocked: scratch.level == 1, // Level 1 scratches start unlocked
                    bestAccuracy: 0,
                    practiceCount: 0,
                    isMastered: false,
                    totalPracticeTime: 0
                )
            }
        }
        
        // Initialize level progress
        for level in Level.allLevels {
            if levelProgress[level.id] == nil {
                levelProgress[level.id] = LevelProgress(
                    levelID: level.id,
                    isUnlocked: level.id == 1, // Level 1 starts unlocked
                    scratchesMastered: 0,
                    comboCompleted: false,
                    comboAccuracy: 0,
                    totalStars: 0
                )
            }
        }
    }
    
    // MARK: - Progress Updates
    
    func recordScratchAttempt(scratchID: String, accuracy: Double, duration: TimeInterval) {
        guard var progress = scratchProgress[scratchID] else { return }
        
        // Update practice count
        progress.practiceCount += 1
        totalScratchAttempts += 1
        
        // Update best accuracy
        if accuracy > progress.bestAccuracy {
            progress.bestAccuracy = accuracy
        }
        
        // Check for mastery (90% or higher)
        if accuracy >= 90 && !progress.isMastered {
            progress.isMastered = true
            progress.masteredDate = Date()
            playerProfile?.scratchesMastered.append(scratchID)
            
            // Check if this unlocks the combo or next scratches
            checkAndUnlockContent(afterMastering: scratchID)
        }
        
        // Update practice time
        progress.totalPracticeTime += duration
        totalPracticeTime += duration
        
        // Update last practice date and streak
        updatePracticeStreak()
        
        // Add experience
        let expGained = Int(accuracy / 10) * 10
        playerProfile?.experience += expGained
        checkLevelUp()
        
        // Save
        scratchProgress[scratchID] = progress
        saveProgress()
    }
    
    func recordComboAttempt(levelID: Int, accuracy: Double) {
        guard var progress = levelProgress[levelID] else { return }
        
        if accuracy > progress.comboAccuracy {
            progress.comboAccuracy = accuracy
        }
        
        if accuracy >= 90 && !progress.comboCompleted {
            progress.comboCompleted = true
            
            // Unlock next level
            let nextLevelID = levelID + 1
            if var nextLevel = levelProgress[nextLevelID] {
                nextLevel.isUnlocked = true
                levelProgress[nextLevelID] = nextLevel
                
                // Unlock all scratches in next level
                if let level = Level.level(nextLevelID) {
                    for scratchID in level.scratchIDs {
                        if var scratchProg = scratchProgress[scratchID] {
                            scratchProg.isUnlocked = true
                            scratchProgress[scratchID] = scratchProg
                        }
                    }
                }
            }
        }
        
        levelProgress[levelID] = progress
        saveProgress()
    }
    
    func recordSessionResult(_ result: SessionResult) {
        sessionHistory.append(result)
        
        // Keep only last 100 sessions
        if sessionHistory.count > 100 {
            sessionHistory.removeFirst()
        }
        
        // Update total score
        playerProfile?.totalScore += result.totalScore
        
        saveProgress()
        
        // Report to Game Center
        if isGameCenterEnabled {
            reportScoreToGameCenter(result.totalScore)
        }
    }
    
    func recordBattleResult(won: Bool, opponentID: String?) {
        if won {
            playerProfile?.battlesWon += 1
        } else {
            playerProfile?.battlesLost += 1
        }
        saveProgress()
    }
    
    // MARK: - Unlock Logic
    
    private func checkAndUnlockContent(afterMastering scratchID: String) {
        guard let scratch = ScratchLibrary.shared.scratch(byID: scratchID) else { return }
        
        let levelID = scratch.level
        guard var levelProg = levelProgress[levelID] else { return }
        
        // Count mastered scratches in this level
        let levelScratchIDs = ScratchLibrary.shared.scratchesForLevel(levelID).map { $0.id }
        let masteredCount = levelScratchIDs.filter { scratchProgress[$0]?.isMastered == true }.count
        
        levelProg.scratchesMastered = masteredCount
        
        // Calculate stars (1-3 based on average accuracy)
        let avgAccuracy = levelScratchIDs.compactMap { scratchProgress[$0]?.bestAccuracy }.reduce(0, +) / Double(levelScratchIDs.count)
        if avgAccuracy >= 95 {
            levelProg.totalStars = 3
        } else if avgAccuracy >= 90 {
            levelProg.totalStars = 2
        } else if avgAccuracy >= 80 {
            levelProg.totalStars = 1
        }
        
        levelProgress[levelID] = levelProg
    }
    
    private func updatePracticeStreak() {
        let today = Calendar.current.startOfDay(for: Date())
        
        if let lastDate = lastPracticeDate {
            let lastDay = Calendar.current.startOfDay(for: lastDate)
            let daysBetween = Calendar.current.dateComponents([.day], from: lastDay, to: today).day ?? 0
            
            if daysBetween == 0 {
                // Same day, streak continues
            } else if daysBetween == 1 {
                // Next day, increment streak
                currentStreak += 1
            } else {
                // Missed days, reset streak
                currentStreak = 1
            }
        } else {
            currentStreak = 1
        }
        
        lastPracticeDate = Date()
    }
    
    private func checkLevelUp() {
        guard let profile = playerProfile else { return }
        
        // Simple level formula: level up every 1000 exp
        let newLevel = (profile.experience / 1000) + 1
        if newLevel > profile.level {
            playerProfile?.level = newLevel
            // Could trigger level up notification here
        }
    }
    
    // MARK: - Data Helpers
    
    func isScratchUnlocked(_ scratchID: String) -> Bool {
        return scratchProgress[scratchID]?.isUnlocked ?? false
    }
    
    func isScratchMastered(_ scratchID: String) -> Bool {
        return scratchProgress[scratchID]?.isMastered ?? false
    }
    
    func isLevelUnlocked(_ levelID: Int) -> Bool {
        return levelProgress[levelID]?.isUnlocked ?? false
    }
    
    func isComboAvailable(_ levelID: Int) -> Bool {
        guard let level = Level.level(levelID) else { return false }
        
        // All scratches in level must be mastered
        return level.scratchIDs.allSatisfy { isScratchMastered($0) }
    }
    
    func getProgressForScratch(_ scratchID: String) -> ScratchProgress? {
        return scratchProgress[scratchID]
    }
    
    func getProgressForLevel(_ levelID: Int) -> LevelProgress? {
        return levelProgress[levelID]
    }
    
    // MARK: - Persistence
    
    private func saveProgress() {
        let encoder = JSONEncoder()
        
        // Save profile
        if let profile = playerProfile, let data = try? encoder.encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
        
        // Save scratch progress
        if let data = try? encoder.encode(scratchProgress) {
            UserDefaults.standard.set(data, forKey: scratchProgressKey)
        }
        
        // Save level progress
        if let data = try? encoder.encode(levelProgress) {
            UserDefaults.standard.set(data, forKey: levelProgressKey)
        }
        
        // Save stats
        let stats: [String: Any] = [
            "totalPracticeTime": totalPracticeTime,
            "totalScratchAttempts": totalScratchAttempts,
            "currentStreak": currentStreak,
            "lastPracticeDate": lastPracticeDate?.timeIntervalSince1970 ?? 0
        ]
        UserDefaults.standard.set(stats, forKey: statsKey)
        
        // Save history
        if let data = try? encoder.encode(sessionHistory) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
    
    private func loadProgress() {
        let decoder = JSONDecoder()
        
        // Load profile
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? decoder.decode(PlayerProfile.self, from: data) {
            playerProfile = profile
        }
        
        // Load scratch progress
        if let data = UserDefaults.standard.data(forKey: scratchProgressKey),
           let progress = try? decoder.decode([String: ScratchProgress].self, from: data) {
            scratchProgress = progress
        }
        
        // Load level progress
        if let data = UserDefaults.standard.data(forKey: levelProgressKey),
           let progress = try? decoder.decode([Int: LevelProgress].self, from: data) {
            levelProgress = progress
        }
        
        // Load stats
        if let stats = UserDefaults.standard.dictionary(forKey: statsKey) {
            totalPracticeTime = stats["totalPracticeTime"] as? TimeInterval ?? 0
            totalScratchAttempts = stats["totalScratchAttempts"] as? Int ?? 0
            currentStreak = stats["currentStreak"] as? Int ?? 0
            if let timestamp = stats["lastPracticeDate"] as? TimeInterval, timestamp > 0 {
                lastPracticeDate = Date(timeIntervalSince1970: timestamp)
            }
        }
        
        // Load history
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let history = try? decoder.decode([SessionResult].self, from: data) {
            sessionHistory = history
        }
        
        // Initialize progress if needed
        initializeProgress()
    }
    
    func resetAllProgress() {
        playerProfile = nil
        scratchProgress.removeAll()
        levelProgress.removeAll()
        sessionHistory.removeAll()
        totalPracticeTime = 0
        totalScratchAttempts = 0
        currentStreak = 0
        lastPracticeDate = nil
        
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: scratchProgressKey)
        UserDefaults.standard.removeObject(forKey: levelProgressKey)
        UserDefaults.standard.removeObject(forKey: statsKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
    
    // MARK: - Game Center
    
    private func setupGameCenter() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                if let error = error {
                    print("Game Center auth error: \(error)")
                    self?.isGameCenterEnabled = false
                    return
                }
                
                if GKLocalPlayer.local.isAuthenticated {
                    self?.isGameCenterEnabled = true
                    self?.gameCenterPlayerID = GKLocalPlayer.local.gamePlayerID
                }
            }
        }
    }
    
    private func reportScoreToGameCenter(_ score: Int) {
        guard isGameCenterEnabled else { return }
        
        GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: ["scratchlab_highscores"]) { error in
            if let error = error {
                print("Error submitting score: \(error)")
            }
        }
    }
    
    func showGameCenterLeaderboard(from viewController: UIViewController) {
        guard isGameCenterEnabled else { return }
        
        let gcViewController = GKGameCenterViewController(leaderboardID: "scratchlab_highscores", playerScope: .global, timeScope: .allTime)
        gcViewController.gameCenterDelegate = viewController as? GKGameCenterControllerDelegate
        viewController.present(gcViewController, animated: true)
    }
}

// MARK: - Scratch Progress Model
struct ScratchProgress: Codable {
    var scratchID: String
    var isUnlocked: Bool
    var bestAccuracy: Double
    var practiceCount: Int
    var isMastered: Bool
    var masteredDate: Date?
    var totalPracticeTime: TimeInterval
    
    // History of attempts (last 20)
    var recentAccuracies: [Double] = []
    
    mutating func addAttempt(accuracy: Double) {
        recentAccuracies.append(accuracy)
        if recentAccuracies.count > 20 {
            recentAccuracies.removeFirst()
        }
    }
    
    var averageAccuracy: Double {
        guard !recentAccuracies.isEmpty else { return 0 }
        return recentAccuracies.reduce(0, +) / Double(recentAccuracies.count)
    }
    
    var progressToMastery: Double {
        return min(100, bestAccuracy / 90 * 100)
    }
}

// MARK: - Level Progress Model
struct LevelProgress: Codable {
    var levelID: Int
    var isUnlocked: Bool
    var scratchesMastered: Int
    var comboCompleted: Bool
    var comboAccuracy: Double
    var totalStars: Int // 0-3 stars based on performance
    
    var isComplete: Bool {
        return scratchesMastered >= 4 && comboCompleted
    }
}
