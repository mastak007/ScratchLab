import SwiftUI

struct WatchCaptureHubView: View {
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore
    @EnvironmentObject private var broadcaster: CompanionCameraBroadcaster
    @AppStorage("localNetworkRationaleAccepted") private var localNetworkRationaleAccepted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SCRATCHLAB COMPANION")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.textAccent)

                Text(presentation.title)
                    .font(ScratchLabDesign.Typo.display)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                Text(presentation.subtitle)
                    .font(ScratchLabDesign.Typo.bodyDefault)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                stateContent
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ScratchLabDesign.Surface.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            watchMotionCaptureStore.activateIfNeeded()
            if localNetworkRationaleAccepted {
                broadcaster.startRelayAdvertisingIfNeeded()
            }
            watchMotionCaptureStore.updateMacConnection(isConnected: !broadcaster.connectedPeerNames.isEmpty)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch presentation.state {
        case .waiting:
            waitingStateContent
        case .ready:
            relayStatusCard(title: "Apple Watch", badge: .connected, detail: "Watch motion source detected.")
            relayStatusCard(title: "Mac ScratchLab", badge: .connected, detail: "Mac capture host detected.")
            relayStatusCard(title: "Motion Relay", badge: .ready, detail: "Ready. Recording can proceed without watch if needed.")
            relayPath("WATCH → iPHONE → MAC")
            footer("Watch is optional; the Mac remains the capture authority.")
        case .active:
            relayStatusCard(title: "Apple Watch", badge: .connected, detail: "Receiving wrist motion.")
            relayStatusCard(title: "Mac ScratchLab", badge: .connected, detail: "Connected to active capture host.")
            relayStatusCard(title: "Motion Relay", badge: .active, detail: "Relaying watch motion for the active take.")
            if let context = watchMotionCaptureStore.activeRelayContext {
                relayPath("SESSION: \(context.sessionID)\nTAKE: \(context.takeID)\nWRIST: \(context.watchWrist?.uppercased() ?? "NOT SET")")
            }
            footer("If the relay drops, the take continues and received motion is preserved.")
        case .interrupted:
            relayStatusCard(
                title: "Connection",
                badge: .failed,
                detail: watchMotionCaptureStore.relayInterruptionReason
                    ?? "Watch or Mac relay connection was lost."
            )
            Button("Retry Connection") {
                localNetworkRationaleAccepted = true
                broadcaster.startRelayAdvertisingIfNeeded()
                watchMotionCaptureStore.retryRelayConnection()
            }
            .font(ScratchLabDesign.Typo.buttonPrimary)
            .foregroundStyle(ScratchLabDesign.Sem.textOnAccent)
            .frame(width: 160, height: 44)
            .background(ScratchLabDesign.Sem.accent, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control))
            .buttonStyle(.plain)

            Text("Retry the relay when ready. Do not restart the take just for missing Watch motion.")
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("WATCH OPTIONAL · CAPTURE CONTINUES")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
        }
    }

    @ViewBuilder
    private var waitingStateContent: some View {
        let watchConnected = watchMotionCaptureStore.isWatchReachable
        let macConnected = !broadcaster.connectedPeerNames.isEmpty

        relayStatusCard(
            title: "Apple Watch",
            badge: watchConnected ? .connected : .waiting,
            detail: watchConnected
                ? "Watch motion source detected."
                : "No Apple Watch connected."
        )
        relayStatusCard(
            title: "Mac ScratchLab",
            badge: macConnected ? .connected : .waiting,
            detail: macConnected
                ? "Mac capture host detected."
                : "Waiting for ScratchLab Capture on the Mac."
        )
        if watchConnected != macConnected {
            relayStatusCard(
                title: "Motion Relay",
                badge: .waiting,
                detail: watchConnected
                    ? "Waiting for Mac capture authority."
                    : "Watch motion is unavailable; capture remains available."
            )
        }
        relayPath(presentation.waitingRoute)
        footer(presentation.waitingFooter)
    }

    private var presentation: RelayPresentation {
        RelayPresentation(
            state: watchMotionCaptureStore.relayState,
            isWatchConnected: watchMotionCaptureStore.isWatchReachable,
            isMacConnected: !broadcaster.connectedPeerNames.isEmpty
        )
    }

    private func relayStatusCard(title: String, badge: RelayBadge, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Spacer()
                badgeView(badge)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScratchLabDesign.Surface.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ScratchLabDesign.Border.default, lineWidth: 1))
    }

    private func badgeView(_ badge: RelayBadge) -> some View {
        HStack(spacing: 6) {
            Circle().fill(badge.color).frame(width: 6, height: 6)
            Text(badge.label)
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(badge.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ScratchLabDesign.Surface.surface, in: Capsule())
        .overlay(Capsule().stroke(badge.color, lineWidth: 1))
    }

    private func relayPath(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            .lineLimit(3)
            .truncationMode(.middle)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
    }

    private struct RelayPresentation {
        let state: WatchRelayFlowState
        let isWatchConnected: Bool
        let isMacConnected: Bool

        var title: String {
            switch state {
            case .waiting:
                switch (isWatchConnected, isMacConnected) {
                case (true, false): return "Waiting for Mac"
                case (false, true): return "Watch Optional"
                default: return "Watch Relay"
                }
            case .ready: return "Relay Ready"
            case .active: return "Take in Progress"
            case .interrupted: return "Relay Interrupted"
            }
        }

        var subtitle: String {
            switch state {
            case .waiting:
                switch (isWatchConnected, isMacConnected) {
                case (true, false):
                    return "Apple Watch is connected. Waiting for ScratchLab Capture on the Mac."
                case (false, true):
                    return "The Mac capture host is connected. A DJ can start and complete a take without an Apple Watch."
                default:
                    return "Watch optional. Capturing can continue without watch motion."
                }
            case .ready:
                return "Everything is connected. Leave the iPhone unlocked with this screen open during capture."
            case .active:
                return "Motion is being relayed to the active ScratchLab take on the Mac."
            case .interrupted:
                return "Watch motion relay was interrupted. The Mac capture continues and received motion is preserved."
            }
        }

        var waitingRoute: String {
            switch (isWatchConnected, isMacConnected) {
            case (true, false): return "WATCH → iPHONE → MAC (WAITING)"
            case (false, true): return "MAC CAPTURE READY · WATCH OPTIONAL"
            default: return "WATCH (OPTIONAL) → iPHONE → MAC"
            }
        }

        var waitingFooter: String {
            switch (isWatchConnected, isMacConnected) {
            case (true, false): return "The Mac can still capture without this Watch relay."
            case (false, true): return "Recording remains available; only wrist motion is absent."
            default: return "No camera recording happens on this iPhone."
            }
        }
    }

    private enum RelayBadge {
        case waiting, connected, ready, active, failed

        var label: String {
            switch self {
            case .waiting: return "WAITING"
            case .connected: return "CONNECTED"
            case .ready: return "READY"
            case .active: return "ACTIVE"
            case .failed: return "FAILED"
            }
        }

        var color: Color {
            switch self {
            case .waiting: return ScratchLabDesign.Sem.textWarning
            case .connected: return ScratchLabDesign.Sem.textAccent
            case .ready: return ScratchLabDesign.Sem.textStatusReady
            case .active, .failed: return ScratchLabDesign.Sem.textError
            }
        }
    }
}
