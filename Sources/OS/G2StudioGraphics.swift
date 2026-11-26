import Foundation
#if canImport(UIKit)
import UIKit
import CoreGraphics
#endif

/// Pixel-for-pixel CoreGraphics 4-bit (16-level monochrome green) port of `g2_spatial_os_studio.html`.
///
/// Renders the entire `576 x 288` G2 optical display into an anti-aliased 16-level grayscale buffer
/// and slices it into 4 permanent `288 x 144` tiles (`id: 10, 11, 12, 13`) with per-tile FNV-1a
/// content hashes so `G2BLEManager` skips unchanged tiles automatically without `cmd 7` layout rebuilds.
public enum G2StudioGraphics {
    public static let canvasW = 576
    public static let canvasH = 288
    public static let tileW = 288
    public static let tileH = 144

    #if canImport(UIKit)
    private typealias DrawCtx = CGContext
    #else
    private typealias DrawCtx = Void
    #endif

    public struct RenderContext {
        public let timeStr: String
        public let dateStr: String
        public let tempStr: String
        public let weatherCode: String
        public let batteryPercent: Int
        public let charging: Bool
        public let tailscaleConnected: Bool
        public let sparkConnected: Bool
        public let aiListening: Bool
        public let voiceSearchMode: Bool
        public let livePartialSTT: String

        public init(
            timeStr: String,
            dateStr: String,
            tempStr: String,
            weatherCode: String,
            batteryPercent: Int,
            charging: Bool,
            tailscaleConnected: Bool,
            sparkConnected: Bool,
            aiListening: Bool,
            voiceSearchMode: Bool,
            livePartialSTT: String
        ) {
            self.timeStr = timeStr
            self.dateStr = dateStr
            self.tempStr = tempStr
            self.weatherCode = weatherCode
            self.batteryPercent = batteryPercent
            self.charging = charging
            self.tailscaleConnected = tailscaleConnected
            self.sparkConnected = sparkConnected
            self.aiListening = aiListening
            self.voiceSearchMode = voiceSearchMode
            self.livePartialSTT = livePartialSTT
        }
    }

    // MARK: - Full-Screen 4-Tile Page Builders (100% Pixel-Identical to Studio HTML!)

    public static func renderHomePage(
        rc: RenderContext,
        alerts: [G2AlertItem],
        recArticles: [G2FeedArticle]
    ) -> G2PageSpec {
        let summary: String
        if rc.aiListening {
            summary = "\(rc.timeStr) \(rc.dateStr) \(rc.tempStr)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
        } else if let a = alerts.first {
            summary = "\(rc.timeStr) \(rc.dateStr) \(rc.tempStr)\n\(a.sender) \(a.preview)"
        } else if let art = recArticles.first {
            summary = "\(rc.timeStr) \(rc.dateStr) \(rc.tempStr)\n\(art.category) \(art.title)"
        } else {
            summary = "\(rc.timeStr) \(rc.dateStr) \(rc.tempStr)"
        }

        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            let hasAlerts = !alerts.isEmpty
            let count = hasAlerts ? alerts.count : recArticles.count

            drawTailscale(ctx, cx: 466, cy: 22, on: rc.tailscaleConnected, spark: rc.sparkConnected)
            drawBattery(ctx, x: 492, y: 16, pct: rc.batteryPercent, charging: rc.charging)

            // Giant SF Pro UltraLight centered clock (82pt)
            drawText(
                ctx, rc.timeStr,
                x: 288, y: 106,
                font: .systemFont(ofSize: 82, weight: .ultraLight),
                level: 15, align: .center, baseline: .alphabetic
            )

            // Date · Sun/Weather Icon + Temperature
            let metaY: CGFloat = 142
            drawText(
                ctx, rc.dateStr,
                x: 268, y: metaY,
                font: .systemFont(ofSize: 18, weight: .regular),
                level: 11, align: .right, baseline: .middle
            )
            fillCircle(ctx, cx: 286, cy: metaY, r: 2, level: 5)
            drawWeatherGlyph(ctx, code: rc.weatherCode, cx: 312, cy: metaY, size: 23, level: 14)
            drawText(
                ctx, rc.tempStr,
                x: 332, y: metaY + 1,
                font: .systemFont(ofSize: 19, weight: .medium),
                level: 14, align: .left, baseline: .middle
            )

            // Bottom Peek Pill or Live AI Listening Pill
            if rc.aiListening {
                fillStrokeRoundedRect(ctx, x: 46, y: 206, w: 484, h: 46, r: 23, fillLevel: 2, strokeLevel: 14, lineWidth: 1.5)
                drawAgyIcon(ctx, cx: 74, cy: 229, size: 17, level: 15)
                drawMiniBars(ctx, x: 92, cy: 229, count: 5, maxH: 16)
                let liveStr = rc.livePartialSTT.isEmpty ? "듣는 중..." : "“\(rc.livePartialSTT)”"
                let font = UIFont.systemFont(ofSize: 15, weight: .regular)
                drawText(ctx, clip(liveStr, font: font, maxW: 382), x: 132, y: 229, font: font, level: 14, align: .left, baseline: .middle)
            } else if count > 0 {
                let lead: String
                let bodyText: String
                let iconKind: String
                if hasAlerts, let first = alerts.first {
                    iconKind = first.source
                    lead = first.sender
                    bodyText = first.preview
                } else {
                    let first = recArticles[0]
                    iconKind = "feed"
                    lead = first.category
                    bodyText = first.title
                }

                fillStrokeRoundedRect(ctx, x: 46, y: 200, w: 484, h: 46, r: 23, fillLevel: 2, strokeLevel: hasAlerts ? 9 : 7, lineWidth: 1.2)
                drawGlyph(ctx, kind: iconKind, cx: 74, cy: 223, size: 17, level: hasAlerts ? 15 : 13)

                let leadFont = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
                let textFont = UIFont.systemFont(ofSize: 13.5, weight: .regular)
                drawText(ctx, lead, x: 94, y: 223, font: leadFont, level: 15, align: .left, baseline: .middle)
                let sw = measureWidth(lead, font: leadFont)
                let avail = max(40, 530 - (104 + sw) - (count > 1 ? 56 : 20))
                drawText(ctx, clip(bodyText, font: textFont, maxW: avail), x: 104 + sw, y: 223, font: textFont, level: 12, align: .left, baseline: .middle)

                if count > 1 {
                    fillRoundedRect(ctx, x: 484, y: 212, w: 34, h: 22, r: 11, level: 4)
                    drawText(
                        ctx, "+\(count - 1)",
                        x: 501, y: 223.5,
                        font: .monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                        level: 13, align: .center, baseline: .middle
                    )
                }

                // Subtle downward chevron cue
                strokePolyline(ctx, points: [CGPoint(x: 278, y: 258), CGPoint(x: 288, y: 265), CGPoint(x: 298, y: 258)], level: 8, lineWidth: 1.6)
            }
            #endif
        }
    }

    public static func renderAlertsPage(
        rc: RenderContext,
        alerts: [G2AlertItem],
        stackIdx: Int
    ) -> G2PageSpec {
        let count = alerts.count
        let baseSummary = count == 0
            ? "알림 0건"
            : "\(alerts[min(stackIdx, count - 1)].sender): \(alerts[min(stackIdx, count - 1)].preview)"
        let summary = rc.aiListening
            ? "\(baseSummary)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
            : baseSummary

        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            let onClearAll = (count > 0 && stackIdx == count)

            drawBellIcon(ctx, cx: 30, cy: 22, size: 15, level: 13)
            let cntText = count > 0 ? (onClearAll ? "\(count)/\(count)" : "\(stackIdx + 1)/\(count)") : "0"
            drawText(ctx, cntText, x: 46, y: 22.5, font: .monospacedSystemFont(ofSize: 13, weight: .semibold), level: 13, align: .left, baseline: .middle)

            if !rc.aiListening {
                drawText(ctx, rc.timeStr, x: 442, y: 22.5, font: .monospacedSystemFont(ofSize: 14, weight: .regular), level: 10, align: .right, baseline: .middle)
                drawTailscale(ctx, cx: 466, cy: 22, on: rc.tailscaleConnected, spark: rc.sparkConnected)
                drawBattery(ctx, x: 492, y: 16, pct: rc.batteryPercent, charging: rc.charging)
            }

            if count == 0 {
                strokeCircle(ctx, cx: 288, cy: 134, r: 24, level: 11, lineWidth: 2.0)
                strokePolyline(ctx, points: [CGPoint(x: 278, y: 134), CGPoint(x: 285, y: 142), CGPoint(x: 300, y: 126)], level: 11, lineWidth: 2.0)
            } else {
                let displayIdx = onClearAll ? count - 1 : min(stackIdx, count - 1)
                let cur = alerts[displayIdx]
                let cardFocused = !onClearAll

                fillRoundedRect(ctx, x: 32, y: 52, w: 512, h: 124, r: 15, level: cardFocused ? 3 : 1)
                if cardFocused {
                    fillRoundedRect(ctx, x: 37, y: 64, w: 3.5, h: 100, r: 1.8, level: 15)
                }
                drawGlyph(ctx, kind: cur.source, cx: 66, cy: 82, size: 20, level: cardFocused ? 15 : 11)
                drawText(ctx, cur.sender, x: 90, y: 82, font: .systemFont(ofSize: 16, weight: .semibold), level: cardFocused ? 15 : 11, align: .left, baseline: .middle)
                drawText(ctx, cur.timeLabel, x: 524, y: 82, font: .monospacedSystemFont(ofSize: 12, weight: .regular), level: cardFocused ? 10 : 8, align: .right, baseline: .middle)
                let prevFont = UIFont.systemFont(ofSize: 15, weight: .regular)
                drawText(ctx, clip(cur.preview, font: prevFont, maxW: 456), x: 56, y: 126, font: prevFont, level: cardFocused ? 13 : 9, align: .left, baseline: .middle)

                if displayIdx + 1 < count {
                    let nxt = alerts[displayIdx + 1]
                    fillRoundedRect(ctx, x: 32, y: 188, w: 512, h: 68, r: 13, level: 1)
                    drawGlyph(ctx, kind: nxt.source, cx: 66, cy: 222, size: 18, level: 11)
                    drawText(ctx, nxt.sender, x: 90, y: 210, font: .systemFont(ofSize: 15, weight: .medium), level: 12, align: .left, baseline: .middle)
                    let nxtFont = UIFont.systemFont(ofSize: 13.5, weight: .regular)
                    drawText(ctx, clip(nxt.preview, font: nxtFont, maxW: 424), x: 90, y: 234, font: nxtFont, level: 9, align: .left, baseline: .middle)
                } else {
                    fillStrokeRoundedRect(ctx, x: 216, y: 202, w: 144, h: 36, r: 18, fillLevel: onClearAll ? 4 : 1, strokeLevel: onClearAll ? 15 : 7, lineWidth: onClearAll ? 1.8 : 1.0)
                    drawText(ctx, "× 모두 지우기", x: 288, y: 220.5, font: .systemFont(ofSize: 13, weight: onClearAll ? .semibold : .regular), level: onClearAll ? 15 : 10, align: .center, baseline: .middle)
                }
            }

            if rc.aiListening { drawTopListeningPill(ctx, rc: rc) }
            #endif
        }
    }

    public static func renderMenuPage(
        rc: RenderContext,
        slotIdx: Int,
        menuFocus: Int,
        recArticles: [G2FeedArticle]
    ) -> G2PageSpec {
        let isFeed = (slotIdx == 0)
        let baseSummary = isFeed
            ? "피드 (\(menuFocus < 0 ? "독" : "\(menuFocus + 1)/\(recArticles.count)"))"
            : "슬롯 \(slotIdx + 1)/8"
        let summary = rc.aiListening
            ? "\(baseSummary)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
            : baseSummary

        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            let onDock = (menuFocus < 0)
            let slotCount = 8

            if isFeed {
                drawCompassIcon(ctx, cx: 31, cy: 21, size: 16, level: 15)
                drawText(ctx, "피드", x: 49, y: 21.5, font: .systemFont(ofSize: 14.5, weight: .semibold), level: 15, align: .left, baseline: .middle)
                if !onDock && !recArticles.isEmpty {
                    drawText(ctx, "\(menuFocus + 1)/\(recArticles.count)", x: 86, y: 21.5, font: .monospacedSystemFont(ofSize: 12, weight: .medium), level: 9, align: .left, baseline: .middle)
                }
            } else {
                drawText(ctx, "\(slotIdx + 1)/\(slotCount)", x: 28, y: 21.5, font: .monospacedSystemFont(ofSize: 13, weight: .medium), level: 9, align: .left, baseline: .middle)
            }

            if !rc.aiListening {
                drawText(ctx, rc.timeStr, x: 442, y: 21.5, font: .monospacedSystemFont(ofSize: 13.5, weight: .regular), level: 10, align: .right, baseline: .middle)
                drawTailscale(ctx, cx: 466, cy: 21, on: rc.tailscaleConnected, spark: rc.sparkConnected)
                drawBattery(ctx, x: 492, y: 15, pct: rc.batteryPercent, charging: rc.charging)
            }

            // Upper Preview Stage: 2 Equally-Bright Balanced 71px Rows
            if isFeed && !recArticles.isEmpty {
                let total = recArticles.count
                let focusIdx = max(-1, min(total - 1, menuFocus))
                let maxViewTop = max(0, total - 2)
                let viewTop = focusIdx < 0 ? 0 : min(focusIdx, maxViewTop)
                let rowH: CGFloat = 71

                for pos in 0..<min(2, total) {
                    let idx = viewTop + pos
                    let rowY: CGFloat = 44 + CGFloat(pos) * (rowH + 6)
                    drawBalancedFeedRow(ctx, article: recArticles[idx], numIndex: idx, y: rowY, h: rowH, focused: idx == focusIdx, showOutlet: false)
                    if pos == 0 && total > 1 && idx != focusIdx && (idx + 1) != focusIdx {
                        strokeLine(ctx, x0: 42, y0: rowY + rowH + 3, x1: 536, y1: rowY + rowH + 3, level: 3, lineWidth: 1)
                    }
                }

                if total > 2 && focusIdx >= 0 {
                    let tx: CGFloat = 558, ty: CGFloat = 46, th: CGFloat = 144
                    fillRoundedRect(ctx, x: tx, y: ty, w: 3, h: th, r: 1.5, level: 3)
                    let thumbH = max(26, th / CGFloat(total))
                    let thumbY = ty + (th - thumbH) * (CGFloat(focusIdx) / CGFloat(max(1, total - 1)))
                    fillRoundedRect(ctx, x: tx, y: thumbY, w: 3, h: thumbH, r: 1.5, level: 13)
                }
            } else {
                drawText(ctx, "슬롯 \(slotIdx + 1)", x: 288, y: 120, font: .systemFont(ofSize: 15, weight: .medium), level: 8, align: .center, baseline: .middle)
            }

            // Micro hairline above 8-slot dock
            strokeLine(ctx, x0: 36, y0: 199, x1: 540, y1: 199, level: 3, lineWidth: 1)

            // 8-Slot Minimalist Bottom Dock
            let spacing: CGFloat = 62
            let startX: CGFloat = 288 - (CGFloat(slotCount - 1) * spacing) / 2.0
            let dockY: CGFloat = 236

            for idx in 0..<slotCount {
                let cx = startX + CGFloat(idx) * spacing
                let sel = (idx == slotIdx)
                let empty = (idx > 0)
                if sel {
                    fillStrokeRoundedRect(
                        ctx, x: cx - 23, y: dockY - 21, w: 46, h: 42, r: 13,
                        fillLevel: onDock ? 4 : 2,
                        strokeLevel: empty ? 9 : (onDock ? 15 : 8),
                        lineWidth: onDock ? 1.8 : 1.1
                    )
                }
                if !empty {
                    drawCompassIcon(ctx, cx: cx, cy: dockY, size: sel ? 22 : 18, level: sel ? (onDock ? 15 : 12) : 9)
                } else {
                    strokeDashedRoundedRect(ctx, x: cx - 7.5, y: dockY - 7.5, w: 15, h: 15, r: 4, level: sel ? 10 : 5, lineWidth: 1.2)
                }
            }

            // Bottom horizontal dock scrollbar
            let trackX: CGFloat = 168, trackW: CGFloat = 240, trackY: CGFloat = 274
            let thumbW = trackW / CGFloat(slotCount)
            let thumbX = trackX + (trackW - thumbW) * (CGFloat(slotIdx) / CGFloat(slotCount - 1))
            fillRoundedRect(ctx, x: trackX, y: trackY, w: trackW, h: 3, r: 1.5, level: 4)
            fillRoundedRect(ctx, x: thumbX, y: trackY, w: thumbW, h: 3, r: 1.5, level: 14)

            if rc.aiListening { drawTopListeningPill(ctx, rc: rc) }
            #endif
        }
    }

    public static func renderFeedAppPage(
        rc: RenderContext,
        categories: [G2FeedCategory],
        catIdx: Int,
        catFocus: Int,
        searchQuery: String
    ) -> G2PageSpec {
        let safeCatIdx = max(0, min(max(0, categories.count - 1), catIdx))
        let cat = categories.isEmpty ? G2FeedCategory(id: "rec", label: "추천", articles: []) : categories[safeCatIdx]
        let items = cat.articles
        let total = items.count
        let focus = max(0, min(max(0, total - 1), catFocus))
        let baseSummary = "\(cat.label) \(total > 0 ? "\(focus + 1)/\(total)" : "0")"
        let summary = rc.aiListening
            ? "\(baseSummary)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
            : baseSummary

        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            var tabX: CGFloat = 26
            for (idx, tab) in categories.enumerated() {
                let active = (idx == safeCatIdx)
                let font = UIFont.systemFont(ofSize: active ? 13.5 : 13, weight: active ? .semibold : .medium)
                let w = measureWidth(tab.label, font: font)
                if active {
                    fillRoundedRect(ctx, x: tabX - 6, y: 8, w: w + 12, h: 24, r: 8, level: 3)
                    fillRoundedRect(ctx, x: tabX, y: 34, w: w, h: 2.4, r: 1.2, level: 15)
                }
                drawText(ctx, tab.label, x: tabX, y: 20, font: font, level: active ? 15 : 9, align: .left, baseline: .middle)
                tabX += w + 18
            }

            if !rc.aiListening {
                if total > 0 {
                    drawText(ctx, "\(focus + 1)/\(total)", x: 468, y: 20, font: .monospacedSystemFont(ofSize: 12, weight: .medium), level: 9, align: .right, baseline: .middle)
                }
                drawBattery(ctx, x: 492, y: 14, pct: rc.batteryPercent, charging: rc.charging)
            }

            strokeLine(ctx, x0: 24, y0: 41, x1: 548, y1: 41, level: 3, lineWidth: 1)

            var startY: CGFloat = 48
            let isSearch = (cat.id == "search")
            if isSearch {
                let qStr = searchQuery.isEmpty ? "전체" : searchQuery
                let sFont = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
                drawText(ctx, clip("⌕ “\(qStr)”  ·  \(total)건", font: sFont, maxW: 510), x: 30, y: 58, font: sFont, level: 13, align: .left, baseline: .middle)
                strokeLine(ctx, x0: 24, y0: 71, x1: 548, y1: 71, level: 3, lineWidth: 1)
                startY = 78
            }

            let visibleCount = min(isSearch ? 2 : 3, total)
            let maxViewTop = max(0, total - visibleCount)
            let viewTop = min(focus, maxViewTop)
            let rowH: CGFloat = isSearch ? 76 : 71
            let rowGap: CGFloat = 6

            for pos in 0..<visibleCount {
                let idx = viewTop + pos
                let rowY = startY + CGFloat(pos) * (rowH + rowGap)
                drawBalancedFeedRow(ctx, article: items[idx], numIndex: idx, y: rowY, h: rowH, focused: idx == focus, showOutlet: true)
                if pos < visibleCount - 1 && idx != focus && (idx + 1) != focus {
                    strokeLine(ctx, x0: 42, y0: rowY + rowH + 3, x1: 536, y1: rowY + rowH + 3, level: 3, lineWidth: 1)
                }
            }

            if total > 1 {
                let tx: CGFloat = 558, ty = startY + 2, th = 274 - ty
                fillRoundedRect(ctx, x: tx, y: ty, w: 3, h: th, r: 1.5, level: 3)
                let thumbH = max(26, th / CGFloat(total))
                let thumbY = ty + (th - thumbH) * (CGFloat(focus) / CGFloat(max(1, total - 1)))
                fillRoundedRect(ctx, x: tx, y: thumbY, w: 3, h: thumbH, r: 1.5, level: 13)
            }

            if rc.aiListening { drawTopListeningPill(ctx, rc: rc) }
            #endif
        }
    }

    public static func renderReaderPage(
        rc: RenderContext,
        iconKind: String,
        headerLeft: String,
        headerRight: String,
        lines: [String],
        scrollOffset: Int,
        isNewsTitleOnLine0: Bool
    ) -> G2PageSpec {
        let baseSummary = "\(headerLeft)\n\(lines.prefix(2).joined(separator: " "))"
        let summary = rc.aiListening
            ? "\(baseSummary)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
            : baseSummary
        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            let detailLines = 6
            drawGlyph(ctx, kind: iconKind, cx: 33, cy: 24, size: 17, level: 15)
            let hlFont = UIFont.systemFont(ofSize: 15.5, weight: .semibold)
            drawText(ctx, clip(headerLeft, font: hlFont, maxW: 340), x: 52, y: 24.5, font: hlFont, level: 15, align: .left, baseline: .middle)

            if !rc.aiListening {
                drawText(ctx, headerRight, x: 548, y: 24.5, font: .monospacedSystemFont(ofSize: 12, weight: .regular), level: 9, align: .right, baseline: .middle)
            }
            strokeLine(ctx, x0: 24, y0: 46, x1: 548, y1: 46, level: 3, lineWidth: 1)

            let total = lines.count
            let maxScroll = max(0, total - detailLines)
            let safeScroll = max(0, min(maxScroll, scrollOffset))
            let slice = Array(lines.dropFirst(safeScroll).prefix(detailLines))

            if safeScroll > 0 {
                strokePolyline(ctx, points: [CGPoint(x: 281, y: 59), CGPoint(x: 288, y: 54), CGPoint(x: 295, y: 59)], level: 8, lineWidth: 1.4)
            }

            for (i, line) in slice.enumerated() {
                if line.isEmpty { continue }
                let isTitle = (isNewsTitleOnLine0 && safeScroll == 0 && i == 0)
                let isSection = (line.hasPrefix("[") && line.hasSuffix("]")) || line.first?.isNumber == true && line.dropFirst().hasPrefix(".")
                let font: UIFont
                let level: Int
                if isTitle {
                    font = .systemFont(ofSize: 17, weight: .semibold)
                    level = 15
                } else if isSection {
                    font = .monospacedSystemFont(ofSize: 13.5, weight: .semibold)
                    level = 14
                } else {
                    font = .systemFont(ofSize: 15, weight: .regular)
                    level = (i == slice.count - 1 && safeScroll < maxScroll) ? 9 : 13
                }
                drawText(ctx, clip(line, font: font, maxW: 506), x: 28, y: 84 + CGFloat(i) * 33, font: font, level: level, align: .left, baseline: .alphabetic)
            }

            if safeScroll < maxScroll {
                strokePolyline(ctx, points: [CGPoint(x: 281, y: 270), CGPoint(x: 288, y: 276), CGPoint(x: 295, y: 270)], level: 10, lineWidth: 1.5)
            }
            if maxScroll > 0 {
                fillRoundedRect(ctx, x: 558, y: 60, w: 3, h: 206, r: 1.5, level: 3)
                let th = max(28, 206 * CGFloat(detailLines) / CGFloat(max(1, total)))
                let ty = 60 + (206 - th) * (CGFloat(safeScroll) / CGFloat(maxScroll))
                fillRoundedRect(ctx, x: 558, y: ty, w: 3, h: th, r: 1.5, level: 13)
            }

            if rc.aiListening { drawTopListeningPill(ctx, rc: rc) }
            #endif
        }
    }

    public static func renderAIReplyPage(
        rc: RenderContext,
        question: String,
        answerLines: [String],
        scrollOffset: Int
    ) -> G2PageSpec {
        let baseSummary = "\(question)\n\(answerLines.joined(separator: "\n"))"
        let summary = rc.aiListening
            ? "\(baseSummary)\n\(rc.livePartialSTT.isEmpty ? "듣는 중..." : rc.livePartialSTT)"
            : baseSummary
        return buildFourTilePage(summary: summary) { ctx in
            #if canImport(UIKit)
            drawAgyIcon(ctx, cx: 30, cy: 22, size: 16, level: 15)
            let qFont = UIFont.systemFont(ofSize: 14, weight: .medium)
            drawText(ctx, clip(question, font: qFont, maxW: 370), x: 48, y: 22.5, font: qFont, level: 11, align: .left, baseline: .middle)
            if !rc.aiListening {
                drawTailscale(ctx, cx: 466, cy: 22, on: rc.tailscaleConnected, spark: rc.sparkConnected)
                drawBattery(ctx, x: 492, y: 16, pct: rc.batteryPercent, charging: rc.charging)
            }
            strokeLine(ctx, x0: 24, y0: 46, x1: 548, y1: 46, level: 3, lineWidth: 1)

            let visible = 5
            let maxOff = max(0, answerLines.count - visible)
            let safeOff = max(0, min(maxOff, scrollOffset))
            let slice = Array(answerLines.dropFirst(safeOff).prefix(visible))

            for (i, line) in slice.enumerated() {
                let font = UIFont.systemFont(ofSize: 16.5, weight: (i == 0 && safeOff == 0) ? .medium : .regular)
                drawText(ctx, clip(line, font: font, maxW: 504), x: 28, y: 86 + CGFloat(i) * 38, font: font, level: (i == 0 && safeOff == 0) ? 15 : 13, align: .left, baseline: .alphabetic)
            }

            if maxOff > 0 {
                fillRoundedRect(ctx, x: 558, y: 60, w: 3, h: 206, r: 1.5, level: 3)
                let th = max(28, 206 * CGFloat(visible) / CGFloat(max(1, answerLines.count)))
                let ty = 60 + (206 - th) * (CGFloat(safeOff) / CGFloat(maxOff))
                fillRoundedRect(ctx, x: 558, y: ty, w: 3, h: th, r: 1.5, level: 13)
            }

            if rc.aiListening { drawTopListeningPill(ctx, rc: rc) }
            #endif
        }
    }

    // MARK: - Core 576x288 Buffer -> 4 Permanent 288x144 Tiles (FNV-1a Dirty Diff!)

    private static func buildFourTilePage(
        summary: String,
        draw: (DrawCtx) -> Void
    ) -> G2PageSpec {
        #if canImport(UIKit)
        var gray = [UInt8](repeating: 0, count: canvasW * canvasH)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        gray.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: canvasW,
                      height: canvasH,
                      bitsPerComponent: 8,
                      bytesPerRow: canvasW,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            ctx.translateBy(x: 0, y: CGFloat(canvasH))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
        }

        let tiles: [(id: Int, name: String, x: Int, y: Int)] = [
            (10, "tTL", 0, 0),
            (11, "tTR", tileW, 0),
            (12, "tBL", 0, tileH),
            (13, "tBR", tileW, tileH)
        ]

        let imageContainers: [G2ImageContainer] = tiles.map { t in
            let packed = packTile4bpp(from: gray, originX: t.x, originY: t.y, width: tileW, height: tileH)
            let hash = "\(t.name)_\(fnv1aHex(packed))"
            return G2ImageContainer(
                id: t.id, name: t.name,
                x: t.x, y: t.y, width: tileW, height: tileH,
                packed4bpp: packed, contentHash: hash
            )
        }
        #else
        let emptyTile = Data(count: (tileW / 2) * tileH)
        let summaryTag = fnv1aHex(Data(summary.utf8))
        let imageContainers: [G2ImageContainer] = [
            G2ImageContainer(id: 10, name: "tTL", x: 0, y: 0, width: tileW, height: tileH, packed4bpp: emptyTile, contentHash: "tTL_\(summaryTag)"),
            G2ImageContainer(id: 11, name: "tTR", x: tileW, y: 0, width: tileW, height: tileH, packed4bpp: emptyTile, contentHash: "tTR_\(summaryTag)"),
            G2ImageContainer(id: 12, name: "tBL", x: 0, y: tileH, width: tileW, height: tileH, packed4bpp: emptyTile, contentHash: "tBL_\(summaryTag)"),
            G2ImageContainer(id: 13, name: "tBR", x: tileW, y: tileH, width: tileW, height: tileH, packed4bpp: emptyTile, contentHash: "tBR_\(summaryTag)")
        ]
        #endif

        // Single invisible captureEvents container so EvenHub keeps session alive & receives temple events
        let eventCapture = G2TextContainer(
            id: 1, name: "evt", x: 0, y: 0, width: 20, height: 20,
            text: " ", captureEvents: true, borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 0
        )

        return G2PageSpec(
            layoutKey: "studio_4tile_v1",
            textContainers: [eventCapture],
            imageContainers: imageContainers,
            isBlankTransparent: false,
            summaryText: summary
        )
    }

    private static func packTile4bpp(from fullGray: [UInt8], originX: Int, originY: Int, width: Int, height: Int) -> Data {
        let stride = (width + 1) / 2
        var packed = Data(count: stride * height)
        packed.withUnsafeMutableBytes { outRaw in
            let out = outRaw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let srcRow = (originY + y) * canvasW + originX
                let dstRow = y * stride
                var x = 0
                while x < width {
                    let hi = UInt8((Int(fullGray[srcRow + x]) * 15 + 127) / 255)
                    let lo: UInt8 = (x + 1 < width) ? UInt8((Int(fullGray[srcRow + x + 1]) * 15 + 127) / 255) : 0
                    out[dstRow + (x >> 1)] = (hi << 4) | lo
                    x += 2
                }
            }
        }
        return packed
    }

    private static func fnv1aHex(_ data: Data) -> String {
        var h: UInt64 = 14695981039346656037
        for b in data {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(format: "%016llx", h)
    }

    // MARK: - Studio Canvas 2D Drawing Primitives (1:1 Match with HTML)

    #if canImport(UIKit)
    private enum TextAlign { case left, center, right }
    private enum TextBaseline { case middle, alphabetic }

    private static func gVal(_ level: Int) -> CGFloat {
        CGFloat(max(0, min(15, level))) / 15.0
    }

    private static func measureWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func clip(_ text: String, font: UIFont, maxW: CGFloat) -> String {
        if measureWidth(text, font: font) <= maxW { return text }
        var s = text
        while s.count > 1 && measureWidth(s + "…", font: font) > maxW {
            s.removeLast()
        }
        return s + "…"
    }

    private static func drawText(
        _ ctx: CGContext,
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        font: UIFont,
        level: Int,
        align: TextAlign,
        baseline: TextBaseline
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: gVal(level), alpha: 1.0)
        ]
        let ns = NSAttributedString(string: text, attributes: attrs)
        let sz = ns.size()
        let drawX: CGFloat
        switch align {
        case .left: drawX = x
        case .center: drawX = x - sz.width / 2.0
        case .right: drawX = x - sz.width
        }
        let drawY: CGFloat
        switch baseline {
        case .middle: drawY = y - sz.height / 2.0
        case .alphabetic: drawY = y - font.ascender
        }
        ns.draw(at: CGPoint(x: drawX, y: drawY))
    }

    private static func fillRoundedRect(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, level: Int) {
        ctx.saveGState()
        let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func fillStrokeRoundedRect(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, fillLevel: Int, strokeLevel: Int, lineWidth: CGFloat) {
        ctx.saveGState()
        let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        ctx.setFillColor(gray: gVal(fillLevel), alpha: 1.0)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor(gray: gVal(strokeLevel), alpha: 1.0)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokeDashedRoundedRect(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, level: Int, lineWidth: CGFloat) {
        ctx.saveGState()
        let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokeLine(_ ctx: CGContext, x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, level: Int, lineWidth: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: x0, y: y0))
        ctx.addLine(to: CGPoint(x: x1, y: y1))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokePolyline(_ ctx: CGContext, points: [CGPoint], level: Int, lineWidth: CGFloat) {
        guard points.count >= 2 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fillCircle(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, level: Int) {
        ctx.saveGState()
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    private static func strokeCircle(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, level: Int, lineWidth: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    // MARK: - Studio Balanced Feed Row (Exact 1:1 Match!)

    private static func drawBalancedFeedRow(
        _ ctx: CGContext,
        article: G2FeedArticle,
        numIndex: Int,
        y: CGFloat,
        h: CGFloat,
        focused: Bool,
        showOutlet: Bool
    ) {
        let x: CGFloat = 24, w: CGFloat = 522
        if focused {
            fillRoundedRect(ctx, x: x, y: y, w: w, h: h, r: 11, level: 3)
            fillRoundedRect(ctx, x: x + 5, y: y + 11, w: 3.5, h: h - 22, r: 1.8, level: 15)
        }

        let tx = x + 18
        let meta = showOutlet ? "\(article.outlet) · \(article.timeLabel)" : "\(article.category) · \(article.timeLabel)"
        let metaFont = UIFont.monospacedSystemFont(ofSize: focused ? 11.5 : 11, weight: focused ? .medium : .regular)
        let rightEdge = focused ? (x + w - 26) : (x + w - 12)
        drawText(ctx, meta, x: rightEdge, y: y + 23, font: metaFont, level: focused ? 11 : 9, align: .right, baseline: .middle)
        let metaW = measureWidth(meta, font: metaFont)

        if focused {
            strokePolyline(
                ctx,
                points: [CGPoint(x: x + w - 16, y: y + 18), CGPoint(x: x + w - 11, y: y + 23), CGPoint(x: x + w - 16, y: y + 28)],
                level: 14, lineWidth: 1.8
            )
        }

        let numStr = String(format: "%02d", numIndex + 1)
        drawText(ctx, numStr, x: tx, y: y + 23.5, font: .monospacedSystemFont(ofSize: 11.5, weight: .semibold), level: focused ? 12 : 9, align: .left, baseline: .middle)

        let titleFont = UIFont.systemFont(ofSize: focused ? 16 : 15.5, weight: focused ? .semibold : .medium)
        let titleAvail = max(120, (rightEdge - metaW - 12) - (tx + 24))
        drawText(ctx, clip(article.title, font: titleFont, maxW: titleAvail), x: tx + 24, y: y + 23, font: titleFont, level: focused ? 15 : 12, align: .left, baseline: .middle)

        let snipFont = UIFont.systemFont(ofSize: 13.5, weight: .regular)
        drawText(ctx, clip(article.snippet, font: snipFont, maxW: w - 34), x: tx, y: y + 51, font: snipFont, level: focused ? 13 : 10, align: .left, baseline: .middle)
    }

    // MARK: - Top Listening Pill & Studio Vector Icons

    private static func drawTopListeningPill(_ ctx: CGContext, rc: RenderContext) {
        ctx.saveGState()
        ctx.setFillColor(gray: 0, alpha: 1.0)
        ctx.fill(CGRect(x: 174, y: 3, width: 398, height: 36))
        ctx.restoreGState()

        fillStrokeRoundedRect(ctx, x: 180, y: 5, w: 376, h: 32, r: 16, fillLevel: 3, strokeLevel: 15, lineWidth: 1.4)
        if rc.voiceSearchMode {
            drawCompassIcon(ctx, cx: 202, cy: 21, size: 14, level: 15)
        } else {
            drawAgyIcon(ctx, cx: 202, cy: 21, size: 14, level: 15)
        }
        drawMiniBars(ctx, x: 218, cy: 21, count: 4, maxH: 13)
        let liveTxt: String
        if !rc.livePartialSTT.isEmpty {
            liveTxt = rc.voiceSearchMode ? "⌕ “\(rc.livePartialSTT)”" : "“\(rc.livePartialSTT)”"
        } else {
            liveTxt = rc.voiceSearchMode ? "⌕ 검색어 듣는 중..." : "듣는 중..."
        }
        let font = UIFont.systemFont(ofSize: 13.5, weight: .regular)
        drawText(ctx, clip(liveTxt, font: font, maxW: 296), x: 248, y: 21.5, font: font, level: 15, align: .left, baseline: .middle)
    }

    private static func drawMiniBars(_ ctx: CGContext, x: CGFloat, cy: CGFloat, count: Int, maxH: CGFloat) {
        let heights: [CGFloat] = [0.45, 0.92, 0.65, 1.0, 0.55]
        for i in 0..<count {
            let h = max(4, maxH * heights[i % heights.count])
            fillRoundedRect(ctx, x: x + CGFloat(i) * 5.2, y: cy - h / 2.0, w: 2.8, h: h, r: 1.4, level: 14)
        }
    }

    private static func drawTailscale(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, on: Bool, spark: Bool) {
        let gap: CGFloat = 5.4
        for r in -1...1 {
            for col in -1...1 {
                let isT = (r == 0) || (r == 1 && col == 0)
                let level: Int
                if on {
                    level = isT ? (spark ? 15 : 12) : 5
                } else {
                    level = isT ? 5 : 2
                }
                fillCircle(ctx, cx: cx + CGFloat(col) * gap, cy: cy + CGFloat(r) * gap, r: isT ? 1.85 : 1.45, level: level)
            }
        }
    }

    private static func drawBattery(_ ctx: CGContext, x: CGFloat, y: CGFloat, pct: Int, charging: Bool) {
        let clamped = max(0, min(100, pct))
        ctx.saveGState()
        let outline = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: 24, height: 12), cornerRadius: 3)
        ctx.setStrokeColor(gray: gVal(10), alpha: 1.0)
        ctx.setLineWidth(1.4)
        ctx.addPath(outline.cgPath)
        ctx.strokePath()
        ctx.setFillColor(gray: gVal(10), alpha: 1.0)
        ctx.fill(CGRect(x: x + 25.5, y: y + 3.5, width: 2, height: 5))
        ctx.restoreGState()

        fillRoundedRect(ctx, x: x + 2.4, y: y + 2.4, w: max(1, 19.0 * CGFloat(clamped) / 100.0), h: 7.2, r: 1.4, level: 14)
        drawText(ctx, "\(charging ? "+" : "")\(clamped)%", x: x + 33, y: y + 6.5, font: .monospacedSystemFont(ofSize: 12, weight: .medium), level: 11, align: .left, baseline: .middle)
    }

    private static func drawGlyph(_ ctx: CGContext, kind: String, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        switch kind {
        case "kakao": drawKakaoIcon(ctx, cx: cx, cy: cy, size: size, level: level)
        case "agy":   drawAgyIcon(ctx, cx: cx, cy: cy, size: size, level: level)
        case "bell":  drawBellIcon(ctx, cx: cx, cy: cy, size: size, level: level)
        default:      drawCompassIcon(ctx, cx: cx, cy: cy, size: size, level: level)
        }
    }

    private static func drawCompassIcon(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
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

    private static func drawAgyIcon(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx, y: cy - r * 0.95))
        ctx.addQuadCurve(to: CGPoint(x: cx + r * 0.95, y: cy), control: CGPoint(x: cx + r * 0.16, y: cy - r * 0.16))
        ctx.addQuadCurve(to: CGPoint(x: cx, y: cy + r * 0.95), control: CGPoint(x: cx + r * 0.16, y: cy + r * 0.16))
        ctx.addQuadCurve(to: CGPoint(x: cx - r * 0.95, y: cy), control: CGPoint(x: cx - r * 0.16, y: cy + r * 0.16))
        ctx.addQuadCurve(to: CGPoint(x: cx, y: cy - r * 0.95), control: CGPoint(x: cx - r * 0.16, y: cy - r * 0.16))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawKakaoIcon(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(max(1.4, size * 0.075))
        ctx.strokeEllipse(in: CGRect(x: cx - r * 0.92, y: cy - r * 0.80, width: r * 1.84, height: r * 1.44))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - r * 0.42, y: cy + r * 0.56))
        ctx.addLine(to: CGPoint(x: cx - r * 0.65, y: cy + r * 0.96))
        ctx.addLine(to: CGPoint(x: cx - r * 0.05, y: cy + r * 0.62))
        ctx.strokePath()
        for ox: CGFloat in [-0.36, 0, 0.36] {
            ctx.fillEllipse(in: CGRect(x: cx + ox * r - 1.4, y: cy - r * 0.08 - 1.4, width: 2.8, height: 2.8))
        }
        ctx.restoreGState()
    }

    private static func drawBellIcon(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(max(1.4, size * 0.08))
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy - r * 0.15), radius: r * 0.55, startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.addLine(to: CGPoint(x: cx + r * 0.72, y: cy + r * 0.48))
        ctx.addLine(to: CGPoint(x: cx - r * 0.72, y: cy + r * 0.48))
        ctx.closePath()
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: cx - r * 0.18, y: cy + r * 0.56, width: r * 0.36, height: r * 0.36))
        ctx.restoreGState()
    }

    private static func drawWeatherGlyph(_ ctx: CGContext, code: String, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
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
