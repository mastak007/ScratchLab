import SwiftUI

struct ScratchLabBrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image(decorative: "ScratchLabLogo")
            .resizable()
            .scaledToFit()
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
