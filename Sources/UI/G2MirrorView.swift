import SwiftUI

/// Clean 2:1 (576x288) monochrome green display mirror matching the G2 optical waveguide.
struct G2MirrorView: View {
    let text: String
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
                } else {
                    Text("576×288")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.02, green: 0.055, blue: 0.03),
                                Color(red: 0.01, green: 0.035, blue: 0.018)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                isMicOn
                                    ? Color.red.opacity(0.55)
                                    : (isConnected ? Color.green.opacity(0.45) : Color.white.opacity(0.12)),
                                lineWidth: 1.2
                            )
                    )

                Text(text)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.26, green: 1.0, blue: 0.48))
                    .lineSpacing(4)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .aspectRatio(2.0, contentMode: .fit)
        }
    }
}

/// Ultra-dim translucent preview optionally toggled inside the fullscreen Motion Pad.
struct G2MiniMirrorStrip: View {
    let text: String
    let isMicOn: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.02, green: 0.06, blue: 0.03).opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isMicOn ? Color.red.opacity(0.5) : Color.green.opacity(0.32), lineWidth: 1)
                )

            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.28, green: 0.95, blue: 0.48).opacity(0.85))
                .lineSpacing(2.5)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .aspectRatio(2.15, contentMode: .fit)
    }
}
