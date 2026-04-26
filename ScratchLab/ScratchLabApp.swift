// ScratchLabApp.swift
// ScratchLab - Turntablism Training & Battle App
// Main application entry point

import SwiftUI

@main
struct ScratchLabApp: App {
    @StateObject private var gameState = GameState()
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var progressManager = ProgressManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gameState)
                .environmentObject(audioEngine)
                .environmentObject(progressManager)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Content View (Root Navigation)
struct ContentView: View {
    @EnvironmentObject var gameState: GameState
    @State private var showSplash = true
    
    var body: some View {
        ZStack {
            // Background gradient - hip-hop themed
            LinearGradient(
                colors: [
                    Color(hex: "0D0D0D"),
                    Color(hex: "1A1A2E"),
                    Color(hex: "16213E")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            if showSplash {
                SplashView(showSplash: $showSplash)
            } else {
                NavigationStack {
                    MainMenuView()
                }
            }
        }
    }
}

// MARK: - Splash Screen
struct SplashView: View {
    @Binding var showSplash: Bool
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var vinylRotation: Double = 0
    
    var body: some View {
        ZStack {
            // Animated vinyl background
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "2D2D2D"), Color(hex: "1A1A1A")],
                        center: .center,
                        startRadius: 50,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .overlay(
                    // Vinyl grooves
                    ForEach(0..<8) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            .frame(width: CGFloat(80 + i * 25), height: CGFloat(80 + i * 25))
                    }
                )
                .overlay(
                    // Center label
                    Circle()
                        .fill(Color(hex: "FFD700"))
                        .frame(width: 60, height: 60)
                )
                .rotationEffect(.degrees(vinylRotation))
            
            VStack(spacing: 20) {
                Text("SCRATCH")
                    .font(.custom("Futura-Bold", size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "FFD700"), Color(hex: "FFA500")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                Text("LAB")
                    .font(.custom("Futura-Bold", size: 48))
                    .foregroundColor(.white)
                    .tracking(20)
                
                Text("MASTER THE ART")
                    .font(.custom("Futura-Medium", size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .tracking(8)
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)
        }
        .onAppear {
            // Animate vinyl spin
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                vinylRotation = 360
            }
            
            // Animate logo appearance
            withAnimation(.easeOut(duration: 0.8)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            
            // Transition to main menu
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(GameState())
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
}
