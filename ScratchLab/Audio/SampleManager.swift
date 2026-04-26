// SampleManager.swift
// ScratchLab - Scratch Sample Management
// Manages the audio samples users scratch with (Fresh, Ahhh, Ah Yeah, etc.)

import Foundation
import AVFoundation

// MARK: - Scratch Sample
struct ScratchSample: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let displayName: String
    let fileName: String
    let category: SampleCategory
    let duration: TimeInterval
    let description: String
    let isDefault: Bool
    
    enum SampleCategory: String, Codable, CaseIterable {
        case classic = "Classic"
        case vocal = "Vocal"
        case sfx = "SFX"
        case custom = "Custom"
        
        var icon: String {
            switch self {
            case .classic: return "🎵"
            case .vocal: return "🎤"
            case .sfx: return "💥"
            case .custom: return "⭐️"
            }
        }
    }
}

// MARK: - Sample Manager
class SampleManager: ObservableObject {
    static let shared = SampleManager()
    
    // Available samples
    @Published var availableSamples: [ScratchSample] = []
    @Published var selectedSample: ScratchSample?
    @Published var customSamples: [ScratchSample] = []
    
    // Audio players for preview
    private var previewPlayer: AVAudioPlayer?
    
    // File manager
    private let fileManager = FileManager.default
    private var samplesDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ScratchSamples", isDirectory: true)
    }
    
    // UserDefaults
    private let selectedSampleKey = "selectedSampleID"
    
    private init() {
        setupSamplesDirectory()
        loadDefaultSamples()
        loadCustomSamples()
        loadSelectedSample()
    }
    
    // MARK: - Setup
    
    private func setupSamplesDirectory() {
        if !fileManager.fileExists(atPath: samplesDirectory.path) {
            try? fileManager.createDirectory(at: samplesDirectory, withIntermediateDirectories: true)
        }
    }
    
    private func loadDefaultSamples() {
        // These are the classic DJ scratch samples that will be bundled with the app
        availableSamples = [
            // Classic Samples
            ScratchSample(
                id: "fresh",
                name: "fresh",
                displayName: "Fresh",
                fileName: "fresh.wav",
                category: .classic,
                duration: 0.8,
                description: "The classic 'Fresh' vocal sample",
                isDefault: true
            ),
            ScratchSample(
                id: "ahhh",
                name: "ahhh",
                displayName: "Ahhh",
                fileName: "ahhh.wav",
                category: .classic,
                duration: 1.2,
                description: "Long vocal 'Ahhh' - great for transforms",
                isDefault: true
            ),
            ScratchSample(
                id: "ah_yeah",
                name: "ah_yeah",
                displayName: "Ah Yeah",
                fileName: "ah_yeah.wav",
                category: .classic,
                duration: 0.9,
                description: "Classic hip-hop vocal",
                isDefault: true
            ),
            ScratchSample(
                id: "wickid",
                name: "wickid",
                displayName: "Wickid",
                fileName: "wickid.wav",
                category: .classic,
                duration: 0.7,
                description: "Sharp vocal hit",
                isDefault: true
            ),
            
            // Vocal Samples
            ScratchSample(
                id: "yeah_boy",
                name: "yeah_boy",
                displayName: "Yeah Boy",
                fileName: "yeah_boy.wav",
                category: .vocal,
                duration: 0.6,
                description: "Hype vocal sample",
                isDefault: true
            ),
            ScratchSample(
                id: "unh",
                name: "unh",
                displayName: "Unh",
                fileName: "unh.wav",
                category: .vocal,
                duration: 0.3,
                description: "Short grunt - perfect for stabs",
                isDefault: true
            ),
            ScratchSample(
                id: "check_it_out",
                name: "check_it_out",
                displayName: "Check It Out",
                fileName: "check_it_out.wav",
                category: .vocal,
                duration: 0.8,
                description: "Classic phrase",
                isDefault: true
            ),
            ScratchSample(
                id: "lets_go",
                name: "lets_go",
                displayName: "Let's Go",
                fileName: "lets_go.wav",
                category: .vocal,
                duration: 0.5,
                description: "Energy vocal",
                isDefault: true
            ),
            
            // SFX Samples
            ScratchSample(
                id: "horn",
                name: "horn",
                displayName: "Air Horn",
                fileName: "horn.wav",
                category: .sfx,
                duration: 1.0,
                description: "Classic air horn",
                isDefault: true
            ),
            ScratchSample(
                id: "laser",
                name: "laser",
                displayName: "Laser",
                fileName: "laser.wav",
                category: .sfx,
                duration: 0.4,
                description: "Sci-fi laser sound",
                isDefault: true
            ),
            ScratchSample(
                id: "808_kick",
                name: "808_kick",
                displayName: "808 Kick",
                fileName: "808_kick.wav",
                category: .sfx,
                duration: 0.5,
                description: "Deep 808 kick drum",
                isDefault: true
            ),
            ScratchSample(
                id: "snare_hit",
                name: "snare_hit",
                displayName: "Snare Hit",
                fileName: "snare_hit.wav",
                category: .sfx,
                duration: 0.3,
                description: "Punchy snare",
                isDefault: true
            )
        ]
        
        // Set default selected sample
        if selectedSample == nil {
            selectedSample = availableSamples.first
        }
    }
    
    private func loadCustomSamples() {
        // Load any user-imported samples
        guard let files = try? fileManager.contentsOfDirectory(at: samplesDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        let audioExtensions = ["wav", "mp3", "m4a", "aiff"]
        
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }
            
            let name = file.deletingPathExtension().lastPathComponent
            
            // Skip if already in custom samples
            guard !customSamples.contains(where: { $0.id == "custom_\(name)" }) else { continue }
            
            // Get duration
            let duration = getAudioDuration(url: file) ?? 1.0
            
            let sample = ScratchSample(
                id: "custom_\(name)",
                name: name,
                displayName: name.capitalized,
                fileName: file.lastPathComponent,
                category: .custom,
                duration: duration,
                description: "Custom sample",
                isDefault: false
            )
            
            customSamples.append(sample)
        }
        
        // Add custom samples to available
        availableSamples.append(contentsOf: customSamples)
    }
    
    private func loadSelectedSample() {
        if let savedID = UserDefaults.standard.string(forKey: selectedSampleKey),
           let sample = availableSamples.first(where: { $0.id == savedID }) {
            selectedSample = sample
        }
    }
    
    // MARK: - Sample Selection
    
    func selectSample(_ sample: ScratchSample) {
        selectedSample = sample
        UserDefaults.standard.set(sample.id, forKey: selectedSampleKey)
    }
    
    func getSampleURL(_ sample: ScratchSample) -> URL? {
        if sample.isDefault {
            // Look in app bundle
            return Bundle.main.url(forResource: sample.name, withExtension: "wav")
        } else {
            // Look in documents
            return samplesDirectory.appendingPathComponent(sample.fileName)
        }
    }
    
    // MARK: - Preview
    
    func previewSample(_ sample: ScratchSample) {
        guard let url = getSampleURL(sample) else {
            print("Sample not found: \(sample.name)")
            return
        }
        
        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
            previewPlayer?.play()
        } catch {
            print("Error playing sample: \(error)")
        }
    }
    
    func stopPreview() {
        previewPlayer?.stop()
    }
    
    // MARK: - Import Custom Sample
    
    func importSample(from sourceURL: URL, name: String) -> Bool {
        let destURL = samplesDirectory.appendingPathComponent("\(name).wav")
        
        do {
            // Copy file to samples directory
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
            
            // Get duration
            let duration = getAudioDuration(url: destURL) ?? 1.0
            
            // Add to custom samples
            let sample = ScratchSample(
                id: "custom_\(name)",
                name: name,
                displayName: name.capitalized,
                fileName: "\(name).wav",
                category: .custom,
                duration: duration,
                description: "Custom sample",
                isDefault: false
            )
            
            customSamples.append(sample)
            availableSamples.append(sample)
            
            return true
        } catch {
            print("Error importing sample: \(error)")
            return false
        }
    }
    
    func deleteCustomSample(_ sample: ScratchSample) {
        guard !sample.isDefault else { return }
        
        let url = samplesDirectory.appendingPathComponent(sample.fileName)
        try? fileManager.removeItem(at: url)
        
        customSamples.removeAll { $0.id == sample.id }
        availableSamples.removeAll { $0.id == sample.id }
        
        // Reset selection if deleted sample was selected
        if selectedSample?.id == sample.id {
            selectedSample = availableSamples.first
        }
    }
    
    // MARK: - Helpers
    
    private func getAudioDuration(url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        return asset.duration.seconds
    }
    
    func samplesForCategory(_ category: ScratchSample.SampleCategory) -> [ScratchSample] {
        return availableSamples.filter { $0.category == category }
    }
}

// MARK: - Sample Selection View
import SwiftUI

struct SampleSelectionView: View {
    @ObservedObject var sampleManager = SampleManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedCategory: ScratchSample.SampleCategory = .classic
    @State private var showingImporter = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Category tabs
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ScratchSample.SampleCategory.allCases, id: \.self) { category in
                                CategoryTab(
                                    category: category,
                                    isSelected: selectedCategory == category,
                                    onTap: { selectedCategory = category }
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.vertical, 16)
                    
                    // Sample list
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(sampleManager.samplesForCategory(selectedCategory)) { sample in
                                SampleRow(
                                    sample: sample,
                                    isSelected: sampleManager.selectedSample?.id == sample.id,
                                    onSelect: {
                                        sampleManager.selectSample(sample)
                                    },
                                    onPreview: {
                                        sampleManager.previewSample(sample)
                                    },
                                    onDelete: sample.isDefault ? nil : {
                                        sampleManager.deleteCustomSample(sample)
                                    }
                                )
                            }
                            
                            // Import button for custom category
                            if selectedCategory == .custom {
                                Button(action: { showingImporter = true }) {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                        Text("Import Custom Sample")
                                    }
                                    .font(.custom("Futura-Medium", size: 14))
                                    .foregroundColor(Color(hex: "FFD700"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(Color(hex: "FFD700").opacity(0.1))
                                    .cornerRadius(12)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Scratch Sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "FFD700"))
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }
    
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            let name = url.deletingPathExtension().lastPathComponent
            _ = sampleManager.importSample(from: url, name: name)
            
        case .failure(let error):
            print("Import error: \(error)")
        }
    }
}

struct CategoryTab: View {
    let category: ScratchSample.SampleCategory
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(category.icon)
                Text(category.rawValue)
                    .font(.custom("Futura-Bold", size: 12))
            }
            .foregroundColor(isSelected ? .black : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color(hex: "FFD700") : Color.white.opacity(0.1))
            .cornerRadius(20)
        }
    }
}

struct SampleRow: View {
    let sample: ScratchSample
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onDelete: (() -> Void)?
    
    @State private var isPlaying = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Play preview button
            Button(action: {
                isPlaying.toggle()
                if isPlaying {
                    onPreview()
                    // Auto-stop after duration
                    DispatchQueue.main.asyncAfter(deadline: .now() + sample.duration) {
                        isPlaying = false
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }
            }
            
            // Sample info
            VStack(alignment: .leading, spacing: 4) {
                Text(sample.displayName)
                    .font(.custom("Futura-Bold", size: 16))
                    .foregroundColor(.white)
                
                Text(sample.description)
                    .font(.custom("Futura-Medium", size: 11))
                    .foregroundColor(.white.opacity(0.5))
                
                // Duration
                Text(String(format: "%.1fs", sample.duration))
                    .font(.custom("Futura-Medium", size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            Spacer()
            
            // Delete button (custom samples only)
            if let delete = onDelete {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .foregroundColor(Color(hex: "F44336"))
                }
            }
            
            // Selection indicator
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Color(hex: "4CAF50") : .white.opacity(0.3))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(hex: "4CAF50").opacity(0.1) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color(hex: "4CAF50").opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Instructions View for Sample Setup
struct SampleSetupInstructionsView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Setting Up Your Scratch Sample")
                                .font(.custom("Futura-Bold", size: 24))
                                .foregroundColor(.white)
                            
                            Text("To practice scratching, you need to load a sample on your DJ software or turntable.")
                                .font(.custom("Futura-Medium", size: 14))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        // Steps
                        VStack(alignment: .leading, spacing: 20) {
                            SetupStep(
                                number: 1,
                                title: "Download the Sample",
                                description: "We'll send the audio file to your device. You can also use any short vocal or sound."
                            )
                            
                            SetupStep(
                                number: 2,
                                title: "Load in DJ Software",
                                description: "Import the sample into Serato, Traktor, rekordbox, or your DJ software."
                            )
                            
                            SetupStep(
                                number: 3,
                                title: "Set a Cue Point",
                                description: "Place a cue point at the start of the sound so you can quickly return to it."
                            )
                            
                            SetupStep(
                                number: 4,
                                title: "Connect Audio",
                                description: "Route your DJ software's audio output to this app, or position your phone to hear through the microphone."
                            )
                        }
                        
                        // Software-specific tips
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Software Tips")
                                .font(.custom("Futura-Bold", size: 18))
                                .foregroundColor(.white)
                            
                            SoftwareTip(
                                name: "Serato DJ",
                                tip: "Use the SP-6 sampler or load on a deck"
                            )
                            
                            SoftwareTip(
                                name: "Traktor",
                                tip: "Load in Remix Deck or on a track deck"
                            )
                            
                            SoftwareTip(
                                name: "rekordbox",
                                tip: "Use the sampler or load on deck"
                            )
                            
                            SoftwareTip(
                                name: "djay Pro",
                                tip: "Load directly on a deck"
                            )
                        }
                        .padding(.top, 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Sample Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "FFD700"))
                }
            }
        }
    }
}

struct SetupStep: View {
    let number: Int
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(hex: "FFD700"))
                    .frame(width: 32, height: 32)
                
                Text("\(number)")
                    .font(.custom("Futura-Bold", size: 16))
                    .foregroundColor(.black)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("Futura-Bold", size: 16))
                    .foregroundColor(.white)
                
                Text(description)
                    .font(.custom("Futura-Medium", size: 13))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

struct SoftwareTip: View {
    let name: String
    let tip: String
    
    var body: some View {
        HStack {
            Text(name)
                .font(.custom("Futura-Bold", size: 13))
                .foregroundColor(Color(hex: "FFD700"))
                .frame(width: 100, alignment: .leading)
            
            Text(tip)
                .font(.custom("Futura-Medium", size: 13))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

#Preview {
    SampleSelectionView()
}
