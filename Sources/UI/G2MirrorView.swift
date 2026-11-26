import CoreGraphics
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
                    // Render 4-bit pixel image containers (hardware-accelerated CGImage, 1:1 Studio optical glow!)
                    ForEach(page.imageContainers) { img in
                        G2BitmapPreview(image: img)
                            .frame(width: CGFloat(img.width) * sx, height: CGFloat(img.height) * sy)
                            .offset(x: CGFloat(img.x) * sx, y: CGFloat(img.y) * sy)
                    }
                    .shadow(color: Color(red: 0.19, green: 1.0, blue: 0.48).opacity(0.36), radius: compact ? 2 : 3.5)

                    // Render non-empty text containers (skipped for invisible 1-space event-capture container)
                    ForEach(page.textContainers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { tc in
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
                                .lineSpacing(2.2)
                                .padding(.horizontal, CGFloat(tc.padding) * sx)
                                .padding(.vertical, CGFloat(max(2, tc.padding - 2)) * sy)
                                .frame(
                                    width: CGFloat(tc.width) * sx,
                                    height: CGFloat(tc.height) * sy,
                                    alignment: tc.height <= 56 ? .leading : .topLeading
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

/// Hardware-accelerated 4-bit monochrome green CGImage renderer (matches Studio HTML pixel-for-pixel at 60fps!).
private struct G2BitmapPreview: View {
    let image: G2ImageContainer

    var body: some View {
        if let cgImg = Self.makeCGImage(from: image) {
            Image(decorative: cgImg, scale: 1.0)
                .interpolation(.high)
                .resizable()
        }
    }

    private static func makeCGImage(from image: G2ImageContainer) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let stride = (w + 1) / 2
        guard image.packed4bpp.count >= stride * h else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        image.packed4bpp.withUnsafeBytes { rawIn in
            let src = rawIn.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let srcRow = y * stride
                let dstRow = y * w * 4
                for x in 0..<w {
                    let b = src[srcRow + (x >> 1)]
                    let nibble = (x & 1 == 0) ? Int(b >> 4) : Int(b & 0x0F)
                    if nibble == 0 { continue }
                    let level = Double(nibble) / 15.0
                    let r = UInt8(min(255, Int((45.0 * level).rounded())))
                    let g = UInt8(min(255, Int((255.0 * min(1.0, level * 1.1)).rounded())))
                    let bl = UInt8(min(255, Int((122.0 * level).rounded())))
                    let a = UInt8(min(255, Int((255.0 * min(1.0, level * 0.99)).rounded())))
                    let p = dstRow + x * 4
                    rgba[p]     = r
                    rgba[p + 1] = g
                    rgba[p + 2] = bl
                    rgba[p + 3] = a
                }
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
