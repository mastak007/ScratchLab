// Scratch.swift
// ScratchLab - Scratch Pattern Definitions
// Defines all 20 scratches across 5 levels with their characteristics

import Foundation

// MARK: - Scratch Model
struct Scratch: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let level: Int
    let description: String
    let difficulty: ScratchDifficulty
    let technique: ScratchTechnique
    let faderRequired: Bool
    let patternSignature: PatternSignature
    let referenceAudioName: String?
    let backingTrackName: String
    let tips: [String]
    
    // User progress (not stored in model, but referenced)
    var isUnlocked: Bool = false
    var bestAccuracy: Double = 0.0
    var practiceCount: Int = 0
    var isMastered: Bool = false

    private static let formulaReferenceDurationSeconds = 0.5

    var formulaDefaultBeats: Double {
        let normalizedBeats = patternSignature.expectedDuration / Self.formulaReferenceDurationSeconds
        let roundedBeats = (normalizedBeats * 10).rounded() / 10
        return max(0.2, roundedBeats)
    }
}

// MARK: - Scratch Difficulty
enum ScratchDifficulty: String, Codable, CaseIterable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"
    case expert = "Expert"
    case master = "Master"
    
    var color: String {
        switch self {
        case .beginner: return "4CAF50"      // Green
        case .intermediate: return "2196F3"  // Blue
        case .advanced: return "FF9800"      // Orange
        case .expert: return "F44336"        // Red
        case .master: return "9C27B0"        // Purple
        }
    }
}

// MARK: - Scratch Technique Type
enum ScratchTechnique: String, Codable {
    case recordOnly = "Record Only"
    case faderBasic = "Fader Basic"
    case faderAdvanced = "Fader Advanced"
    case combination = "Combination"
}

// MARK: - Pattern Signature (for audio matching)
struct PatternSignature: Codable, Equatable {
    let waveformPattern: [Float]        // Normalized amplitude pattern
    let expectedDuration: Double        // Typical duration in seconds
    let peakCount: Int                  // Number of sound peaks
    let crossfaderClicks: Int           // Number of fader movements
    let rhythmPattern: [Double]         // Timing ratios between peaks
    let frequencyProfile: FrequencyProfile
    
    struct FrequencyProfile: Codable, Equatable {
        let dominantFrequencyRange: ClosedRange<Float>
        let hasSharpAttack: Bool
        let hasReverseSound: Bool
    }
}

// MARK: - Combo Scratch (combines multiple scratches)
struct ComboScratch: Identifiable, Codable {
    let id: String
    let name: String
    let level: Int
    let componentScratchIDs: [String]
    let description: String
    let bonusPoints: Int
}

// MARK: - Scratch Library
class ScratchLibrary {
    static let shared = ScratchLibrary()
    
    // All 20 scratches organized by level
    let allScratches: [Scratch]
    let comboScratches: [ComboScratch]
    
    private init() {
        // LEVEL 1 - Foundation (No Fader)
        let level1: [Scratch] = [
            Scratch(
                id: "baby_scratch",
                name: "Baby Scratch",
                level: 1,
                description: "The foundation of all scratches. Push the record forward and pull it back without using the fader.",
                difficulty: .beginner,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.8, 0.0, -0.8, 0.0],
                    expectedDuration: 0.5,
                    peakCount: 2,
                    crossfaderClicks: 0,
                    rhythmPattern: [1.0, 1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 200...2000, hasSharpAttack: false, hasReverseSound: true)
                ),
                referenceAudioName: "baby_scratch_ref",
                backingTrackName: "boom_bap_100bpm",
                tips: [
                    "Keep your wrist loose",
                    "Use your fingers, not your whole arm",
                    "Start slow and focus on consistent movement",
                    "The forward and back should sound equal"
                ]
            ),
            Scratch(
                id: "forward_scratch",
                name: "Forward Scratch",
                level: 1,
                description: "Push the record forward to create sound, then silently return it to the starting position.",
                difficulty: .beginner,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.9, 0.3, 0.0],
                    expectedDuration: 0.4,
                    peakCount: 1,
                    crossfaderClicks: 0,
                    rhythmPattern: [1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 200...2000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "forward_scratch_ref",
                backingTrackName: "boom_bap_100bpm",
                tips: [
                    "Quick push forward",
                    "Slow, silent return",
                    "Lift pressure slightly on the return"
                ]
            ),
            Scratch(
                id: "backward_scratch",
                name: "Backward Scratch",
                level: 1,
                description: "Pull the record backward to create sound, then silently return it forward.",
                difficulty: .beginner,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, -0.9, -0.3, 0.0],
                    expectedDuration: 0.4,
                    peakCount: 1,
                    crossfaderClicks: 0,
                    rhythmPattern: [1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 200...2000, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "backward_scratch_ref",
                backingTrackName: "boom_bap_100bpm",
                tips: [
                    "Quick pull backward",
                    "Control the release",
                    "The reverse sound is distinctive"
                ]
            ),
            Scratch(
                id: "release_scratch",
                name: "Release Scratch",
                level: 1,
                description: "Pull the record back, then release it to spin forward naturally using the platter motor.",
                difficulty: .beginner,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, -0.7, 0.0, 0.5, 0.7, 0.5, 0.3],
                    expectedDuration: 0.8,
                    peakCount: 2,
                    crossfaderClicks: 0,
                    rhythmPattern: [0.3, 0.7],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: false, hasReverseSound: true)
                ),
                referenceAudioName: "release_scratch_ref",
                backingTrackName: "boom_bap_100bpm",
                tips: [
                    "Let the motor do the work on the release",
                    "Time your release with the beat",
                    "Great for adding groove to your scratching"
                ]
            )
        ]
        
        // LEVEL 2 - Control
        let level2: [Scratch] = [
            Scratch(
                id: "tear",
                name: "Tear",
                level: 2,
                description: "A two-part scratch where you pause in the middle of the movement, creating two distinct sounds from one direction.",
                difficulty: .intermediate,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.6, 0.1, 0.6, 0.0],
                    expectedDuration: 0.5,
                    peakCount: 2,
                    crossfaderClicks: 0,
                    rhythmPattern: [0.5, 0.5],
                    frequencyProfile: .init(dominantFrequencyRange: 200...2500, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "tear_ref",
                backingTrackName: "boom_bap_95bpm",
                tips: [
                    "The pause creates the 'tear' effect",
                    "Keep the pause brief but distinct",
                    "Practice getting consistent timing"
                ]
            ),
            Scratch(
                id: "chirp",
                name: "Chirp",
                level: 2,
                description: "Close the fader as the record moves, creating a short, sharp sound like a bird chirp.",
                difficulty: .intermediate,
                technique: .faderBasic,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.9, 0.0],
                    expectedDuration: 0.15,
                    peakCount: 1,
                    crossfaderClicks: 1,
                    rhythmPattern: [1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 500...3000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "chirp_ref",
                backingTrackName: "boom_bap_95bpm",
                tips: [
                    "Fader closes AT the end of the record movement",
                    "Quick, snappy fader action",
                    "The chirp should be tight and punchy"
                ]
            ),
            Scratch(
                id: "scribble",
                name: "Scribble",
                level: 2,
                description: "Rapid back-and-forth movement using your fingers to 'vibrate' the record.",
                difficulty: .intermediate,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.4, -0.4, 0.4, -0.4, 0.4, -0.4, 0.0],
                    expectedDuration: 0.4,
                    peakCount: 6,
                    crossfaderClicks: 0,
                    rhythmPattern: [0.16, 0.16, 0.16, 0.16, 0.16, 0.16],
                    frequencyProfile: .init(dominantFrequencyRange: 300...4000, hasSharpAttack: false, hasReverseSound: true)
                ),
                referenceAudioName: "scribble_ref",
                backingTrackName: "boom_bap_95bpm",
                tips: [
                    "Use your fingers, not your wrist",
                    "Keep movements small and fast",
                    "Tension in your forearm helps control speed"
                ]
            ),
            Scratch(
                id: "stab",
                name: "Stab",
                level: 2,
                description: "A quick, aggressive forward push with immediate fader cut, creating a punchy stab sound.",
                difficulty: .intermediate,
                technique: .faderBasic,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 1.0, 0.0],
                    expectedDuration: 0.1,
                    peakCount: 1,
                    crossfaderClicks: 1,
                    rhythmPattern: [1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 200...2000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "stab_ref",
                backingTrackName: "boom_bap_95bpm",
                tips: [
                    "Fast, aggressive movement",
                    "Cut the fader immediately after the sound",
                    "Great for accents and emphasis"
                ]
            )
        ]
        
        // LEVEL 3 - Fader Introduction
        let level3: [Scratch] = [
            Scratch(
                id: "transform",
                name: "Transform",
                level: 3,
                description: "While the record moves continuously, rapidly tap the fader to create rhythmic cuts in the sound.",
                difficulty: .advanced,
                technique: .faderBasic,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.7, 0.0, 0.7, 0.0, 0.7, 0.0],
                    expectedDuration: 0.6,
                    peakCount: 3,
                    crossfaderClicks: 3,
                    rhythmPattern: [0.33, 0.33, 0.33],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "transform_ref",
                backingTrackName: "electro_100bpm",
                tips: [
                    "Record moves in ONE direction while fader taps",
                    "Keep fader taps even and rhythmic",
                    "Named after the Transformers cartoon sound"
                ]
            ),
            Scratch(
                id: "crab",
                name: "Crab",
                level: 3,
                description: "Use multiple fingers to rapidly tap the fader open in sequence, creating machine-gun-like cuts.",
                difficulty: .advanced,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.8, 0.0, 0.8, 0.0, 0.8, 0.0, 0.8, 0.0],
                    expectedDuration: 0.3,
                    peakCount: 4,
                    crossfaderClicks: 4,
                    rhythmPattern: [0.25, 0.25, 0.25, 0.25],
                    frequencyProfile: .init(dominantFrequencyRange: 300...3500, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "crab_ref",
                backingTrackName: "electro_100bpm",
                tips: [
                    "Use 3-4 fingers in sequence",
                    "Let the fader spring bounce your fingers",
                    "Practice the finger roll separately first"
                ]
            ),
            Scratch(
                id: "flare_1click",
                name: "1-Click Flare",
                level: 3,
                description: "Start with fader open, click it closed and open during the record movement to create 2 sounds.",
                difficulty: .advanced,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.5, 0.0, 0.5],
                    expectedDuration: 0.3,
                    peakCount: 2,
                    crossfaderClicks: 1,
                    rhythmPattern: [0.5, 0.5],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "flare_1click_ref",
                backingTrackName: "electro_100bpm",
                tips: [
                    "Fader STARTS open (opposite of transform)",
                    "One click in the middle splits the sound",
                    "Foundation for all flare variations"
                ]
            ),
            Scratch(
                id: "orbit",
                name: "Orbit",
                level: 3,
                description: "A flare performed in both directions - forward flare, then backward flare, creating a circular pattern.",
                difficulty: .advanced,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.5, 0.0, 0.5, -0.5, 0.0, -0.5],
                    expectedDuration: 0.6,
                    peakCount: 4,
                    crossfaderClicks: 2,
                    rhythmPattern: [0.25, 0.25, 0.25, 0.25],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "orbit_ref",
                backingTrackName: "electro_100bpm",
                tips: [
                    "Think of it as two flares connected",
                    "Forward flare → backward flare → repeat",
                    "Smooth transition between directions"
                ]
            )
        ]
        
        // LEVEL 4 - Advanced
        let level4: [Scratch] = [
            Scratch(
                id: "flare_2click",
                name: "2-Click Flare",
                level: 4,
                description: "Two fader clicks during one record movement, creating 3 distinct sounds.",
                difficulty: .expert,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.4, 0.0, 0.4, 0.0, 0.4],
                    expectedDuration: 0.35,
                    peakCount: 3,
                    crossfaderClicks: 2,
                    rhythmPattern: [0.33, 0.33, 0.33],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3500, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "flare_2click_ref",
                backingTrackName: "trap_110bpm",
                tips: [
                    "Even spacing between the 3 sounds",
                    "Fader speed must increase from 1-click",
                    "Keep record movement smooth and consistent"
                ]
            ),
            Scratch(
                id: "twiddle",
                name: "Twiddle",
                level: 4,
                description: "Alternate between thumb and fingers on the fader while scratching, creating rapid cuts.",
                difficulty: .expert,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.6, 0.0, 0.6, 0.0, 0.6, 0.0, 0.6, 0.0],
                    expectedDuration: 0.4,
                    peakCount: 4,
                    crossfaderClicks: 4,
                    rhythmPattern: [0.25, 0.25, 0.25, 0.25],
                    frequencyProfile: .init(dominantFrequencyRange: 300...3500, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "twiddle_ref",
                backingTrackName: "trap_110bpm",
                tips: [
                    "Thumb pushes one way, fingers pull back",
                    "Like a very fast transform",
                    "Keep your hand relaxed"
                ]
            ),
            Scratch(
                id: "boomerang",
                name: "Boomerang",
                level: 4,
                description: "A scratch that sounds the same forward and backward, creating a symmetrical pattern.",
                difficulty: .expert,
                technique: .combination,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.5, 0.8, 0.5, 0.0, -0.5, -0.8, -0.5, 0.0],
                    expectedDuration: 0.7,
                    peakCount: 4,
                    crossfaderClicks: 2,
                    rhythmPattern: [0.25, 0.25, 0.25, 0.25],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "boomerang_ref",
                backingTrackName: "trap_110bpm",
                tips: [
                    "Pattern is symmetrical",
                    "What you do going forward, mirror going back",
                    "Great for building complex patterns"
                ]
            ),
            Scratch(
                id: "hydroplane",
                name: "Hydroplane",
                level: 4,
                description: "Using very light pressure to let the record 'float' while scratching, creating a smooth gliding effect.",
                difficulty: .expert,
                technique: .recordOnly,
                faderRequired: false,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.3, 0.5, 0.7, 0.5, 0.3, 0.0],
                    expectedDuration: 0.8,
                    peakCount: 1,
                    crossfaderClicks: 0,
                    rhythmPattern: [1.0],
                    frequencyProfile: .init(dominantFrequencyRange: 100...2000, hasSharpAttack: false, hasReverseSound: false)
                ),
                referenceAudioName: "hydroplane_ref",
                backingTrackName: "trap_110bpm",
                tips: [
                    "Minimal pressure on the record",
                    "Let it glide rather than grip",
                    "Creates a unique floaty texture"
                ]
            )
        ]
        
        // LEVEL 5 - Expert/Master
        let level5: [Scratch] = [
            Scratch(
                id: "flare_3click",
                name: "3-Click Flare",
                level: 5,
                description: "Three fader clicks during one record movement, creating 4 distinct sounds. The ultimate flare.",
                difficulty: .master,
                technique: .faderAdvanced,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.4, 0.0, 0.4, 0.0, 0.4, 0.0, 0.4],
                    expectedDuration: 0.4,
                    peakCount: 4,
                    crossfaderClicks: 3,
                    rhythmPattern: [0.25, 0.25, 0.25, 0.25],
                    frequencyProfile: .init(dominantFrequencyRange: 200...4000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "flare_3click_ref",
                backingTrackName: "dnb_120bpm",
                tips: [
                    "Lightning fast fader work",
                    "Record movement must be perfectly smooth",
                    "The holy grail of fader scratches"
                ]
            ),
            Scratch(
                id: "autobahn",
                name: "Autobahn",
                level: 5,
                description: "High-speed continuous scratching with complex fader patterns, like driving on the German highway.",
                difficulty: .master,
                technique: .combination,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.7, 0.0, 0.7, 0.7, 0.0, 0.7, 0.0, -0.7, 0.0, -0.7, 0.0],
                    expectedDuration: 0.8,
                    peakCount: 8,
                    crossfaderClicks: 6,
                    rhythmPattern: [0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125],
                    frequencyProfile: .init(dominantFrequencyRange: 200...4000, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "autobahn_ref",
                backingTrackName: "dnb_120bpm",
                tips: [
                    "Speed is key but control is essential",
                    "Complex combination of techniques",
                    "Requires mastery of all previous levels"
                ]
            ),
            Scratch(
                id: "military",
                name: "Military",
                level: 5,
                description: "Precision scratching with exact timing, like military drills. Every sound must be perfectly placed.",
                difficulty: .master,
                technique: .combination,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.9, 0.0, 0.0, 0.9, 0.0, 0.0, 0.9, 0.0],
                    expectedDuration: 0.6,
                    peakCount: 3,
                    crossfaderClicks: 3,
                    rhythmPattern: [0.33, 0.33, 0.33],
                    frequencyProfile: .init(dominantFrequencyRange: 200...3000, hasSharpAttack: true, hasReverseSound: false)
                ),
                referenceAudioName: "military_ref",
                backingTrackName: "dnb_120bpm",
                tips: [
                    "Timing is EVERYTHING",
                    "Like a drummer - every hit must be exact",
                    "Practice with a metronome"
                ]
            ),
            Scratch(
                id: "prizm",
                name: "Prizm",
                level: 5,
                description: "A showcase scratch that combines multiple techniques into one flowing pattern, like light through a prism.",
                difficulty: .master,
                technique: .combination,
                faderRequired: true,
                patternSignature: PatternSignature(
                    waveformPattern: [0.0, 0.5, 0.0, 0.8, 0.4, 0.0, -0.4, -0.8, 0.0, -0.5, 0.0],
                    expectedDuration: 1.0,
                    peakCount: 6,
                    crossfaderClicks: 4,
                    rhythmPattern: [0.15, 0.15, 0.2, 0.2, 0.15, 0.15],
                    frequencyProfile: .init(dominantFrequencyRange: 200...4000, hasSharpAttack: true, hasReverseSound: true)
                ),
                referenceAudioName: "prizm_ref",
                backingTrackName: "dnb_120bpm",
                tips: [
                    "Combines everything you've learned",
                    "Expression and creativity matter here",
                    "Make it your own - add your style"
                ]
            )
        ]
        
        // Combine all scratches
        self.allScratches = level1 + level2 + level3 + level4 + level5
        
        // Define combo scratches for each level
        self.comboScratches = [
            ComboScratch(
                id: "combo_l1",
                name: "Foundation Flow",
                level: 1,
                componentScratchIDs: ["baby_scratch", "forward_scratch", "backward_scratch", "release_scratch"],
                description: "Combine all 4 foundation scratches into a smooth pattern",
                bonusPoints: 500
            ),
            ComboScratch(
                id: "combo_l2",
                name: "Control Combo",
                level: 2,
                componentScratchIDs: ["tear", "chirp", "scribble", "stab"],
                description: "Chain the control scratches with perfect timing",
                bonusPoints: 1000
            ),
            ComboScratch(
                id: "combo_l3",
                name: "Fader Fury",
                level: 3,
                componentScratchIDs: ["transform", "crab", "flare_1click", "orbit"],
                description: "Showcase your fader skills in one sequence",
                bonusPoints: 1500
            ),
            ComboScratch(
                id: "combo_l4",
                name: "Advanced Arsenal",
                level: 4,
                componentScratchIDs: ["flare_2click", "twiddle", "boomerang", "hydroplane"],
                description: "Expert-level scratch combination",
                bonusPoints: 2000
            ),
            ComboScratch(
                id: "combo_l5",
                name: "Master Showcase",
                level: 5,
                componentScratchIDs: ["flare_3click", "autobahn", "military", "prizm"],
                description: "The ultimate test - all master scratches combined",
                bonusPoints: 3000
            )
        ]
    }
    
    // MARK: - Helper Methods
    
    func scratchesForLevel(_ level: Int) -> [Scratch] {
        return allScratches.filter { $0.level == level }
    }
    
    func scratch(byID id: String) -> Scratch? {
        return allScratches.first { $0.id == id }
    }
    
    func comboForLevel(_ level: Int) -> ComboScratch? {
        return comboScratches.first { $0.level == level }
    }
    
    func nextScratchToUnlock(after scratchID: String) -> Scratch? {
        guard let currentIndex = allScratches.firstIndex(where: { $0.id == scratchID }) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        if nextIndex < allScratches.count {
            return allScratches[nextIndex]
        }
        return nil
    }
}
