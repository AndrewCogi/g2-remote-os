import SwiftUI

/// Live 2:1 (576x288) monochrome green preview mirroring exactly what is pushed to the G2 display.
struct G2MirrorView: View {
    let text: String
    let isAsleep: Bool
    let isMicOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("G2 디스플레이 미러 (576×288)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                if isMicOn {
                    Text("● LC3 MIC LIVE")
                        .font(.caption2.bold().monospaced())
                        .foregroundColor(.red)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.02, green: 0.06, blue: 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isAsleep ? Color.gray.opacity(0.35) : Color.green.opacity(0.55), lineWidth: 1.5)
                    )

                if isAsleep {
                    VStack(spacing: 6) {
                        Image(systemName: "zzz")
                            .font(.title2)
                            .foregroundColor(.green.opacity(0.35))
                        Text("G2 화면 절전 중 — 아무 버튼이나 눌러 깨우기")
                            .font(.caption.monospaced())
                            .foregroundColor(.green.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(text)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(red: 0.25, green: 1.0, blue: 0.45))
                        .lineSpacing(3)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .aspectRatio(2.0, contentMode: .fit)
        }
    }
}
