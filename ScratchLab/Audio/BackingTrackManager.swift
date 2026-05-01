// BackingTrackManager.swift
// ScratchLab - Backing Track Management
// Manages beat/backing tracks for practice sessions

import Foundation
import AVFoundation

// MARK: - Backing Track
struct BackingTrack: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let displayName: String
    let fileName: String
    let bpm: Int
    let genre: TrackGenre
    let duration: TimeInterval
    let difficulty: Int // 1-5, affects how forgiving the timing is
    
    enum TrackGenre: String, Codable, CaseIterable {
        case boomBap = "Boom Bap"
        case trap = "Trap"
        case electro = "Electro"
        case dnb = "Drum & Bass"
        case house = "House"
        case breakbeat = "Breakbeat"
        
        var icon: String {
            switch self {
            case .boomBap: return "🎤"
            case .trap: return "🔥"
            case .electro: return "⚡️"
            case .dnb: return "🥁"
            case .house: return "🎵"
            case .breakbeat: return "💥"
            }
        }
        
        var color: String {
            switch self {
            case .boomBap: return "FFD700"
            case .trap: return "F44336"
            case .electro: return "2196F3"
            case .dnb: return "9C27B0"
            case .house: return "4CAF50"
            case .breakbeat: return "FF9800"
            }
        }
    }
}

// MARK: - Backing Track Manager
class BackingTrackManager: ObservableObject {
    static let shared = BackingTrackManager()

    static let bundledDefaultTracksCatalog: [BackingTrack] = [
        BackingTrack(
            id: "boom_bap_100bpm",
            name: "boom_bap_100bpm",
            displayName: "Golden Era",
            fileName: "boom_bap_100bpm.wav",
            bpm: 100,
            genre: .boomBap,
            duration: 180,
            difficulty: 1
        ),
        BackingTrack(
            id: "boom_bap_95bpm",
            name: "boom_bap_95bpm",
            displayName: "Street Knowledge",
            fileName: "boom_bap_95bpm.mp3",
            bpm: 95,
            genre: .boomBap,
            duration: 180,
            difficulty: 2
        ),
        BackingTrack(
            id: "electro_100bpm",
            name: "electro_100bpm",
            displayName: "Electric Dreams",
            fileName: "electro_100bpm.mp3",
            bpm: 100,
            genre: .electro,
            duration: 180,
            difficulty: 3
        ),
        BackingTrack(
            id: "electro_105bpm",
            name: "electro_105bpm",
            displayName: "Robot Funk",
            fileName: "electro_105bpm.mp3",
            bpm: 105,
            genre: .electro,
            duration: 180,
            difficulty: 3
        ),
        BackingTrack(
            id: "trap_110bpm",
            name: "trap_110bpm",
            displayName: "808 Mafia",
            fileName: "trap_110bpm.mp3",
            bpm: 110,
            genre: .trap,
            duration: 180,
            difficulty: 4
        ),
        BackingTrack(
            id: "trap_140bpm",
            name: "trap_140bpm",
            displayName: "ATL Heat",
            fileName: "trap_140bpm.mp3",
            bpm: 140,
            genre: .trap,
            duration: 180,
            difficulty: 5
        ),
        BackingTrack(
            id: "dnb_120bpm",
            name: "dnb_120bpm",
            displayName: "Liquid Smooth",
            fileName: "dnb_120bpm.mp3",
            bpm: 120,
            genre: .dnb,
            duration: 180,
            difficulty: 4
        ),
        BackingTrack(
            id: "dnb_174bpm",
            name: "dnb_174bpm",
            displayName: "Jungle Warfare",
            fileName: "dnb_174bpm.mp3",
            bpm: 174,
            genre: .dnb,
            duration: 180,
            difficulty: 5
        ),
        BackingTrack(
            id: "house_120bpm",
            name: "house_120bpm",
            displayName: "Deep Groove",
            fileName: "house_120bpm.mp3",
            bpm: 120,
            genre: .house,
            duration: 180,
            difficulty: 3
        ),
        BackingTrack(
            id: "house_128bpm",
            name: "house_128bpm",
            displayName: "Club Classic",
            fileName: "house_128bpm.mp3",
            bpm: 128,
            genre: .house,
            duration: 180,
            difficulty: 3
        ),
        BackingTrack(
            id: "breakbeat_100bpm",
            name: "breakbeat_100bpm",
            displayName: "Amen Brother",
            fileName: "breakbeat_100bpm.mp3",
            bpm: 100,
            genre: .breakbeat,
            duration: 180,
            difficulty: 2
        ),
        BackingTrack(
            id: "breakbeat_130bpm",
            name: "breakbeat_130bpm",
            displayName: "Funky Drummer",
            fileName: "breakbeat_130bpm.mp3",
            bpm: 130,
            genre: .breakbeat,
            duration: 180,
            difficulty: 4
        )
    ]
    
    // Available tracks
    @Published var availableTracks: [BackingTrack] = []
    @Published var selectedTrack: BackingTrack?
    
    // Playback state
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var currentBeat: Int = 0
    
    // Audio player
    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    
    // Beat tracking
    private var beatInterval: TimeInterval = 0
    private var lastBeatTime: TimeInterval = 0
    var onBeat: ((Int) -> Void)?
    
    // UserDefaults
    private let selectedTrackKey = "selectedBackingTrackID"
    
    private init() {
        loadDefaultTracks()
        loadSelectedTrack()
    }
    
    // MARK: - Setup

    static func bundledDefaultTracks(in resourceRoot: URL?) -> [BackingTrack] {
        bundledDefaultTracksCatalog.filter { bundledTrackURL(for: $0, in: resourceRoot) != nil }
    }

    static func bundledTrackURL(for track: BackingTrack, in resourceRoot: URL?) -> URL? {
        guard let resourceRoot else { return nil }

        let primaryURL = resourceRoot.appendingPathComponent(track.fileName)
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }

        let fallbackExtensions = ["mp3", "m4a", "wav"]
        for ext in fallbackExtensions {
            let fallbackURL = resourceRoot.appendingPathComponent("\(track.name).\(ext)")
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                return fallbackURL
            }
        }

        return nil
    }
    
    private func loadDefaultTracks() {
        availableTracks = Self.bundledDefaultTracks(in: Bundle.main.resourceURL)

        if let selectedTrack, availableTracks.contains(where: { $0.id == selectedTrack.id }) {
            return
        }

        selectedTrack = availableTracks.first
    }
    
    private func loadSelectedTrack() {
        if let savedID = UserDefaults.standard.string(forKey: selectedTrackKey),
           let track = availableTracks.first(where: { $0.id == savedID }) {
            selectedTrack = track
        }
    }
    
    // MARK: - Track Selection
    
    func selectTrack(_ track: BackingTrack) {
        stop()
        selectedTrack = track
        UserDefaults.standard.set(track.id, forKey: selectedTrackKey)
        loadTrack(track)
    }
    
    func loadTrack(_ track: BackingTrack) {
        guard let url = Self.bundledTrackURL(for: track, in: Bundle.main.resourceURL) else {
            audioPlayer = nil
            isPlaying = false
            print("Backing track not found: \(track.fileName)")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1 // Loop indefinitely
            audioPlayer?.prepareToPlay()
            
            // Calculate beat interval
            beatInterval = 60.0 / Double(track.bpm)
        } catch {
            print("Error loading backing track: \(error)")
        }
    }
    
    // MARK: - Playback Control
    
    func play() {
        guard let player = audioPlayer else {
            if let track = selectedTrack {
                loadTrack(track)
            }
            return
        }
        
        player.play()
        isPlaying = true
        startBeatTracking()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopBeatTracking()
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        currentTime = 0
        currentBeat = 0
        stopBeatTracking()
    }
    
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func setVolume(_ volume: Float) {
        audioPlayer?.volume = volume
    }
    
    // MARK: - Beat Tracking
    
    private func startBeatTracking() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateBeat))
        displayLink?.add(to: .main, forMode: .common)
        lastBeatTime = 0
    }
    
    private func stopBeatTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateBeat() {
        guard let player = audioPlayer, isPlaying else { return }
        
        currentTime = player.currentTime
        
        // Check if we've hit a new beat
        let expectedBeat = Int(currentTime / beatInterval)
        if expectedBeat > currentBeat {
            currentBeat = expectedBeat
            onBeat?(currentBeat)
        }
    }
    
    // MARK: - Timing Analysis
    
    func getTimingOffset(from timestamp: TimeInterval) -> Double {
        // Calculate how far off the timestamp is from the nearest beat
        let beatPosition = timestamp.truncatingRemainder(dividingBy: beatInterval)
        
        // If closer to the next beat, calculate offset as negative
        if beatPosition > beatInterval / 2 {
            return beatPosition - beatInterval
        }
        
        return beatPosition
    }
    
    func isOnBeat(timestamp: TimeInterval, tolerance: Double = 0.1) -> Bool {
        let offset = abs(getTimingOffset(from: timestamp))
        return offset <= tolerance
    }
    
    // MARK: - Helpers
    
    func tracksForGenre(_ genre: BackingTrack.TrackGenre) -> [BackingTrack] {
        return availableTracks.filter { $0.genre == genre }
    }
    
    func tracksForDifficulty(_ difficulty: Int) -> [BackingTrack] {
        return availableTracks.filter { $0.difficulty == difficulty }
    }
    
    func recommendedTrack(forLevel level: Int) -> BackingTrack? {
        // Recommend tracks based on level difficulty
        let targetDifficulty = min(level, 5)
        return availableTracks.first { $0.difficulty == targetDifficulty }
    }
}

// MARK: - Backing Track Selection View
import SwiftUI

struct BackingTrackSelectionView: View {
    @ObservedObject var trackManager = BackingTrackManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedGenre: BackingTrack.TrackGenre?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Genre filter
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            GenreFilterButton(
                                title: "All",
                                icon: "🎵",
                                isSelected: selectedGenre == nil,
                                color: "FFD700",
                                onTap: { selectedGenre = nil }
                            )
                            
                            ForEach(BackingTrack.TrackGenre.allCases, id: \.self) { genre in
                                GenreFilterButton(
                                    title: genre.rawValue,
                                    icon: genre.icon,
                                    isSelected: selectedGenre == genre,
                                    color: genre.color,
                                    onTap: { selectedGenre = genre }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.vertical, 16)
                    
                    // Track list
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if filteredTracks.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Bundled backing tracks are unavailable on this build.")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.white)

                                    Text("This legacy screen now hides any track that is not actually bundled with the app.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(0.62))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                ForEach(filteredTracks) { track in
                                    BackingTrackRow(
                                        track: track,
                                        isSelected: trackManager.selectedTrack?.id == track.id,
                                        isPlaying: trackManager.isPlaying && trackManager.selectedTrack?.id == track.id,
                                        onSelect: {
                                            trackManager.selectTrack(track)
                                        },
                                        onPlay: {
                                            if trackManager.selectedTrack?.id == track.id {
                                                trackManager.togglePlayback()
                                            } else {
                                                trackManager.selectTrack(track)
                                                trackManager.play()
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 100)
                    }
                }
                
                // Now playing bar
                if trackManager.selectedTrack != nil {
                    VStack {
                        Spacer()
                        NowPlayingBar(trackManager: trackManager)
                    }
                }
            }
            .navigationTitle("Backing Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "FFD700"))
                }
            }
        }
    }
    
    private var filteredTracks: [BackingTrack] {
        if let genre = selectedGenre {
            return trackManager.tracksForGenre(genre)
        }
        return trackManager.availableTracks
    }
}

struct GenreFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(icon)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(isSelected ? .black : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color(hex: color) : Color.white.opacity(0.1))
            .cornerRadius(16)
        }
    }
}

struct BackingTrackRow: View {
    let track: BackingTrack
    let isSelected: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Play button
            Button(action: onPlay) {
                ZStack {
                    Circle()
                        .fill(Color(hex: track.genre.color).opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color(hex: track.genre.color))
                }
            }
            
            // Track info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(track.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(track.genre.icon)
                        .font(.caption)
                }
                
                HStack(spacing: 12) {
                    // BPM
                    HStack(spacing: 4) {
                        Image(systemName: "metronome")
                            .font(.caption2)
                        Text("\(track.bpm) BPM")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    
                    // Difficulty
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in
                            Circle()
                                .fill(i < track.difficulty ? Color(hex: track.genre.color) : Color.white.opacity(0.2))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Selection
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Color(hex: "4CAF50") : .white.opacity(0.3))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(hex: track.genre.color).opacity(0.1) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color(hex: track.genre.color).opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
    }
}

struct NowPlayingBar: View {
    @ObservedObject var trackManager: BackingTrackManager
    
    var body: some View {
        if let track = trackManager.selectedTrack {
            HStack(spacing: 16) {
                // Genre icon
                Text(track.genre.icon)
                    .font(.title2)
                
                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("\(track.bpm) BPM • Beat \(trackManager.currentBeat)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                Spacer()
                
                // Playback controls
                Button(action: { trackManager.togglePlayback() }) {
                    Image(systemName: trackManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: track.genre.color))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                Rectangle()
                    .fill(Color(hex: "1A1A1A"))
                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: -5)
            )
        }
    }
}

#if DEBUG
struct BackingTrackSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        BackingTrackSelectionView()
    }
}
#endif
