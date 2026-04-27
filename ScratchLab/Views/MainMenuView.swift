// MainMenuView.swift
// ScratchLab - Main Menu
// Primary companion home for capture and monitoring

import SwiftUI
import UIKit
import Network

struct MainMenuView: View {
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var companionRelayBroadcaster: CompanionCameraBroadcaster
    @EnvironmentObject var watchMotionCaptureStore: WatchMotionCaptureStore
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var showingPracticeHub = false
    @State private var showingCompanionCam = false
    @State private var showingWatchCapture = false
    @State private var showingPerformerMonitor = false
    @State private var showingCoachPreview = false

    private var isIOSAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        headerView
                        systemStatusCard
                        menuButtons
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, geometry.safeAreaInsets.top + 12)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 16) + 28)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        #if DEBUG && canImport(RealityKit)
        .sheet(isPresented: $showingCoachPreview) {
            NavigationStack {
                CoachPreviewView()
            }
        }
        #endif
        .onAppear {
            if progressManager.playerProfile == nil {
                progressManager.createProfile(displayName: "New DJ")
            }
        }
        .navigationDestination(isPresented: $showingPracticeHub) {
            LevelSelectView()
        }
        .navigationDestination(isPresented: $showingCompanionCam) {
            if isIOSAppOnMac {
                UnsupportedCompanionCameraView()
            } else {
                CompanionCameraView()
            }
        }
        .navigationDestination(isPresented: $showingWatchCapture) {
            WatchCaptureHubView()
        }
        .navigationDestination(isPresented: $showingPerformerMonitor) {
            IPadPerformerMonitorView()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { showingProfile = true }) {
                HStack(spacing: 8) {
                    Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                        .font(.system(size: 22))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progressManager.playerProfile?.displayName ?? "New DJ")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text("Live practice")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "7DD3FC"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            
            VStack(spacing: 4) {
                Text("ScratchLab")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                Text("Practice + companion")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity)
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
    }

    private var systemStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LIVE INPUT READY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "7DD3FC"))

            Text("Run live scratch practice on this device with the microphone or a wired USB/interface input. You can also use it for deck video, performer monitor, and watch motion capture with ScratchLab on your main device.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.86))

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    StatusBadge(label: "Practice", value: "Live input", color: Color(hex: "22C55E"))
                    StatusBadge(label: "Audio", value: "Mic or USB", color: Color(hex: "0EA5E9"))
                }

                HStack(spacing: 8) {
                    StatusBadge(label: "Camera", value: "Deck video", color: Color(hex: "F59E0B"))
                    StatusBadge(label: "Sync", value: "Optional", color: Color(hex: "6366F1"))
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("WATCH RELAY")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "A78BFA"))

                Text(watchRelayStatusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    StatusBadge(
                        label: "Relay",
                        value: companionRelayBroadcaster.connectedPeerNames.isEmpty ? "Waiting for Mac" : "Mac linked",
                        color: companionRelayBroadcaster.connectedPeerNames.isEmpty ? Color(hex: "334155") : Color(hex: "22C55E")
                    )
                    StatusBadge(
                        label: "Watch",
                        value: watchMotionCaptureStore.isWatchReachable ? "Reachable" : "Not reachable",
                        color: watchMotionCaptureStore.isWatchReachable ? Color(hex: "22C55E") : Color(hex: "475569")
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: - Menu Buttons
    
    private var menuButtons: some View {
        VStack(spacing: 16) {
            MenuButton(
                title: "Live Practice",
                subtitle: "Pick a scratch and practice from mic or wired input",
                icon: "waveform",
                accent: Color(hex: "22C55E"),
                action: { showingPracticeHub = true }
            )

            MenuButton(
                title: "Companion Camera",
                subtitle: isIOSAppOnMac
                    ? "Use ScratchLabDesktop on Mac for capture. Companion Camera is for iPhone hardware."
                    : "Send deck video to your main device",
                icon: "iphone.gen3.radiowaves.left.and.right",
                accent: Color(hex: "F59E0B"),
                action: { showingCompanionCam = true }
            )

            MenuButton(
                title: "Performer Monitor",
                subtitle: performerMonitorSubtitle,
                icon: performerMonitorIcon,
                accent: Color(hex: "0EA5E9"),
                action: { showingPerformerMonitor = true }
            )

            MenuButton(
                title: "Watch Capture",
                subtitle: "Import wrist motion and relay it back to Mac capture",
                icon: "applewatch.side.right",
                accent: Color(hex: "6366F1"),
                action: { showingWatchCapture = true }
            )

            #if DEBUG && canImport(RealityKit)
            MenuButton(
                title: "Coach Preview",
                subtitle: "View coach animation and motion response",
                icon: "cube.transparent",
                accent: Color(hex: "8B5CF6"),
                action: { showingCoachPreview = true }
            )
            #endif
        }
    }

    private var performerMonitorSubtitle: String {
        "Receive deck view on this device"
    }

    private var performerMonitorIcon: String {
        UIDevice.current.userInterfaceIdiom == .pad
            ? "ipad.landscape.badge.play"
            : "iphone.badge.play"
    }

    private var watchRelayStatusText: String {
        if companionRelayBroadcaster.connectedPeerNames.isEmpty {
            return "The iPhone relay is active. Open ScratchLab on macOS and connect Companion Camera when you want watch motion files to bounce back to the Mac."
        }

        if watchMotionCaptureStore.isWatchReachable {
            return "Relay is live between Mac and Watch. Mac record commands can start watch capture, and imported watch motion will return through this iPhone."
        }

        return "Mac relay is connected, but the watch is not currently reachable. Keep the watch app open and the devices nearby for live motion capture."
    }
}

private struct UnsupportedCompanionCameraView: View {
    var body: some View {
        ZStack {
            BackgroundView()

            VStack(alignment: .leading, spacing: 16) {
                Text("Companion Camera Unavailable")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("This iOS app running on Mac does not support the iPhone companion-camera capture flow. Use the ScratchLab desktop app on macOS for camera capture and routine recording.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle("Companion Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Menu Button Component

struct MenuButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 48, height: 48)
                    .overlay {
                    Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(accent)
                    }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            )
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

// MARK: - Shared Stat Item Component

struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)

                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

struct StatusBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.56))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Background View

struct BackgroundView: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: "05070B"),
                Color(hex: "0B1018"),
                Color(hex: "101826")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
                        .font(.system(size: 28, weight: .bold))
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
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(hex: "FFD700"))
            Text(label)
                .font(.system(size: 12, weight: .medium))
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
                        ForEach(visibleInputSources, id: \.self) { source in
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
                            Text(appVersionLabel)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .onAppear {
                selectedInput = audioEngine.currentInputSource
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

    private var visibleInputSources: [AudioInputSource] {
        AudioInputSource.allCases.filter { $0 != .djApp }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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

private struct PerformerMonitorZonePacket: Codable, Identifiable {
    let role: String
    let title: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var id: String { role }
}

private struct PerformerMonitorFramePacket: Codable {
    let timestamp: TimeInterval
    let jpegData: Data
    let guidanceCue: String
    let guidanceDetail: String
    let scratchStatusTitle: String
    let rigStatusTitle: String
    let audioPercent: String
    let detectionCount: Int
    let highlightedZoneRole: String
    let zones: [PerformerMonitorZonePacket]
}

private final class IPadPerformerMonitorReceiver: NSObject, ObservableObject {
    struct MacSummary: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published var discoveredPeers: [MacSummary] = []
    @Published var connectedPeerNames: [String] = []
    @Published var connectionStatus = "Searching for nearby ScratchLab"
    @Published private(set) var latestFrameImage: UIImage?
    @Published private(set) var latestFramePacket: PerformerMonitorFramePacket?

    private let serviceType = "_scrmonfeed._tcp"
    private let defaultManualPort = NWEndpoint.Port(rawValue: 58585)!
    private let browserQueue = DispatchQueue(label: "scratchlab.ipad.performer.browser")
    private let decoder = PropertyListDecoder()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpointLookup: [String: NWEndpoint] = [:]
    private var attemptedAutoConnectPeerIDs: Set<String> = []
    private let maxFrameSize = 6_000_000

    override init() {
        super.init()
        startBrowsing()
    }

    deinit {
        browser?.cancel()
        connection?.cancel()
    }

    func refresh() {
        disconnect()
        discoveredPeers = []
        endpointLookup.removeAll()
        latestFrameImage = nil
        latestFramePacket = nil
        attemptedAutoConnectPeerIDs.removeAll()
        startBrowsing()
        connectionStatus = "Searching for nearby ScratchLab"
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connectedPeerNames = []
        latestFrameImage = nil
        latestFramePacket = nil
        connectionStatus = "Searching for nearby ScratchLab"
    }

    func connect(to peer: MacSummary) {
        guard let endpoint = endpointLookup[peer.id] else { return }
        connect(to: endpoint, displayName: peer.name)
    }

    func connect(hostname rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionStatus = "Enter the connection name shown in ScratchLab"
            return
        }

        let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let hostPart = String(pieces.first ?? "")
        let normalizedHost = normalizedManualHost(hostPart)
        let port = manualPort(from: pieces.count > 1 ? String(pieces[1]) : nil)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(normalizedHost), port: port)
        connect(to: endpoint, displayName: normalizedHost)
    }

    private func connect(to endpoint: NWEndpoint, displayName: String) {
        connection?.cancel()
        connectionStatus = "Connecting to \(displayName)"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .setup, .preparing:
                    self.connectionStatus = "Connecting to \(displayName)"
                case .ready:
                    self.connectedPeerNames = [displayName]
                    self.connectionStatus = "Connected to \(displayName)"
                    self.receiveNextFrameLength(on: connection, peerName: displayName)
                case .waiting(let error):
                    print("Performer monitor waiting for \(displayName): \(error.localizedDescription)")
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(displayName) paused. Check network."
                case .failed(let error):
                    print("Performer monitor connection failed for \(displayName): \(error.localizedDescription)")
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(displayName) lost."
                case .cancelled:
                    self.connectedPeerNames = []
                    self.connectionStatus = "Searching for nearby ScratchLab"
                @unknown default:
                    self.connectionStatus = "Performer monitor connection changed"
                }
            }
        }
        connection.start(queue: browserQueue)
    }

    private func normalizedManualHost(_ rawHost: String) -> String {
        let host = rawHost.lowercased()
        if host.hasSuffix(".local") || host.contains(".") {
            return host
        }
        return "\(host).local"
    }

    private func manualPort(from rawPort: String?) -> NWEndpoint.Port {
        guard let rawPort,
              let portValue = UInt16(rawPort),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            return defaultManualPort
        }
        return port
    }

    private func autoConnectIfNeeded() {
        guard connectedPeerNames.isEmpty else { return }
        guard discoveredPeers.count == 1, let onlyPeer = discoveredPeers.first else { return }
        guard !attemptedAutoConnectPeerIDs.contains(onlyPeer.id) else { return }

        attemptedAutoConnectPeerIDs.insert(onlyPeer.id)
        connect(to: onlyPeer)
    }

    private func startBrowsing() {
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if self.connectedPeerNames.isEmpty, self.discoveredPeers.isEmpty {
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                case .waiting(let error):
                    print("Performer monitor browse waiting: \(error.localizedDescription)")
                    self.connectionStatus = "Searching paused. Check network."
                case .failed(let error):
                    print("Performer monitor browse failed: \(error.localizedDescription)")
                    self.connectionStatus = "Unable to search for nearby device. Check network."
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let summaries = results.compactMap { result -> MacSummary? in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else {
                    return nil
                }
                let id = result.endpoint.debugDescription
                return MacSummary(id: id, name: name.isEmpty ? "ScratchLab" : name)
            }
            .sorted { $0.name < $1.name }

            let nextLookup = Dictionary(uniqueKeysWithValues: results.map { ($0.endpoint.debugDescription, $0.endpoint) })

            DispatchQueue.main.async {
                self.discoveredPeers = summaries
                self.endpointLookup = nextLookup
                if self.connectedPeerNames.isEmpty {
                    self.connectionStatus = summaries.isEmpty
                        ? "Searching for nearby ScratchLab"
                        : "Found \(summaries.count == 1 ? summaries[0].name : "\(summaries.count) nearby ScratchLab devices"). Connect when ready."
                }
                self.autoConnectIfNeeded()
            }
        }

        browser.start(queue: browserQueue)
    }

    private func receiveNextFrameLength(on connection: NWConnection, peerName: String) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("Performer monitor frame header receive failed for \(peerName): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(peerName) lost."
                }
                return
            }

            guard let data, data.count == 4 else {
                if isComplete {
                    DispatchQueue.main.async {
                        self.connectedPeerNames = []
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                }
                return
            }

            let frameLength = data.withUnsafeBytes { rawBuffer -> Int in
                let value = rawBuffer.load(as: UInt32.self)
                return Int(UInt32(bigEndian: value))
            }
            self.receiveFrameBody(length: frameLength, on: connection, peerName: peerName)
        }
    }

    private func receiveFrameBody(length: Int, on connection: NWConnection, peerName: String) {
        guard length > 0, length <= maxFrameSize else {
            DispatchQueue.main.async {
                self.connectedPeerNames = []
                self.connectionStatus = "Received an invalid frame from \(peerName)"
            }
            return
        }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("Performer monitor frame receive failed for \(peerName): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(peerName) lost."
                }
                return
            }

            guard let data,
                  let packet = try? self.decoder.decode(PerformerMonitorFramePacket.self, from: data),
              let image = UIImage(data: packet.jpegData) else {
                if isComplete {
                    DispatchQueue.main.async {
                        self.connectedPeerNames = []
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.latestFramePacket = packet
                self.latestFrameImage = image
                self.connectionStatus = "Connected to \(peerName)"
            }

            self.receiveNextFrameLength(on: connection, peerName: peerName)
        }
    }
}

private struct IPadPerformerMonitorView: View {
    @StateObject private var receiver = IPadPerformerMonitorReceiver()
    @State private var manualHost = ""

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    performerHeader

                    if let image = receiver.latestFrameImage,
                       let packet = receiver.latestFramePacket {
                        IPadPerformerMonitorStage(image: image, packet: packet)
                    } else {
                        emptyStateCard
                    }

                    controlRow
                }
                .padding(24)
            }
        }
        .navigationTitle("Performer Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            receiver.refresh()
        }
    }

    private var performerHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use this when you want ScratchLab feedback off the Serato screen.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.82))

            Label(receiver.connectionStatus, systemImage: receiver.connectedPeerNames.isEmpty ? "ipad.landscape" : "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(receiver.connectedPeerNames.isEmpty ? .white.opacity(0.78) : Color(hex: "4CAF50"))

            if !receiver.discoveredPeers.isEmpty && receiver.connectedPeerNames.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nearby ScratchLab")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.68))

                    ForEach(receiver.discoveredPeers) { peer in
                        HStack(spacing: 12) {
                            Text(peer.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)

                            Spacer()

                            Button("Connect") {
                                receiver.connect(to: peer)
                            }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(hex: "0EA5E9"))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                }
            }

            if receiver.connectedPeerNames.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Advanced connection")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.68))

                    HStack(spacing: 10) {
                        TextField("Device name or address", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)

                        Button("Connect") {
                            receiver.connect(hostname: manualHost)
                        }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: "0EA5E9"))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Text("Use this only if nearby discovery does not find ScratchLab.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(18)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting for nearby ScratchLab")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("1. Open ScratchLab on your main device running Serato.\n2. Stay on the analyzer screen or open Performer Monitor there.\n3. Keep both devices on the same local network.\n4. This screen will auto-connect when the nearby feed appears if it is the only one available.\n5. If Nearby ScratchLab stays empty, use Advanced connection.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            Text("If you are using an external display instead, move the Performer Monitor window there and you do not need this screen.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(20)
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button("Reconnect") {
                receiver.refresh()
            }
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(hex: "0EA5E9"))
            .foregroundColor(.white)
            .cornerRadius(14)

            Button("Disconnect") {
                receiver.disconnect()
            }
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.12))
            .foregroundColor(.white)
            .cornerRadius(14)

            Spacer()
        }
    }

}

private struct IPadPerformerMonitorStage: View {
    let image: UIImage
    let packet: PerformerMonitorFramePacket

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                ForEach(packet.zones) { zone in
                    zoneOverlay(zone, in: proxy.size)
                }

                VStack(alignment: .leading, spacing: 10) {
                    cuePill

                    HStack(spacing: 8) {
                        metricBadge(title: "Audio", value: packet.audioPercent)
                        metricBadge(title: "Matches", value: "\(packet.detectionCount)")
                    }
                }
                .padding(20)

                VStack(alignment: .leading, spacing: 6) {
                    Spacer()

                    Text(packet.scratchStatusTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text(packet.guidanceDetail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .aspectRatio(imageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
        .cornerRadius(20)
    }

    private var imageAspectRatio: CGFloat {
        let width = max(image.size.width, 1)
        let height = max(image.size.height, 1)
        return width / height
    }

    private var cuePill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(highlightColor(for: packet.highlightedZoneRole))
                .frame(width: 10, height: 10)

            Text(packet.guidanceCue)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.62))
        .cornerRadius(18)
        .frame(maxWidth: 320)
    }

    private func metricBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.58))

            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.62))
        .cornerRadius(14)
    }

    private func zoneOverlay(_ zone: PerformerMonitorZonePacket, in size: CGSize) -> some View {
        let zoneRect = CGRect(
            x: zone.minX * size.width,
            y: (1 - zone.minY - zone.height) * size.height,
            width: zone.width * size.width,
            height: zone.height * size.height
        )
        let isHighlighted = packet.highlightedZoneRole == zone.role
        let strokeColor = highlightColor(for: zone.role)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .stroke(strokeColor.opacity(isHighlighted ? 1 : 0.72), lineWidth: isHighlighted ? 4 : 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(strokeColor.opacity(isHighlighted ? 0.14 : 0.06))
                )

            Text(zone.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.72))
                .cornerRadius(12)
                .padding(10)
        }
        .frame(width: zoneRect.width, height: zoneRect.height)
        .position(x: zoneRect.midX, y: zoneRect.midY)
    }

    private func highlightColor(for role: String) -> Color {
        switch role {
        case "leftDeck":
            return Color(hex: "F59E0B")
        case "mixer":
            return Color(hex: "06B6D4")
        case "rightDeck":
            return Color(hex: "22C55E")
        default:
            return Color.white
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MainMenuView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            MainMenuView()
        }
        .environmentObject(GameState())
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
    }
}
#endif
