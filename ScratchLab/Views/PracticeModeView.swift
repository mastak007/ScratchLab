// PracticeModeView.swift
// ScratchLab - Practice Mode
// Camera feed with gamification overlays for scratch practice

import SwiftUI
import AVFoundation

struct PracticeModeView: View {
    let scratch: Scratch
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var gameState: GameState
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var progressManager: ProgressManager
    
    // Session state
    @State private var isSessionActive = false
    @State private var isPaused = false
    @State private var showingTutorial = false
    @State private var showingResults = false
    
    // Timing
    @State private var selectedDuration: TimeInterval = 300 // 5 min default
    @State private var timeRemaining: TimeInterval = 300
    @State private var sessionTimer: Timer?
    
    // Scoring
    @State private var currentScore: Int = 0
    @State private var currentAccuracy: Double = 0
    @State private var attemptCount: Int = 0
    @State private var currentStreak: Int = 0
    @State private var bestStreak: Int = 0
    
    // Feedback
    @State private var lastFeedback: [String] = []
    @State private var showFeedback = false
    @State private var feedbackColor: Color = .white
    
    // Animation states
    @State private var pulseRing = false
    @State private var showAccuracyBurst = false
    @State private var lastAccuracyValue: Double = 0
    
    let durationOptions: [(String, TimeInterval)] = [
        ("5 min", 300),
        ("10 min", 600),
        ("15 min", 900)
    ]
    
    var body: some View {
        ZStack {
            // Camera feed background
            CameraPreviewView()
                .ignoresSafeArea()
            
            // Dark overlay for readability
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            
            // Main UI overlay
            VStack(spacing: 0) {
                // Top bar
                topBar
                
                Spacer()
                
                // Center feedback area
                if isSessionActive {
                    centerFeedbackArea
                }
                
                Spacer()
                
                // Bottom controls
                bottomControls
            }
            
            // Accuracy burst animation
            if showAccuracyBurst {
                AccuracyBurstView(accuracy: lastAccuracyValue)
                    .transition(.scale.combined(with: .opacity))
            }
            
            // Tutorial overlay
            if showingTutorial {
                TutorialOverlayView(scratch: scratch, onDismiss: { showingTutorial = false })
            }
            
            // Results screen
            if showingResults {
                ResultsOverlayView(
                    scratch: scratch,
                    score: currentScore,
                    accuracy: currentAccuracy,
                    attempts: attemptCount,
                    bestStreak: bestStreak,
                    onContinue: { showingResults = false; resetSession() },
                    onExit: { dismiss() }
                )
            }
            
            // Pause overlay
            if isPaused {
                PauseOverlayView(
                    onResume: { resumeSession() },
                    onRestart: { resetSession(); startSession() },
                    onExit: { dismiss() },
                    onTutorial: { showingTutorial = true }
                )
            }
            
            // Pre-session setup
            if !isSessionActive && !showingResults {
                SessionSetupOverlay(
                    scratch: scratch,
                    selectedDuration: $selectedDuration,
                    durationOptions: durationOptions,
                    onStart: { startSession() },
                    onTutorial: { showingTutorial = true },
                    onBack: { dismiss() }
                )
            }
        }
        .onAppear {
            setupAudioEngine()
        }
        .onDisappear {
            cleanupSession()
        }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack {
            // Back/Pause button
            Button(action: {
                if isSessionActive {
                    pauseSession()
                } else {
                    dismiss()
                }
            }) {
                Image(systemName: isSessionActive ? "pause.fill" : "chevron.left")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            // Timer
            if isSessionActive {
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(timeRemaining < 60 ? Color(hex: "F44336") : Color(hex: "FFD700"))
                    
                    Text(formatTime(timeRemaining))
                        .font(.custom("Futura-Bold", size: 24))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))
                .cornerRadius(20)
            }
            
            Spacer()
            
            // Tutorial button
            Button(action: { showingTutorial = true }) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }
    
    // MARK: - Center Feedback Area
    
    private var centerFeedbackArea: some View {
        VStack(spacing: 24) {
            // Current scratch name
            VStack(spacing: 4) {
                Text(scratch.name.uppercased())
                    .font(.custom("Futura-Bold", size: 28))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                
                Text(scratch.technique.rawValue)
                    .font(.custom("Futura-Medium", size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Accuracy ring
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(feedbackColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 180, height: 180)
                    .scaleEffect(pulseRing ? 1.2 : 1.0)
                    .opacity(pulseRing ? 0 : 1)
                
                // Main ring
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 8)
                    .frame(width: 160, height: 160)
                
                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(currentAccuracy / 100))
                    .stroke(
                        accuracyGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 160, height: 160)
                    .rotationEffect(.degrees(-90))
                
                // Center content
                VStack(spacing: 4) {
                    Text("\(Int(currentAccuracy))%")
                        .font(.custom("Futura-Bold", size: 48))
                        .foregroundColor(.white)
                    
                    Text("ACCURACY")
                        .font(.custom("Futura-Medium", size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            // Feedback text
            if showFeedback && !lastFeedback.isEmpty {
                VStack(spacing: 8) {
                    ForEach(lastFeedback, id: \.self) { feedback in
                        Text(feedback)
                            .font(.custom("Futura-Medium", size: 14))
                            .foregroundColor(feedbackColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(8)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // Stats row
            HStack(spacing: 40) {
                StatDisplay(icon: "flame.fill", value: "\(currentStreak)", label: "Streak", color: Color(hex: "FF5722"))
                StatDisplay(icon: "star.fill", value: "\(currentScore)", label: "Score", color: Color(hex: "FFD700"))
                StatDisplay(icon: "number", value: "\(attemptCount)", label: "Attempts", color: Color(hex: "2196F3"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.5))
            .cornerRadius(16)
        }
    }
    
    private var accuracyGradient: LinearGradient {
        if currentAccuracy >= 90 {
            return LinearGradient(colors: [Color(hex: "4CAF50"), Color(hex: "8BC34A")], startPoint: .leading, endPoint: .trailing)
        } else if currentAccuracy >= 70 {
            return LinearGradient(colors: [Color(hex: "FF9800"), Color(hex: "FFC107")], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [Color(hex: "F44336"), Color(hex: "FF5722")], startPoint: .leading, endPoint: .trailing)
        }
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Audio level indicator
            if isSessionActive {
                AudioLevelIndicator(level: audioEngine.inputLevel)
            }
            
            // Tips
            if isSessionActive {
                Text("💡 \(scratch.tips.randomElement() ?? "Focus on clean execution")")
                    .font(.custom("Futura-Medium", size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
            }
        }
        .padding(.bottom, 40)
    }
    
    // MARK: - Session Management
    
    private func setupAudioEngine() {
        audioEngine.start()
        audioEngine.onScratchDetected = { [self] result in
            handleScratchDetected(result)
        }
    }
    
    private func startSession() {
        timeRemaining = selectedDuration
        currentScore = 0
        currentAccuracy = 0
        attemptCount = 0
        currentStreak = 0
        bestStreak = 0
        
        isSessionActive = true
        isPaused = false
        
        // Start audio analysis
        audioEngine.startAnalyzing(for: scratch)
        
        // Load and play backing track
        audioEngine.loadBackingTrack(named: scratch.backingTrackName)
        audioEngine.playBackingTrack()
        
        // Start timer
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                endSession()
            }
        }
    }
    
    private func pauseSession() {
        isPaused = true
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        audioEngine.pauseBackingTrack()
    }
    
    private func resumeSession() {
        isPaused = false
        audioEngine.startAnalyzing(for: scratch)
        audioEngine.playBackingTrack()
        
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                endSession()
            }
        }
    }
    
    private func endSession() {
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        audioEngine.stopBackingTrack()
        
        isSessionActive = false
        showingResults = true
        
        // Save progress
        progressManager.recordScratchAttempt(
            scratchID: scratch.id,
            accuracy: currentAccuracy,
            duration: selectedDuration - timeRemaining
        )
    }
    
    private func resetSession() {
        timeRemaining = selectedDuration
        currentScore = 0
        currentAccuracy = 0
        attemptCount = 0
        currentStreak = 0
        bestStreak = 0
        showingResults = false
        isSessionActive = false
    }
    
    private func cleanupSession() {
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        audioEngine.stopBackingTrack()
    }
    
    private func handleScratchDetected(_ result: ScratchAnalysisResult) {
        attemptCount += 1
        
        // Update accuracy (running average)
        if currentAccuracy == 0 {
            currentAccuracy = result.accuracy
        } else {
            currentAccuracy = (currentAccuracy * Double(attemptCount - 1) + result.accuracy) / Double(attemptCount)
        }
        
        // Update score
        let basePoints = 100
        let accuracyMultiplier = result.accuracy / 100.0
        let streakMultiplier = 1.0 + (Double(currentStreak) * 0.1)
        currentScore += Int(Double(basePoints) * accuracyMultiplier * streakMultiplier)
        
        // Update streak
        if result.accuracy >= 70 {
            currentStreak += 1
            if currentStreak > bestStreak {
                bestStreak = currentStreak
            }
        } else {
            currentStreak = 0
        }
        
        // Show feedback
        lastFeedback = result.feedback
        lastAccuracyValue = result.accuracy
        
        // Determine feedback color
        if result.accuracy >= 90 {
            feedbackColor = Color(hex: "4CAF50")
        } else if result.accuracy >= 70 {
            feedbackColor = Color(hex: "FF9800")
        } else {
            feedbackColor = Color(hex: "F44336")
        }
        
        // Animate
        withAnimation(.easeOut(duration: 0.3)) {
            showFeedback = true
            showAccuracyBurst = true
        }
        
        withAnimation(.easeOut(duration: 0.5)) {
            pulseRing = true
        }
        
        // Hide feedback after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showFeedback = false
                showAccuracyBurst = false
                pulseRing = false
            }
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            return view
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = UIScreen.main.bounds
        view.layer.addSublayer(previewLayer)
        
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Audio Level Indicator

struct AudioLevelIndicator: View {
    let level: Float
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                Rectangle()
                    .fill(barColor(for: i))
                    .frame(width: 8, height: 30)
                    .opacity(Float(i) / 20.0 < level * 5 ? 1.0 : 0.3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
    }
    
    private func barColor(for index: Int) -> Color {
        if index < 12 {
            return Color(hex: "4CAF50")
        } else if index < 16 {
            return Color(hex: "FFC107")
        } else {
            return Color(hex: "F44336")
        }
    }
}

// MARK: - Stat Display

struct StatDisplay: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(value)
                    .font(.custom("Futura-Bold", size: 18))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.custom("Futura-Medium", size: 10))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - Accuracy Burst Animation

struct AccuracyBurstView: View {
    let accuracy: Double
    
    var body: some View {
        ZStack {
            // Expanding rings
            ForEach(0..<3) { i in
                Circle()
                    .stroke(burstColor.opacity(0.5 - Double(i) * 0.15), lineWidth: 3)
                    .frame(width: 100 + CGFloat(i * 40), height: 100 + CGFloat(i * 40))
            }
            
            // Center text
            Text(accuracy >= 90 ? "🔥" : accuracy >= 70 ? "👍" : "💪")
                .font(.system(size: 60))
        }
    }
    
    private var burstColor: Color {
        if accuracy >= 90 {
            return Color(hex: "4CAF50")
        } else if accuracy >= 70 {
            return Color(hex: "FF9800")
        } else {
            return Color(hex: "F44336")
        }
    }
}

// MARK: - Session Setup Overlay

struct SessionSetupOverlay: View {
    let scratch: Scratch
    @Binding var selectedDuration: TimeInterval
    let durationOptions: [(String, TimeInterval)]
    let onStart: () -> Void
    let onTutorial: () -> Void
    let onBack: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Text("PRACTICE")
                        .font(.custom("Futura-Bold", size: 16))
                        .foregroundColor(Color(hex: "FFD700"))
                    
                    Text(scratch.name)
                        .font(.custom("Futura-Bold", size: 32))
                        .foregroundColor(.white)
                    
                    Text(scratch.description)
                        .font(.custom("Futura-Medium", size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                // Duration selector
                VStack(spacing: 12) {
                    Text("SESSION LENGTH")
                        .font(.custom("Futura-Bold", size: 12))
                        .foregroundColor(.white.opacity(0.5))
                    
                    HStack(spacing: 12) {
                        ForEach(durationOptions, id: \.1) { option in
                            Button(action: { selectedDuration = option.1 }) {
                                Text(option.0)
                                    .font(.custom("Futura-Bold", size: 16))
                                    .foregroundColor(selectedDuration == option.1 ? .black : .white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .background(selectedDuration == option.1 ? Color(hex: "FFD700") : Color.white.opacity(0.1))
                                    .cornerRadius(12)
                            }
                        }
                    }
                }
                
                // Buttons
                VStack(spacing: 12) {
                    Button(action: onStart) {
                        Text("START SESSION")
                            .font(.custom("Futura-Bold", size: 18))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "FFD700"))
                            .cornerRadius(16)
                    }
                    
                    Button(action: onTutorial) {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text("Watch Tutorial First")
                        }
                        .font(.custom("Futura-Medium", size: 14))
                        .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 40)
                
                Button(action: onBack) {
                    Text("Back to Level")
                        .font(.custom("Futura-Medium", size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }
}

// MARK: - Pause Overlay

struct PauseOverlayView: View {
    let onResume: () -> Void
    let onRestart: () -> Void
    let onExit: () -> Void
    let onTutorial: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Text("PAUSED")
                    .font(.custom("Futura-Bold", size: 32))
                    .foregroundColor(.white)
                
                VStack(spacing: 12) {
                    PauseButton(title: "Resume", icon: "play.fill", color: Color(hex: "4CAF50"), action: onResume)
                    PauseButton(title: "Watch Tutorial", icon: "play.circle", color: Color(hex: "2196F3"), action: onTutorial)
                    PauseButton(title: "Restart", icon: "arrow.counterclockwise", color: Color(hex: "FF9800"), action: onRestart)
                    PauseButton(title: "Exit", icon: "xmark", color: Color(hex: "F44336"), action: onExit)
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

struct PauseButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .font(.custom("Futura-Bold", size: 16))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color, lineWidth: 2)
            )
            .cornerRadius(12)
        }
    }
}

// MARK: - Results Overlay

struct ResultsOverlayView: View {
    let scratch: Scratch
    let score: Int
    let accuracy: Double
    let attempts: Int
    let bestStreak: Int
    let onContinue: () -> Void
    let onExit: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Performance emoji
                Text(accuracy >= 90 ? "🔥" : accuracy >= 70 ? "👏" : "💪")
                    .font(.system(size: 80))
                
                // Result text
                VStack(spacing: 8) {
                    Text(accuracy >= 90 ? "MASTERY!" : accuracy >= 70 ? "GOOD JOB!" : "KEEP PRACTICING!")
                        .font(.custom("Futura-Bold", size: 28))
                        .foregroundColor(accuracy >= 90 ? Color(hex: "FFD700") : .white)
                    
                    Text(scratch.name)
                        .font(.custom("Futura-Medium", size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ResultStat(value: "\(Int(accuracy))%", label: "Accuracy", icon: "target")
                    ResultStat(value: "\(score)", label: "Score", icon: "star.fill")
                    ResultStat(value: "\(attempts)", label: "Attempts", icon: "number")
                    ResultStat(value: "\(bestStreak)", label: "Best Streak", icon: "flame.fill")
                }
                .padding(.horizontal, 40)
                
                // Progress to mastery
                if accuracy < 90 {
                    VStack(spacing: 8) {
                        Text("Progress to Mastery")
                            .font(.custom("Futura-Medium", size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        
                        ProgressView(value: accuracy, total: 90)
                            .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "FFD700")))
                            .padding(.horizontal, 40)
                        
                        Text("\(Int(90 - accuracy))% more to master")
                            .font(.custom("Futura-Medium", size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                
                // Buttons
                VStack(spacing: 12) {
                    Button(action: onContinue) {
                        Text("PRACTICE AGAIN")
                            .font(.custom("Futura-Bold", size: 16))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "FFD700"))
                            .cornerRadius(12)
                    }
                    
                    Button(action: onExit) {
                        Text("Back to Level")
                            .font(.custom("Futura-Medium", size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

struct ResultStat: View {
    let value: String
    let label: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(Color(hex: "FFD700"))
            
            Text(value)
                .font(.custom("Futura-Bold", size: 24))
                .foregroundColor(.white)
            
            Text(label)
                .font(.custom("Futura-Medium", size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Tutorial Overlay

struct TutorialOverlayView: View {
    let scratch: Scratch
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                
                // Video placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.1))
                        .aspectRatio(16/9, contentMode: .fit)
                    
                    VStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("Tutorial Video")
                            .font(.custom("Futura-Medium", size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                
                // Scratch info
                VStack(spacing: 16) {
                    Text(scratch.name)
                        .font(.custom("Futura-Bold", size: 24))
                        .foregroundColor(.white)
                    
                    Text(scratch.description)
                        .font(.custom("Futura-Medium", size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                // Tips
                VStack(alignment: .leading, spacing: 12) {
                    Text("TIPS")
                        .font(.custom("Futura-Bold", size: 12))
                        .foregroundColor(Color(hex: "FFD700"))
                    
                    ForEach(scratch.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(hex: "4CAF50"))
                            Text(tip)
                                .font(.custom("Futura-Medium", size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.05))
                .cornerRadius(16)
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Got it button
                Button(action: onDismiss) {
                    Text("GOT IT")
                        .font(.custom("Futura-Bold", size: 16))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "FFD700"))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    PracticeModeView(scratch: ScratchLibrary.shared.allScratches[0])
        .environmentObject(GameState())
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
}
