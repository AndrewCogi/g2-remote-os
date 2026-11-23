import Foundation

/// A single text container on the 576x288 G2 EvenHub canvas.
/// Supports optional rounded borders (borderWidth 0..5, borderColor 0..16, borderRadius 0..10).
public struct G2TextContainer: Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let text: String
    public let captureEvents: Bool
    public let borderWidth: Int
    public let borderColor: Int
    public let borderRadius: Int
    public let padding: Int
    public let textColor: Int?

    public init(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        text: String,
        captureEvents: Bool = false,
        borderWidth: Int = 0,
        borderColor: Int = 0,
        borderRadius: Int = 0,
        padding: Int = 4,
        textColor: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.captureEvents = captureEvents
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.borderRadius = borderRadius
        self.padding = padding
        self.textColor = textColor
    }
}

/// A 4-bit (16-level monochrome green) pixel image container on the G2 EvenHub canvas.
/// Firmware constraints: width 20..288 (even recommended), height 20..144, max 4 per page.
public struct G2ImageContainer: Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// 4-bit packed greyscale bytes (2 pixels per byte, high nibble = left pixel).
    public let packed4bpp: Data
    /// Content hash/tag so BLE manager skips redundant 200-byte fragment uploads when image is unchanged.
    public let contentHash: String

    public init(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        packed4bpp: Data,
        contentHash: String
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.packed4bpp = packed4bpp
        self.contentHash = contentHash
    }
}

/// Full EvenHub page specification rendered simultaneously to the G2 glasses and the 1:1 iPhone mirror.
public struct G2PageSpec: Equatable {
    /// Structural layout signature; when equal to the active glasses layout, only text/image diffs are pushed.
    public let layoutKey: String
    public let textContainers: [G2TextContainer]
    public let imageContainers: [G2ImageContainer]
    public let isBlankTransparent: Bool
    /// Plain-text fallback summary for logs/accessibility.
    public let summaryText: String

    public init(
        layoutKey: String,
        textContainers: [G2TextContainer],
        imageContainers: [G2ImageContainer] = [],
        isBlankTransparent: Bool = false,
        summaryText: String = ""
    ) {
        self.layoutKey = layoutKey
        self.textContainers = textContainers
        self.imageContainers = imageContainers
        self.isBlankTransparent = isBlankTransparent
        self.summaryText = summaryText.isEmpty
            ? textContainers.map(\.text).joined(separator: "\n")
            : summaryText
    }

    public static func blankTransparent() -> G2PageSpec {
        G2PageSpec(
            layoutKey: "blank_transparent",
            textContainers: [
                G2TextContainer(
                    id: 1,
                    name: "blank",
                    x: 0,
                    y: 0,
                    width: 576,
                    height: 288,
                    text: " ",
                    captureEvents: true,
                    borderWidth: 0,
                    borderColor: 0,
                    borderRadius: 0,
                    padding: 0
                )
            ],
            imageContainers: [],
            isBlankTransparent: true,
            summaryText: ""
        )
    }
}

/// Pure-Swift 4-bit (16-level greyscale) pixel canvas and BMP encoder for EvenHub `cmd 3` image containers.
/// Byte-exact port of `open-g2-hub` `pack4bpp` & `encodeBmp4bpp` (Windows 4bpp bottom-up BMP with 16-level palette).
public final class G2PixelCanvas {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8] // 0..15 per pixel

    public init(width: Int, height: Int) {
        self.width = max(20, min(288, width))
        self.height = max(20, min(144, height))
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height)
    }

    public func setPixel(x: Int, y: Int, level: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let clamped = min(15, level)
        let idx = y * width + x
        if clamped > pixels[idx] {
            pixels[idx] = clamped
        }
    }

    public func fillRect(x: Int, y: Int, w: Int, h: Int, level: UInt8) {
        guard w > 0, h > 0 else { return }
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + w)
        let y1 = min(height, y + h)
        for py in y0..<y1 {
            for px in x0..<x1 {
                setPixel(x: px, y: py, level: level)
            }
        }
    }

    public func drawCircle(cx: Int, cy: Int, r: Int, level: UInt8, filled: Bool = true) {
        let r2 = r * r
        let innerR2 = max(0, (r - 2) * (r - 2))
        for dy in -r...r {
            for dx in -r...r {
                let d2 = dx * dx + dy * dy
                if d2 <= r2 {
                    if filled || d2 >= innerR2 {
                        setPixel(x: cx + dx, y: cy + dy, level: level)
                    }
                }
            }
        }
    }

    public func drawLine(x0: Int, y0: Int, x1: Int, y1: Int, thickness: Int = 2, level: UInt8 = 15) {
        let steps = max(1, max(abs(x1 - x0), abs(y1 - y0)))
        let half = max(0, thickness / 2)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let px = Int(round(Double(x0) + Double(x1 - x0) * t))
            let py = Int(round(Double(y0) + Double(y1 - y0) * t))
            fillRect(x: px - half, y: py - half, w: thickness, h: thickness, level: level)
        }
    }

    /// Renders crisp sleek geometric digital clock digits (e.g. "12:35") matching Even G2 dashboard style.
    public func drawBigClock(_ timeText: String, originX: Int, originY: Int, digitW: Int = 28, digitH: Int = 48, thickness: Int = 5, spacing: Int = 8, level: UInt8 = 15) {
        var cursorX = originX
        for ch in timeText {
            if ch == ":" {
                let dotSize = max(4, thickness)
                fillRect(x: cursorX + 2, y: originY + digitH / 3 - dotSize / 2, w: dotSize, h: dotSize, level: level)
                fillRect(x: cursorX + 2, y: originY + (digitH * 2) / 3 - dotSize / 2, w: dotSize, h: dotSize, level: level)
                cursorX += dotSize + spacing
            } else if let digit = Int(String(ch)) {
                drawSevenSegDigit(digit, x: cursorX, y: originY, w: digitW, h: digitH, t: thickness, level: level)
                cursorX += digitW + spacing
            } else {
                cursorX += digitW / 2
            }
        }
    }

    private func drawSevenSegDigit(_ digit: Int, x: Int, y: Int, w: Int, h: Int, t: Int, level: UInt8) {
        // Segments: a(top), b(topRight), c(botRight), d(bottom), e(botLeft), f(topLeft), g(middle)
        let masks: [UInt8] = [
            0b0111111, // 0
            0b0000110, // 1
            0b1011011, // 2
            0b1001111, // 3
            0b1100110, // 4
            0b1101101, // 5
            0b1111101, // 6
            0b0000111, // 7
            0b1111111, // 8
            0b1101111  // 9
        ]
        guard digit >= 0 && digit <= 9 else { return }
        let m = masks[digit]
        let midY = y + (h - t) / 2
        let halfH = (h - t) / 2
        let gap = 1

        // Horizontal segments with subtle bevel tips
        if (m & 0b0000001) != 0 { fillRect(x: x + gap, y: y, w: w - 2 * gap, h: t, level: level) } // a
        if (m & 0b0001000) != 0 { fillRect(x: x + gap, y: y + h - t, w: w - 2 * gap, h: t, level: level) } // d
        if (m & 0b1000000) != 0 { fillRect(x: x + gap, y: midY, w: w - 2 * gap, h: t, level: level) } // g

        // Vertical segments
        if (m & 0b0000010) != 0 { fillRect(x: x + w - t, y: y + gap, w: t, h: halfH, level: level) } // b
        if (m & 0b0000100) != 0 { fillRect(x: x + w - t, y: midY + gap, w: t, h: halfH, level: level) } // c
        if (m & 0b0100000) != 0 { fillRect(x: x, y: y + gap, w: t, h: halfH, level: level) } // f
        if (m & 0b0010000) != 0 { fillRect(x: x, y: midY + gap, w: t, h: halfH, level: level) } // e
    }

    /// Draws a crisp 4-bit weather glyph (sun, cloud, rain, snow, storm, night) inside a ~40x40 box.
    public func drawWeatherIcon(code: String, cx: Int, cy: Int) {
        switch code {
        case "sun":
            drawCircle(cx: cx, cy: cy, r: 8, level: 15, filled: true)
            let rays = [(0, -15), (0, 15), (-15, 0), (15, 0), (-11, -11), (11, -11), (-11, 11), (11, 11)]
            for (rx, ry) in rays {
                drawLine(x0: cx + rx * 2 / 3, y0: cy + ry * 2 / 3, x1: cx + rx, y1: cy + ry, thickness: 2, level: 12)
            }
        case "rain", "storm":
            drawCircle(cx: cx - 6, cy: cy - 3, r: 7, level: 13, filled: true)
            drawCircle(cx: cx + 4, cy: cy - 6, r: 9, level: 15, filled: true)
            drawCircle(cx: cx + 11, cy: cy - 2, r: 6, level: 12, filled: true)
            fillRect(x: cx - 10, y: cy - 2, w: 23, h: 6, level: 13)
            drawLine(x0: cx - 6, y0: cy + 7, x1: cx - 9, y1: cy + 14, thickness: 2, level: 14)
            drawLine(x0: cx + 1, y0: cy + 7, x1: cx - 2, y1: cy + 14, thickness: 2, level: 14)
            drawLine(x0: cx + 8, y0: cy + 7, x1: cx + 5, y1: cy + 14, thickness: 2, level: 14)
        case "snow":
            drawCircle(cx: cx - 5, cy: cy - 4, r: 7, level: 13, filled: true)
            drawCircle(cx: cx + 5, cy: cy - 6, r: 8, level: 15, filled: true)
            fillRect(x: cx - 9, y: cy - 3, w: 20, h: 5, level: 13)
            fillRect(x: cx - 8, y: cy + 7, w: 3, h: 3, level: 15)
            fillRect(x: cx, y: cy + 10, w: 3, h: 3, level: 15)
            fillRect(x: cx + 8, y: cy + 7, w: 3, h: 3, level: 15)
        default: // cloud / partly cloudy
            drawCircle(cx: cx - 7, cy: cy + 1, r: 7, level: 12, filled: true)
            drawCircle(cx: cx + 2, cy: cy - 4, r: 10, level: 15, filled: true)
            drawCircle(cx: cx + 11, cy: cy + 1, r: 7, level: 13, filled: true)
            fillRect(x: cx - 11, y: cy + 1, w: 25, h: 7, level: 14)
        }
    }

    /// Draws a horizontal battery gauge bar with percentage fill.
    public func drawBatteryBar(x: Int, y: Int, w: Int, h: Int, percent: Int) {
        let clamped = max(0, min(100, percent))
        // Outline
        fillRect(x: x, y: y, w: w, h: 2, level: 10)
        fillRect(x: x, y: y + h - 2, w: w, h: 2, level: 10)
        fillRect(x: x, y: y, w: 2, h: h, level: 10)
        fillRect(x: x + w - 2, y: y, w: 2, h: h, level: 10)
        // Battery cap
        fillRect(x: x + w, y: y + h / 4, w: 3, h: max(2, h / 2), level: 10)
        // Fill
        let innerW = max(0, w - 6)
        let fillW = (innerW * clamped) / 100
        if fillW > 0 {
            fillRect(x: x + 3, y: y + 3, w: fillW, h: max(1, h - 6), level: 15)
        }
    }

    /// Packs pixels to 4bpp (2 pixels per byte, high nibble = left pixel).
    public func pack4bpp() -> Data {
        Self.pack4bpp(pixels: pixels, width: width, height: height)
    }

    public static func pack4bpp(pixels: [UInt8], width: Int, height: Int) -> Data {
        let stride = (width + 1) / 2
        var out = Data(count: stride * height)
        for row in 0..<height {
            for col in 0..<width {
                let v = pixels[row * width + col] & 0x0F
                let i = row * stride + (col / 2)
                if col % 2 == 0 {
                    out[i] |= (v << 4)
                } else {
                    out[i] |= v
                }
            }
        }
        return out
    }

    /// Wraps 4bpp packed bytes into the Windows 4-bit bottom-up BMP expected by G2 firmware (`common_image_set_data`).
    public static func encodeBmp4bpp(packed: Data, width: Int, height: Int) -> Data {
        let srcStride = (width + 1) / 2
        guard packed.count == srcStride * height else { return Data() }
        let stride = ((srcStride + 3) / 4) * 4
        let pixelOffset = 14 + 40 + 64
        let totalSize = pixelOffset + stride * height

        var out = Data(count: totalSize)
        func writeU16(_ offset: Int, _ value: UInt16) {
            out[offset] = UInt8(value & 0xFF)
            out[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func writeU32(_ offset: Int, _ value: UInt32) {
            out[offset] = UInt8(value & 0xFF)
            out[offset + 1] = UInt8((value >> 8) & 0xFF)
            out[offset + 2] = UInt8((value >> 16) & 0xFF)
            out[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        // BITMAPFILEHEADER (14 bytes)
        out[0] = 0x42 // 'B'
        out[1] = 0x4D // 'M'
        writeU32(2, UInt32(totalSize))
        writeU32(10, UInt32(pixelOffset))

        // BITMAPINFOHEADER (40 bytes)
        writeU32(14, 40)
        writeU32(18, UInt32(bitPattern: Int32(width)))
        writeU32(22, UInt32(bitPattern: Int32(height)))
        writeU16(26, 1) // planes
        writeU16(28, 4) // 4 bpp
        writeU32(34, UInt32(stride * height))
        writeU32(38, 2835)
        writeU32(42, 2835)
        writeU32(46, 16)
        writeU32(50, 16)

        // 16-level greyscale palette (64 bytes at offset 54)
        for i in 0..<16 {
            let shade = UInt8(17 * i)
            out[54 + i * 4] = shade
            out[55 + i * 4] = shade
            out[56 + i * 4] = shade
            out[57 + i * 4] = 0
        }

        // Bottom-up row copy
        let packedBytes = Array(packed)
        for r in 0..<height {
            let dstStart = pixelOffset + (height - 1 - r) * stride
            let srcStart = r * srcStride
            for c in 0..<srcStride {
                out[dstStart + c] = packedBytes[srcStart + c]
            }
        }
        return out
    }
}
