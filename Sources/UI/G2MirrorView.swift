import SwiftUI

/// True 1:1 (576x288) monochrome green live mirror rendering the exact G2PageSpec
/// (multi-container rounded cards + 4-bit 16-level pixel bitmap graphics).
struct G2MirrorView: View {
    let page: G2PageSpec
    let isConnected: Bool
    let isMicOn: Bool
    let alwaysOnActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("G2 디스플레이")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.6))

                if alwaysOnActive && isConnected {
                    Text("항시 유지")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.14))
                        .clipShape(Capsule())
                }

                Spacer()

                if isMicOn {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("MIC LIVE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                } else if page.isBlankTransparent {
                    Text("들어깨우기 대기")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.mint)
                } else {
                    Text("576×288")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            G2CanvasPreview(page: page, isConnected: isConnected, isMicOn: isMicOn, compact: false)
                .aspectRatio(2.0, contentMode: .fit)
        }
    }
}

/// Ultra-dim translucent 1:1 preview optionally toggled inside the fullscreen Motion Pad.
struct G2MiniMirrorStrip: View {
    let page: G2PageSpec
    let isMicOn: Bool

    var body: some View {
        G2CanvasPreview(page: page, isConnected: true, isMicOn: isMicOn, compact: true)
            .aspectRatio(2.0, contentMode: .fit)
            .opacity(0.86)
    }
}

private struct G2CanvasPreview: View {
    let page: G2PageSpec
    let isConnected: Bool
    let isMicOn: Bool
    let compact: Bool

    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / 576.0
            let sy = geo.size.height / 288.0

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.015, green: 0.05, blue: 0.025),
                                Color(red: 0.008, green: 0.03, blue: 0.015)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                            .stroke(
                                isMicOn
                                    ? Color.red.opacity(0.55)
                                    : (isConnected ? Color.green.opacity(0.45) : Color.white.opacity(0.12)),
                                lineWidth: 1.2
                            )
                    )

                if page.isBlankTransparent {
                    VStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                            .font(.title3)
                            .foregroundColor(.green.opacity(0.35))
                        Text("들어깨우기 투명 대기 중 (고개 들기 또는 터치)")
                            .font(.system(size: compact ? 9.5 : 11, design: .monospaced))
                            .foregroundColor(.green.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Render 4-bit pixel image containers
                    ForEach(page.imageContainers) { img in
                        G2BitmapPreview(image: img)
                            .frame(width: CGFloat(img.width) * sx, height: CGFloat(img.height) * sy)
                            .offset(x: CGFloat(img.x) * sx, y: CGFloat(img.y) * sy)
                    }

                    // Render multi-container text cards with Studio-grade proportional SF Pro typography & focus pills
                    ForEach(page.textContainers) { tc in
                        let isFocusedCard = tc.borderWidth >= 2
                        let borderOpacity = tc.borderWidth > 0 ? max(0.22, Double(tc.borderColor) / 15.0) : 0.0
                        let fontSize = max(7.5, (compact ? 10.2 : 12.6) * (geo.size.width / 360.0))

                        ZStack(alignment: .leading) {
                            if isFocusedCard {
                                RoundedRectangle(cornerRadius: CGFloat(tc.borderRadius) * sx, style: .continuous)
                                    .fill(Color(red: 0.22, green: 1.0, blue: 0.45).opacity(0.11))
                            } else if tc.borderWidth == 1 {
                                RoundedRectangle(cornerRadius: CGFloat(tc.borderRadius) * sx, style: .continuous)
                                    .fill(Color(red: 0.22, green: 1.0, blue: 0.45).opacity(0.05))
                            }

                            Text(tc.text)
                                .font(.system(size: fontSize, weight: isFocusedCard ? .semibold : .medium))
                                .foregroundColor(Color(red: 0.26, green: 1.0, blue: 0.48).opacity(isFocusedCard ? 1.0 : 0.84))
                                .lineSpacing(2.5)
                                .padding(.horizontal, CGFloat(tc.padding) * sx)
                                .padding(.vertical, CGFloat(max(2, tc.padding - 2)) * sy)
                                .frame(
                                    width: CGFloat(tc.width) * sx,
                                    height: CGFloat(tc.height) * sy,
                                    alignment: .topLeading
                                )
                                .clipped()

                            if isFocusedCard {
                                Capsule()
                                    .fill(Color(red: 0.30, green: 1.0, blue: 0.52))
                                    .frame(width: max(2.2, 3.5 * sx), height: max(8, CGFloat(tc.height - 20) * sy))
                                    .padding(.leading, 4 * sx)
                            }
                        }
                        .frame(width: CGFloat(tc.width) * sx, height: CGFloat(tc.height) * sy)
                        .overlay(
                            RoundedRectangle(cornerRadius: CGFloat(tc.borderRadius) * sx, style: .continuous)
                                .stroke(
                                    Color(red: 0.26, green: 1.0, blue: 0.48).opacity(isFocusedCard ? 0.45 : borderOpacity * 0.7),
                                    lineWidth: max(0, CGFloat(tc.borderWidth == 1 ? 1.0 : 0.8))
                                )
                        )
                        .offset(x: CGFloat(tc.x) * sx, y: CGFloat(tc.y) * sy)
                    }
                }
            }
        }
    }
}

/// Renders a 4-bit packed monochrome green G2ImageContainer directly in SwiftUI Canvas.
private struct G2BitmapPreview: View {
    let image: G2ImageContainer

    var body: some View {
        Canvas { context, size in
            let w = image.width
            let h = image.height
            guard w > 0, h > 0 else { return }
            let stride = (w + 1) / 2
            let bytes = Array(image.packed4bpp)
            guard bytes.count >= stride * h else { return }

            let pw = size.width / CGFloat(w)
            let ph = size.height / CGFloat(h)

            for r in 0..<h {
                for c in 0..<w {
                    let b = bytes[r * stride + (c / 2)]
                    let nibble = (c % 2 == 0) ? (b >> 4) : (b & 0x0F)
                    if nibble == 0 { continue }
                    let alpha = Double(nibble) / 15.0
                    let rect = CGRect(x: CGFloat(c) * pw, y: CGFloat(r) * ph, width: max(0.8, pw + 0.15), height: max(0.8, ph + 0.15))
                    context.fill(Path(rect), with: .color(Color(red: 0.26, green: 1.0, blue: 0.48).opacity(alpha)))
                }
            }
        }
    }
}
