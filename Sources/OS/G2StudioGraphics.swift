import Foundation
#if canImport(UIKit)
import UIKit
import CoreGraphics
#endif

/// CoreGraphics 4-bit (16-level monochrome green) optical HUD graphic renderer matching our
/// minimalist G2 Spatial OS Studio design (`g2_spatial_os_studio.html`).
///
/// Generates compact, `contentHash`-cached `G2ImageContainer` tiles (each <= 288x144) so:
/// - Real Even Realities G2 glasses display smooth anti-aliased SF Pro UltraLight typography & vector icons.
/// - Scrolling text rows updates in ~28ms via differential `cmd 5` text upgrades without re-uploading bitmaps!
public enum G2StudioGraphics {

    // MARK: - 1. Home Hero Clock + Date & Weather (`288 x 136`, centered at x=144, y=28)

    public static func makeHomeClockImage(
        timeStr: String,
        dateStr: String,
        tempStr: String,
        weatherCode: String
    ) -> G2ImageContainer {
        let w = 288
        let h = 136
        let hash = "hclk_\(timeStr)_\(dateStr)_\(tempStr)_\(weatherCode)"

        #if canImport(UIKit)
        let packed = render4bpp(width: w, height: h) { ctx in
            // Giant SF Pro UltraLight centered clock (matching Studio 82px look scaled cleanly into 288x136)
            let clockAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 78, weight: .ultraLight),
                .foregroundColor: UIColor(white: 1.0, alpha: 1.0)
            ]
            let clockStr = NSAttributedString(string: timeStr, attributes: clockAttrs)
            let cSize = clockStr.size()
            clockStr.draw(at: CGPoint(x: (CGFloat(w) - cSize.width) / 2.0, y: 2))

            // Date · Weather Icon + Temp row below clock
            let metaY: CGFloat = 104
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .regular),
                .foregroundColor: UIColor(white: 11.0 / 15.0, alpha: 1.0)
            ]
            let dateNS = NSAttributedString(string: dateStr, attributes: dateAttrs)
            let dSize = dateNS.size()
            dateNS.draw(at: CGPoint(x: 132 - dSize.width, y: metaY - dSize.height / 2.0))

            // Center dot separator
            ctx.setFillColor(gray: 6.0 / 15.0, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: 144 - 2, y: metaY - 2, width: 4, height: 4))

            // Crisp vector weather icon
            drawWeatherGlyph(ctx: ctx, code: weatherCode, cx: 168, cy: metaY, size: 22)

            // Temperature
            let tempAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 19, weight: .medium),
                .foregroundColor: UIColor(white: 14.0 / 15.0, alpha: 1.0)
            ]
            let tempNS = NSAttributedString(string: tempStr, attributes: tempAttrs)
            let tSize = tempNS.size()
            tempNS.draw(at: CGPoint(x: 186, y: metaY - tSize.height / 2.0))
        }
        return G2ImageContainer(id: 10, name: "homeclk", x: 144, y: 26, width: w, height: h, packed4bpp: packed, contentHash: hash)
        #else
        let canvas = G2PixelCanvas(width: w, height: h)
        canvas.drawBigClock(timeStr, originX: 48, originY: 16, digitW: 32, digitH: 56, thickness: 5, spacing: 8, level: 15)
        canvas.drawWeatherIcon(code: weatherCode, cx: 168, cy: 104)
        return G2ImageContainer(id: 10, name: "homeclk", x: 144, y: 26, width: w, height: h, packed4bpp: canvas.pack4bpp(), contentHash: hash)
        #endif
    }

    // MARK: - 2. Top-Right Tailscale 9-Dot + Battery Gauge (`128 x 26`, at x=436, y=10)

    public static func makeTopStatusImage(
        tailscaleOn: Bool,
        sparkConnected: Bool,
        batteryPercent: Int,
        charging: Bool
    ) -> G2ImageContainer {
        let w = 128
        let h = 26
        let batBucket = max(0, min(100, batteryPercent))
        let hash = "tsbat_\(tailscaleOn ? 1 : 0)_\(sparkConnected ? 1 : 0)_\(batBucket)_\(charging ? 1 : 0)"

        #if canImport(UIKit)
        let packed = render4bpp(width: w, height: h) { ctx in
            // Tailscale 3x3 dot matrix (T highlighted when connected)
            let cx: CGFloat = 20
            let cy: CGFloat = 13
            let gap: CGFloat = 5.4
            for row in -1...1 {
                for col in -1...1 {
                    let isT = (row == 0) || (row == 1 && col == 0)
                    let level: CGFloat
                    if tailscaleOn {
                        level = isT ? (sparkConnected ? 15.0 / 15.0 : 12.0 / 15.0) : 5.0 / 15.0
                    } else {
                        level = isT ? 5.0 / 15.0 : 2.0 / 15.0
                    }
                    let rad: CGFloat = isT ? 1.85 : 1.4
                    ctx.setFillColor(gray: level, alpha: 1.0)
                    ctx.fillEllipse(in: CGRect(
                        x: cx + CGFloat(col) * gap - rad,
                        y: cy + CGFloat(row) * gap - rad,
                        width: rad * 2,
                        height: rad * 2
                    ))
                }
            }

            // Battery outline + terminal + fill
            let bx: CGFloat = 46
            let by: CGFloat = 7
            let bw: CGFloat = 24
            let bh: CGFloat = 12
            let outlinePath = UIBezierPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh), cornerRadius: 3)
            ctx.setStrokeColor(gray: 10.0 / 15.0, alpha: 1.0)
            ctx.setLineWidth(1.4)
            ctx.addPath(outlinePath.cgPath)
            ctx.strokePath()

            ctx.setFillColor(gray: 10.0 / 15.0, alpha: 1.0)
            ctx.fill(CGRect(x: bx + bw + 1.5, y: by + 3.5, width: 2.0, height: 5.0))

            let fillW = max(1.0, CGFloat(batBucket) / 100.0 * 19.0)
            let fillPath = UIBezierPath(roundedRect: CGRect(x: bx + 2.4, y: by + 2.4, width: fillW, height: 7.2), cornerRadius: 1.4)
            ctx.setFillColor(gray: 14.0 / 15.0, alpha: 1.0)
            ctx.addPath(fillPath.cgPath)
            ctx.fillPath()

            // Battery text ("85%")
            let pctStr = "\(charging ? "+" : "")\(batBucket)%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor(white: 11.0 / 15.0, alpha: 1.0)
            ]
            let ns = NSAttributedString(string: pctStr, attributes: attrs)
            let sz = ns.size()
            ns.draw(at: CGPoint(x: bx + 32, y: 13 - sz.height / 2.0))
        }
        return G2ImageContainer(id: 11, name: "tsbat", x: 436, y: 10, width: w, height: h, packed4bpp: packed, contentHash: hash)
        #else
        let canvas = G2PixelCanvas(width: w, height: h)
        canvas.drawBatteryBar(x: 46, y: 7, w: 26, h: 12, percent: batBucket)
        return G2ImageContainer(id: 11, name: "tsbat", x: 436, y: 10, width: w, height: h, packed4bpp: canvas.pack4bpp(), contentHash: hash)
        #endif
    }

    // MARK: - 3. Minimalist 8-Slot Bottom Dock (2 tiles x `256 x 64`, cached while scrolling!)

    public static func makeMenuDockTiles(
        selectedIdx: Int,
        dockFocused: Bool,
        slotCount: Int = 8
    ) -> [G2ImageContainer] {
        let tileW = 256
        let tileH = 64
        let dockY = 216
        let totalW = 512 // centered at x=32..544 on 576px canvas
        let spacing: CGFloat = 62
        let startX: CGFloat = CGFloat(totalW) / 2.0 - (CGFloat(slotCount - 1) * spacing) / 2.0
        let iconCenterY: CGFloat = 26

        #if canImport(UIKit)
        func renderHalf(tileIndex: Int, originX: Int, containerId: Int, name: String) -> G2ImageContainer {
            let hash = "dock_\(tileIndex)_\(selectedIdx)_\(dockFocused ? 1 : 0)_\(slotCount)"
            let packed = render4bpp(width: tileW, height: tileH) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: -CGFloat(tileIndex * tileW), y: 0)

                // Hairline above dock
                ctx.setStrokeColor(gray: 3.0 / 15.0, alpha: 1.0)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: 4, y: 1))
                ctx.addLine(to: CGPoint(x: CGFloat(totalW - 4), y: 1))
                ctx.strokePath()

                // 8 Slots
                for idx in 0..<slotCount {
                    let cx = startX + CGFloat(idx) * spacing
                    let sel = (idx == selectedIdx)
                    let isEmpty = (idx > 0)

                    if sel {
                        let pill = UIBezierPath(roundedRect: CGRect(x: cx - 23, y: iconCenterY - 20, width: 46, height: 40), cornerRadius: 12)
                        ctx.setFillColor(gray: (dockFocused ? 4.0 : 2.0) / 15.0, alpha: 1.0)
                        ctx.addPath(pill.cgPath)
                        ctx.fillPath()

                        let strokeLevel: CGFloat = isEmpty ? 9.0 : (dockFocused ? 15.0 : 8.0)
                        ctx.setStrokeColor(gray: strokeLevel / 15.0, alpha: 1.0)
                        ctx.setLineWidth(dockFocused ? 1.8 : 1.1)
                        ctx.addPath(pill.cgPath)
                        ctx.strokePath()
                    }

                    if !isEmpty {
                        // Slot #1: Crisp ✦ Compass vector icon
                        let iconLevel: CGFloat = sel ? (dockFocused ? 15.0 : 12.0) : 9.0
                        drawCompassGlyph(ctx: ctx, cx: cx, cy: iconCenterY, size: sel ? 22 : 18, level: iconLevel / 15.0)
                    } else {
                        // Slots #2..#8: Clean minimalist dashed placeholder box
                        ctx.saveGState()
                        let box = UIBezierPath(roundedRect: CGRect(x: cx - 7.5, y: iconCenterY - 7.5, width: 15, height: 15), cornerRadius: 4)
                        ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
                        ctx.setStrokeColor(gray: (sel ? 10.0 : 5.0) / 15.0, alpha: 1.0)
                        ctx.setLineWidth(1.2)
                        ctx.addPath(box.cgPath)
                        ctx.strokePath()
                        ctx.restoreGState()
                    }
                }

                // Bottom horizontal indicator track
                let trackX: CGFloat = 136
                let trackW: CGFloat = 240
                let trackY: CGFloat = 56
                let trackPath = UIBezierPath(roundedRect: CGRect(x: trackX, y: trackY, width: trackW, height: 3), cornerRadius: 1.5)
                ctx.setFillColor(gray: 4.0 / 15.0, alpha: 1.0)
                ctx.addPath(trackPath.cgPath)
                ctx.fillPath()

                let thumbW = trackW / CGFloat(max(1, slotCount))
                let denom = CGFloat(max(1, slotCount - 1))
                let thumbX = trackX + (trackW - thumbW) * (CGFloat(selectedIdx) / denom)
                let thumbPath = UIBezierPath(roundedRect: CGRect(x: thumbX, y: trackY, width: thumbW, height: 3), cornerRadius: 1.5)
                ctx.setFillColor(gray: 14.0 / 15.0, alpha: 1.0)
                ctx.addPath(thumbPath.cgPath)
                ctx.fillPath()

                ctx.restoreGState()
            }
            return G2ImageContainer(id: containerId, name: name, x: originX, y: dockY, width: tileW, height: tileH, packed4bpp: packed, contentHash: hash)
        }

        return [
            renderHalf(tileIndex: 0, originX: 32, containerId: 12, name: "dockL"),
            renderHalf(tileIndex: 1, originX: 288, containerId: 13, name: "dockR")
        ]
        #else
        let leftCanvas = G2PixelCanvas(width: tileW, height: tileH)
        let rightCanvas = G2PixelCanvas(width: tileW, height: tileH)
        leftCanvas.drawCircle(cx: 38, cy: 26, r: 9, level: 15, filled: false)
        return [
            G2ImageContainer(id: 12, name: "dockL", x: 32, y: dockY, width: tileW, height: tileH, packed4bpp: leftCanvas.pack4bpp(), contentHash: "dockL_\(selectedIdx)_\(dockFocused)"),
            G2ImageContainer(id: 13, name: "dockR", x: 288, y: dockY, width: tileW, height: tileH, packed4bpp: rightCanvas.pack4bpp(), contentHash: "dockR_\(selectedIdx)_\(dockFocused)")
        ]
        #endif
    }

    // MARK: - CoreGraphics 4bpp Helpers

    #if canImport(UIKit)
    private static func render4bpp(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
        var grayBytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        grayBytes.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }

            // Flip coordinate system to top-left origin so UIKit NSAttributedString & paths match Canvas 2D!
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
        }

        // Pack 8-bit grayscale (0..255) -> 4-bit nibbles (0..15, 2 pixels/byte, high nibble = left)
        let stride = (width + 1) / 2
        var packed = Data(count: stride * height)
        packed.withUnsafeMutableBytes { outRaw in
            let out = outRaw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let rowOff = y * width
                let outOff = y * stride
                var x = 0
                while x < width {
                    let hi = UInt8((Int(grayBytes[rowOff + x]) * 15 + 127) / 255)
                    let lo: UInt8
                    if x + 1 < width {
                        lo = UInt8((Int(grayBytes[rowOff + x + 1]) * 15 + 127) / 255)
                    } else {
                        lo = 0
                    }
                    out[outOff + (x >> 1)] = (hi << 4) | lo
                    x += 2
                }
            }
        }
        return packed
    }

    private static func drawCompassGlyph(ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: CGFloat) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: level, alpha: 1.0)
        ctx.setFillColor(gray: level, alpha: 1.0)
        ctx.setLineWidth(max(1.6, size * 0.08))
        ctx.strokeEllipse(in: CGRect(x: cx - r * 0.88, y: cy - r * 0.88, width: r * 1.76, height: r * 1.76))

        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx + r * 0.44, y: cy - r * 0.44))
        ctx.addLine(to: CGPoint(x: cx + r * 0.14, y: cy + r * 0.14))
        ctx.addLine(to: CGPoint(x: cx - r * 0.44, y: cy + r * 0.44))
        ctx.addLine(to: CGPoint(x: cx - r * 0.14, y: cy - r * 0.14))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawWeatherGlyph(ctx: CGContext, code: String, cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: 14.0 / 15.0, alpha: 1.0)
        ctx.setFillColor(gray: 14.0 / 15.0, alpha: 1.0)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)

        switch code {
        case "rain", "storm":
            ctx.fillEllipse(in: CGRect(x: cx - 8, y: cy - 6, width: 10, height: 10))
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: cy - 9, width: 12, height: 12))
            ctx.fill(CGRect(x: cx - 6, y: cy - 1, width: 14, height: 4))
            for ox: CGFloat in [-4.0, 1.0, 6.0] {
                ctx.move(to: CGPoint(x: cx + ox, y: cy + 5))
                ctx.addLine(to: CGPoint(x: cx + ox - 2, y: cy + 9))
            }
            ctx.strokePath()
        case "cloud", "cloudy", "snow":
            ctx.fillEllipse(in: CGRect(x: cx - 9, y: cy - 3, width: 10, height: 10))
            ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy - 7, width: 12, height: 12))
            ctx.fillEllipse(in: CGRect(x: cx + 3, y: cy - 3, width: 9, height: 9))
            ctx.fill(CGRect(x: cx - 6, y: cy + 2, width: 15, height: 5))
        default: // sun
            ctx.fillEllipse(in: CGRect(x: cx - r * 0.44, y: cy - r * 0.44, width: r * 0.88, height: r * 0.88))
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4.0
                ctx.move(to: CGPoint(x: cx + cos(a) * r * 0.68, y: cy + sin(a) * r * 0.68))
                ctx.addLine(to: CGPoint(x: cx + cos(a) * r * 0.96, y: cy + sin(a) * r * 0.96))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
    #endif
}
