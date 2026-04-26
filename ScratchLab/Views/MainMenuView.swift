// MainMenuView.swift
// ScratchLab - Main Menu
// Hip-hop styled main menu with navigation to all modes

import SwiftUI

struct MainMenuView: View {
    @EnvironmentObject var gameState: GameState
    @EnvironmentObject var progressManager: ProgressManager
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var animateVinyl = false
    @State private var selectedMode: GameMode?
    
    var body: some View {
        ZStack {
            // Animated background
            BackgroundView()
            
            VStack(spacing: 0) {
                // Header
                headerView
                    .padding(.top, 20)
                
                Spacer()
                
                // Spinning vinyl decoration
                vinylDecoration
                    .padding(.vertical, 20)
                
                // Main menu buttons
                menuButtons
                    .padding(.horizontal, 24)
                
                Spacer()
                
                // Stats bar
                statsBar
                    .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                animateVinyl = true
            }
        }
        .navigationDestination(item: $selectedMode) { mode in
            destinationView(for: mode)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            // Profile button
            Button(action: { showingProfile = true }) {
                HStack(spacing: 8) {
                    Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progressManager.playerProfile?.displayName ?? "New DJ")
                            .font(.custom("Futura-Bold", size: 14))
                            .foregroundColor(.white)
                        
                        Text("Level \(progressManager.playerProfile?.level ?? 1)")
                            .font(.custom("Futura-Medium", size: 11))
                            .foregroundColor(Color(hex: "FFD700"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(20)
            }
            
            Spacer()
            
            // Logo
            VStack(spacing: 0) {
                Text("SCRATCH")
                    .font(.custom("Futura-Bold", size: 22))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("LAB")
                    .font(.custom("Futura-Bold", size: 22))
                    .foregroundColor(.white)
                    .tracking(8)
            }
            
            Spacer()
            
            // Settings button
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Vinyl Decoration
    
    private var vinylDecoration: some View {
        ZStack {
            // Outer ring glow
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: "FFD700").opacity(0.5), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .frame(width: 200, height: 200)
                .blur(radius: 5)
            
            // Vinyl record
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "1A1A1A"), Color(hex: "0D0D0D")],
                        center: .center,
                        startRadius: 20,
                        endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)
                .overlay(
                    // Grooves
                    ForEach(0..<6) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                            .frame(width: CGFloat(50 + i * 20), height: CGFloat(50 + i * 20))
                    }
                )
                .overlay(
                    // Center label
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "FFD700"), Color(hex: "FF8C00")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 50, height: 50)
                        
                        Text("SL")
                            .font(.custom("Futura-Bold", size: 18))
                            .foregroundColor(.black)
                    }
                )
                .rotationEffect(.degrees(animateVinyl ? 360 : 0))
            
            // Tonearm hint
            Rectangle()
                .fill(Color(hex: "444444"))
                .frame(width: 4, height: 60)
                .offset(x: 80, y: -30)
                .rotationEffect(.degrees(25))
        }
    }
    
    // MARK: - Menu Buttons
    
    private var menuButtons: some View {
        VStack(spacing: 16) {
            // Practice Mode
            MenuButton(
                title: "PRACTICE",
                subtitle: "Master your scratches",
                icon: "music.note.list",
                gradient: [Color(hex: "4CAF50"), Color(hex: "2E7D32")],
                action: { selectedMode = .practice }
            )
            
            // AI Challenge
            MenuButton(
                title: "AI BATTLE",
                subtitle: "Challenge the AI DJs",
                icon: "cpu",
                gradient: [Color(hex: "2196F3"), Color(hex: "1565C0")],
                action: { selectedMode = .aiChallenge }
            )
            
            // Online Battle
            MenuButton(
                title: "ONLINE BATTLE",
                subtitle: "90 sec head-to-head",
                icon: "person.2.fill",
                gradient: [Color(hex: "F44336"), Color(hex: "C62828")],
                action: { selectedMode = .onlineBattle }
            )
            
            // Tutorial
            MenuButton(
                title: "TUTORIAL",
                subtitle: "Learn the fundamentals",
                icon: "book.fill",
                gradient: [Color(hex: "9C27B0"), Color(hex: "6A1B9A")],
                action: { selectedMode = .tutorial }
            )
        }
    }
    
    // MARK: - Stats Bar
    
    private var statsBar: some View {
        HStack(spacing: 30) {
            StatItem(
                icon: "flame.fill",
                value: "\(progressManager.currentStreak)",
                label: "Day Streak",
                color: Color(hex: "FF5722")
            )
            
            StatItem(
                icon: "star.fill",
                value: "\(progressManager.playerProfile?.scratchesMastered.count ?? 0)/20",
                label: "Mastered",
                color: Color(hex: "FFD700")
            )
            
            StatItem(
                icon: "trophy.fill",
                value: "\(progressManager.playerProfile?.battlesWon ?? 0)",
                label: "Wins",
                color: Color(hex: "4CAF50")
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .padding(.horizontal, 24)
    }
    
    // MARK: - Navigation Destinations
    
    @ViewBuilder
    private func destinationView(for mode: GameMode) -> some View {
        switch mode {
        case .practice:
            LevelSelectView()
        case .aiChallenge:
            AIBattleSetupView()
        case .onlineBattle:
            OnlineBattleLobbyView()
        case .tutorial:
            TutorialHubView()
        }
    }
}

// MARK: - Menu Button Component

struct MenuButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom("Futura-Bold", size: 18))
                        .foregroundColor(.white)
                    
                    Text(subtitle)
                        .font(.custom("Futura-Medium", size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                // Arrow
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(16)
            .shadow(color: gradient[0].opacity(0.4), radius: isPressed ? 5 : 10, x: 0, y: isPressed ? 2 : 5)
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Stat Item Component

struct StatItem: View {
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
                    .font(.custom("Futura-Bold", size: 16))
                    .foregroundColor(.white)
            }
            
            Text(label)
                .font(.custom("Futura-Medium", size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - Background View

struct BackgroundView: View {
    var body: some View {
        ZStack {
            // Base gradient
            LinearGradient(
                colors: [
                    Color(hex: "0D0D0D"),
                    Color(hex: "1A1A2E"),
                    Color(hex: "16213E")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Subtle pattern overlay
            GeometryReader { geo in
                ForEach(0..<20) { i in
                    Circle()
                        .fill(Color.white.opacity(0.02))
                        .frame(width: CGFloat.random(in: 50...150))
                        .position(
                            x: CGFloat.random(in: 0...geo.size.width),
                            y: CGFloat.random(in: 0...geo.size.height)
                        )
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Placeholder Views (to be implemented)

struct ProfileView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var progressManager: ProgressManager
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                VStack(spacing: 24) {
                    // Avatar
                    Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                        .font(.system(size: 80))
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                    
                    // Name
                    Text(progressManager.playerProfile?.displayName ?? "DJ")
                        .font(.custom("Futura-Bold", size: 28))
                        .foregroundColor(.white)
                    
                    // Stats
                    HStack(spacing: 40) {
                        ProfileStat(value: "\(progressManager.playerProfile?.level ?? 1)", label: "Level")
                        ProfileStat(value: "\(progressManager.playerProfile?.totalScore ?? 0)", label: "Score")
                        ProfileStat(value: "\(progressManager.playerProfile?.battlesWon ?? 0)", label: "Wins")
                    }
                    
                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ProfileStat: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.custom("Futura-Bold", size: 24))
                .foregroundColor(Color(hex: "FFD700"))
            Text(label)
                .font(.custom("Futura-Medium", size: 12))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var audioEngine: AudioEngine
    @State private var selectedInput: AudioInputSource = .microphone
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                List {
                    Section("Audio Input") {
                        ForEach(AudioInputSource.allCases, id: \.self) { source in
                            Button(action: {
                                selectedInput = source
                                audioEngine.selectInputSource(source)
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(source.rawValue)
                                            .foregroundColor(.white)
                                        Text(source.description)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if selectedInput == source {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color(hex: "FFD700"))
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("1.0.0")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// Placeholder navigation destinations
struct OnlineBattleLobbyView: View {
    var body: some View {
        ZStack {
            BackgroundView()
            Text("Online Battle Lobby")
                .foregroundColor(.white)
        }
    }
}

struct TutorialHubView: View {
    var body: some View {
        ZStack {
            BackgroundView()
            Text("Tutorial Hub")
                .foregroundColor(.white)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MainMenuView()
    }
    .environmentObject(GameState())
    .environmentObject(AudioEngine())
    .environmentObject(ProgressManager())
}
