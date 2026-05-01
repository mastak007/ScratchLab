import SwiftUI

struct HandMotionOverlay: View {
    @ObservedObject var detector: MacCaptureEngine

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let point = detector.handPosition, detector.handDetected {
                    let converted = CGPoint(x: point.x * proxy.size.width, y: (1 - point.y) * proxy.size.height)

                    Circle()
                        .fill(detector.handMotionState.color.opacity(0.18))
                        .frame(width: 84, height: 84)
                        .position(converted)

                    Circle()
                        .stroke(detector.handMotionState.color, lineWidth: 4)
                        .frame(width: 34, height: 34)
                        .position(converted)

                    HStack(spacing: 8) {
                        Image(systemName: detector.handMotionState.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(detector.handMotionState.title)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .position(
                        x: min(max(converted.x + 86, 90), proxy.size.width - 90),
                        y: min(max(converted.y - 42, 32), proxy.size.height - 32)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
