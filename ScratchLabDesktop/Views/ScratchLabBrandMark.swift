import SwiftUI

struct ScratchLabBrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width
            let center = CGPoint(x: s / 2, y: s / 2)
            let r = s * 0.46

            let outerRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let outerRing = Path(ellipseIn: outerRect)

            // Outer record ring
            ctx.stroke(outerRing, with: .color(Color(white: 0.28)), lineWidth: s * 0.04)

            // Inner groove ring
            let grooveR = r * 0.60
            let grooveRing = Path(ellipseIn: CGRect(
                x: center.x - grooveR, y: center.y - grooveR,
                width: grooveR * 2, height: grooveR * 2
            ))
            ctx.stroke(grooveRing, with: .color(Color(white: 0.22)), lineWidth: s * 0.018)

            // Center hub
            let hubR = s * 0.09
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)),
                with: .color(Color(white: 0.18))
            )

            // Scratch trace — clipped to record circle via drawLayer
            ctx.drawLayer { layerCtx in
                layerCtx.clip(to: outerRing)
                var trace = Path()
                trace.move(to: CGPoint(x: s * 0.20, y: s * 0.76))
                trace.addLine(to: CGPoint(x: s * 0.80, y: s * 0.24))
                layerCtx.stroke(trace, with: .color(Color(red: 0.20, green: 0.88, blue: 0.55)), lineWidth: s * 0.06)
            }

            // Subtle grid cues — clipped to record circle
            ctx.drawLayer { layerCtx in
                layerCtx.clip(to: outerRing)
                var grid = Path()
                grid.move(to: CGPoint(x: s * 0.36, y: center.y - grooveR))
                grid.addLine(to: CGPoint(x: s * 0.36, y: center.y + grooveR))
                grid.move(to: CGPoint(x: s * 0.64, y: center.y - grooveR))
                grid.addLine(to: CGPoint(x: s * 0.64, y: center.y + grooveR))
                layerCtx.stroke(grid, with: .color(Color(white: 0.50).opacity(0.28)), lineWidth: s * 0.016)
            }
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 24) {
        ScratchLabBrandMark(size: 24)
        ScratchLabBrandMark(size: 36)
        ScratchLabBrandMark(size: 56)
        ScratchLabBrandMark(size: 80)
    }
    .padding(32)
    .background(Color.black)
}
#endif
