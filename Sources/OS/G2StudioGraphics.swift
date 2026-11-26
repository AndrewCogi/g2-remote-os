import Foundation
#if canImport(UIKit)
import UIKit
import CoreGraphics
#endif

/// Ultra-fast Hybrid Minimalist Studio HUD Renderer for Even Realities G2 (`576 x 288`).
///
/// Combines:
/// - **~60ms instant native `G2TextContainer` cards** (rounded `borderRadius: 10`, focus `borderWidth: 2, borderColor: 15`,
///   zero-flicker differential `cmd 5` text upgrades) for Alerts, Menu Quick Preview, Feed, Reader, and AI streaming.
/// - **Compact 4-bit CoreGraphics vector bitmaps** streamed via official `4096 B` ACK-gated chunks ONLY for elements
///   the stock font cannot express (giant 78pt SF Pro UltraLight Home clock + weather, 9-dot Tailscale + battery icon,
///   and the minimalist 8-slot Menu bottom dock), with per-container FNV-1a dirty-diff caching so unchanged graphics send 0 bytes.
public enum G2StudioGraphics {
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

    // MARK: - 1. Home (`studio_home` — Giant 78pt Clock + Status Icon + Instant Rounded Peek Pill)

    public static func renderHomePage(
        rc: RenderContext,
        alerts: [G2AlertItem],
        recArticles: [G2FeedArticle]
    ) -> G2PageSpec {
        let hasAlerts = !alerts.isEmpty
        let count = hasAlerts ? alerts.count : recArticles.count

        let peekText: String
        let showCue: Bool
        if rc.aiListening {
            let live = rc.livePartialSTT.isEmpty ? "듣는 중..." : "“\(rc.livePartialSTT)”"
            peekText = "✦  \(clipVisual(live, maxUnits: 38))"
            showCue = false
        } else if hasAlerts, let first = alerts.first {
            let badge = count > 1 ? "   +\(count - 1)" : ""
            let lead = "\(glyphSymbol(first.source)) \(first.sender)"
            let bodyAvail = max(12, 42 - visualUnits(lead) - visualUnits(badge))
            peekText = "\(lead)  \(clipVisual(first.preview, maxUnits: bodyAvail))\(badge)"
            showCue = true
        } else if let first = recArticles.first {
            let badge = count > 1 ? "   +\(count - 1)" : ""
            let lead = "✦ \(first.category)"
            let bodyAvail = max(12, 42 - visualUnits(lead) - visualUnits(badge))
            peekText = "\(lead)  \(clipVisual(first.title, maxUnits: bodyAvail))\(badge)"
            showCue = true
        } else {
            peekText = " "
            showCue = false
        }

        let peekPill = G2TextContainer(
            id: 1, name: "peek", x: 36, y: 202, width: 504, height: 52,
            text: peekText,
            captureEvents: true,
            borderWidth: (rc.aiListening || count > 0) ? (rc.aiListening ? 2 : 1) : 0,
            borderColor: rc.aiListening ? 15 : (hasAlerts ? 10 : 7),
            borderRadius: 10,
            padding: 10
        )
        let cue = G2TextContainer(
            id: 2, name: "cue", x: 264, y: 256, width: 48, height: 24,
            text: showCue ? " ⌄" : " ",
            captureEvents: false,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 2
        )

        let clockImg = makeHomeClockImage(
            timeStr: rc.timeStr,
            dateStr: rc.dateStr,
            tempStr: rc.tempStr,
            weatherCode: rc.weatherCode
        )
        let statusImg = makeTopStatusImage(
            tailscaleOn: rc.tailscaleConnected,
            sparkConnected: rc.sparkConnected,
            batteryPercent: rc.batteryPercent,
            charging: rc.charging
        )

        let summary = "\(rc.timeStr) \(rc.dateStr) \(rc.tempStr)\n\(peekText)"
        return G2PageSpec(
            layoutKey: "studio_home",
            textContainers: [peekPill, cue],
            imageContainers: [clockImg, statusImg],
            isBlankTransparent: false,
            summaryText: summary
        )
    }

    // MARK: - 2. Alerts Stack (`studio_alerts_*` — 0 Images, ~60ms Native Rounded Focus Cards)

    public static func renderAlertsPage(
        rc: RenderContext,
        alerts: [G2AlertItem],
        stackIdx: Int
    ) -> G2PageSpec {
        let count = alerts.count
        let onClearAll = (count > 0 && stackIdx == count)
        let cntText = count > 0 ? (onClearAll ? "\(count)/\(count)" : "\(stackIdx + 1)/\(count)") : "0"

        let hdrText: String
        if rc.aiListening {
            hdrText = listeningHeaderText(rc: rc)
        } else {
            hdrText = alignTwoColumns(left: "🔔 \(cntText)", right: compactStatusRight(rc: rc), totalUnits: 46)
        }

        let header = G2TextContainer(
            id: 1, name: "hdr", x: 24, y: 6, width: 528, height: 34,
            text: hdrText,
            captureEvents: true,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 4
        )

        if count == 0 {
            let emptyCard = G2TextContainer(
                id: 2, name: "empty", x: 148, y: 112, width: 280, height: 56,
                text: "      ✓   알림 없음",
                captureEvents: false,
                borderWidth: 1, borderColor: 7, borderRadius: 10, padding: 12
            )
            return G2PageSpec(
                layoutKey: "studio_alerts_empty",
                textContainers: [header, emptyCard],
                imageContainers: [],
                summaryText: "\(hdrText)\n알림 0건"
            )
        }

        let displayIdx = onClearAll ? count - 1 : min(stackIdx, count - 1)
        let cur = alerts[displayIdx]
        let cardFocused = !onClearAll

        let topLine = alignTwoColumns(
            left: "\(glyphSymbol(cur.source)) \(cur.sender)",
            right: cur.timeLabel,
            totalUnits: 42
        )
        let wrappedPreview = wrapVisual(cur.preview, maxUnits: 42).prefix(2)
        let curText = ([topLine, ""] + wrappedPreview).joined(separator: "\n")

        let curCard = G2TextContainer(
            id: 2, name: "acard0", x: 24, y: 46, width: 528, height: 126,
            text: curText,
            captureEvents: false,
            borderWidth: cardFocused ? 2 : 1,
            borderColor: cardFocused ? 15 : 5,
            borderRadius: 10,
            padding: 10
        )

        let bottomCard: G2TextContainer
        let layoutKey: String
        if displayIdx + 1 < count {
            let nxt = alerts[displayIdx + 1]
            let nxtText = "\(glyphSymbol(nxt.source)) \(nxt.sender)\n\(clipVisual(nxt.preview, maxUnits: 42))"
            bottomCard = G2TextContainer(
                id: 3, name: "acard1", x: 24, y: 184, width: 528, height: 86,
                text: nxtText,
                captureEvents: false,
                borderWidth: 1, borderColor: 5, borderRadius: 10, padding: 10
            )
            layoutKey = "studio_alerts_stack"
        } else {
            bottomCard = G2TextContainer(
                id: 3, name: "aclear", x: 184, y: 196, width: 208, height: 48,
                text: "   ×  모두 지우기",
                captureEvents: false,
                borderWidth: onClearAll ? 2 : 1,
                borderColor: onClearAll ? 15 : 7,
                borderRadius: 10,
                padding: 10
            )
            layoutKey = onClearAll ? "studio_alerts_clear_on" : "studio_alerts_clear_off"
        }

        return G2PageSpec(
            layoutKey: layoutKey,
            textContainers: [header, curCard, bottomCard],
            imageContainers: [],
            summaryText: "\(hdrText)\n\(cur.sender): \(cur.preview)"
        )
    }

    // MARK: - 3. Menu Preview + 8-Slot Dock (`studio_menu_*` — 0.06s Quick Preview + Fast 4KB Dock Strips)

    public static func renderMenuPage(
        rc: RenderContext,
        slotIdx: Int,
        menuFocus: Int,
        recArticles: [G2FeedArticle]
    ) -> G2PageSpec {
        let isFeed = (slotIdx == 0)
        let onDock = (menuFocus < 0)

        let hdrText: String
        if rc.aiListening {
            hdrText = listeningHeaderText(rc: rc)
        } else if isFeed {
            let counter = (!onDock && !recArticles.isEmpty) ? "   \(menuFocus + 1)/\(recArticles.count)" : ""
            hdrText = "✦ 피드\(counter)   \(rc.timeStr)"
        } else {
            hdrText = "\(slotIdx + 1)/8   \(rc.timeStr)"
        }

        let header = G2TextContainer(
            id: 1, name: "hdr", x: 24, y: 6, width: 410, height: 32,
            text: hdrText,
            captureEvents: true,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 4
        )
        let statusImg = makeTopStatusImage(
            tailscaleOn: rc.tailscaleConnected,
            sparkConnected: rc.sparkConnected,
            batteryPercent: rc.batteryPercent,
            charging: rc.charging
        )
        let dockImgs = makeMenuDockImages(selectedIdx: slotIdx, dockFocused: onDock)

        if isFeed && !recArticles.isEmpty {
            let total = recArticles.count
            let focusIdx = max(-1, min(total - 1, menuFocus))
            let maxViewTop = max(0, total - 2)
            let viewTop = focusIdx < 0 ? 0 : min(focusIdx, maxViewTop)

            var rows: [G2TextContainer] = []
            for pos in 0..<min(2, total) {
                let idx = viewTop + pos
                let art = recArticles[idx]
                let focused = (idx == focusIdx)
                let text = formatBalancedRowText(
                    article: art,
                    numIndex: idx,
                    focused: focused,
                    showOutlet: false
                )
                rows.append(
                    G2TextContainer(
                        id: 2 + pos,
                        name: "mrow\(pos)",
                        x: 24,
                        y: 44 + pos * 88,
                        width: 528,
                        height: 82,
                        text: text,
                        captureEvents: false,
                        borderWidth: 1,
                        borderColor: 7,
                        borderRadius: 10,
                        padding: 8
                    )
                )
            }

            let summary = "\(hdrText)\n피드 (\(onDock ? "독" : "\(focusIdx + 1)/\(total)"))"
            // Fixed layoutKey across Dock & Quick Preview so ↑/↓ never triggers cmd 7 or Dock re-uploads (~60ms!).
            return G2PageSpec(
                layoutKey: "studio_menu_feed",
                textContainers: [header] + rows,
                imageContainers: [statusImg] + dockImgs,
                summaryText: summary
            )
        } else {
            let emptySlot = G2TextContainer(
                id: 2, name: "mempty", x: 168, y: 102, width: 240, height: 52,
                text: "        슬롯 \(slotIdx + 1)",
                captureEvents: false,
                borderWidth: 1, borderColor: 5, borderRadius: 10, padding: 12
            )
            return G2PageSpec(
                layoutKey: "studio_menu_empty",
                textContainers: [header, emptySlot],
                imageContainers: [statusImg] + dockImgs,
                summaryText: "\(hdrText)\n슬롯 \(slotIdx + 1)/8"
            )
        }
    }

    // MARK: - 4. Full-Screen Feed App (`studio_feed_*` — 0 Images, ~60-85ms Rounded Focus Cards!)

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
        let isSearch = (cat.id == "search")

        let hdrText: String
        if rc.aiListening {
            hdrText = listeningHeaderText(rc: rc)
        } else {
            let tabLine = categories.enumerated().map { idx, tab in
                idx == safeCatIdx ? "▌\(tab.label)" : tab.label
            }.joined(separator: "  ")
            let rightMeta = "\(total > 0 ? "\(focus + 1)/\(total) " : "")\(rc.charging ? "+" : "")\(rc.batteryPercent)%"
            hdrText = alignTwoColumns(left: tabLine, right: rightMeta, totalUnits: 48)
        }

        let header = G2TextContainer(
            id: 1, name: "hdr", x: 16, y: 4, width: 544, height: 34,
            text: hdrText,
            captureEvents: true,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 4
        )

        var containers: [G2TextContainer] = [header]
        var startY = 42

        if isSearch {
            let qStr = searchQuery.isEmpty ? "전체" : searchQuery
            containers.append(
                G2TextContainer(
                    id: 5, name: "fsearch", x: 20, y: 40, width: 536, height: 32,
                    text: clipVisual("⌕ “\(qStr)”  ·  \(total)건", maxUnits: 44),
                    captureEvents: false,
                    borderWidth: 1, borderColor: 8, borderRadius: 8, padding: 5
                )
            )
            startY = 78
        }

        let visibleCount = min(isSearch ? 2 : 3, total)
        let maxViewTop = max(0, total - visibleCount)
        let viewTop = min(focus, maxViewTop)
        let focusPos = max(0, focus - viewTop)
        let rowH = isSearch ? 92 : 74
        let rowGap = 6

        for pos in 0..<visibleCount {
            let idx = viewTop + pos
            let focused = (idx == focus)
            let rowText = formatBalancedRowText(
                article: items[idx],
                numIndex: idx,
                focused: focused,
                showOutlet: true
            )
            containers.append(
                G2TextContainer(
                    id: 2 + pos,
                    name: "frow\(pos)",
                    x: 20,
                    y: startY + pos * (rowH + rowGap),
                    width: 536,
                    height: rowH,
                    text: rowText,
                    captureEvents: false,
                    borderWidth: focused ? 2 : 1,
                    borderColor: focused ? 15 : 5,
                    borderRadius: 10,
                    padding: 8
                )
            )
        }

        if visibleCount == 0 {
            containers.append(
                G2TextContainer(
                    id: 2, name: "fempty", x: 148, y: 120, width: 280, height: 56,
                    text: "     검색 결과 없음",
                    captureEvents: false,
                    borderWidth: 1, borderColor: 6, borderRadius: 10, padding: 12
                )
            )
        }

        let layoutKey = "studio_feed_\(isSearch ? "s" : "n")_\(visibleCount)_f\(focusPos)"
        let summary = "\(hdrText)\n\(cat.label) \(total > 0 ? "\(focus + 1)/\(total)" : "0")"
        return G2PageSpec(
            layoutKey: layoutKey,
            textContainers: containers,
            imageContainers: [],
            summaryText: summary
        )
    }

    // MARK: - 5. Reader Detail (`studio_reader` — 0 Images, ~60ms Zero-Flicker Scroll!)

    public static func renderReaderPage(
        rc: RenderContext,
        iconKind: String,
        headerLeft: String,
        headerRight: String,
        lines: [String],
        scrollOffset: Int,
        isNewsTitleOnLine0: Bool
    ) -> G2PageSpec {
        let hdrText: String
        if rc.aiListening {
            hdrText = listeningHeaderText(rc: rc)
        } else {
            hdrText = alignTwoColumns(
                left: "\(glyphSymbol(iconKind)) \(clipVisual(headerLeft, maxUnits: 32))",
                right: headerRight,
                totalUnits: 46
            )
        }

        let header = G2TextContainer(
            id: 1, name: "hdr", x: 20, y: 6, width: 536, height: 34,
            text: hdrText,
            captureEvents: true,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 4
        )

        let detailLines = 6
        let total = lines.count
        let maxScroll = max(0, total - detailLines)
        let safeScroll = max(0, min(maxScroll, scrollOffset))
        var slice = Array(lines.dropFirst(safeScroll).prefix(detailLines))
        if safeScroll > 0 && !slice.isEmpty {
            slice[0] = "▴ " + slice[0]
        }
        if safeScroll < maxScroll && !slice.isEmpty {
            slice[slice.count - 1] = slice[slice.count - 1] + "  ▾"
        }

        let bodyText = slice.joined(separator: "\n")
        let bodyCard = G2TextContainer(
            id: 2, name: "rbody", x: 20, y: 44, width: 536, height: 236,
            text: bodyText.isEmpty ? " " : bodyText,
            captureEvents: false,
            borderWidth: 1, borderColor: 7, borderRadius: 10, padding: 10
        )

        return G2PageSpec(
            layoutKey: "studio_reader",
            textContainers: [header, bodyCard],
            imageContainers: [],
            summaryText: "\(hdrText)\n\(bodyText)"
        )
    }

    // MARK: - 6. AI Reply (`studio_ai_reply` — 0 Images, ~60ms Live Token Streaming!)

    public static func renderAIReplyPage(
        rc: RenderContext,
        question: String,
        answerLines: [String],
        scrollOffset: Int
    ) -> G2PageSpec {
        let hdrText: String
        if rc.aiListening {
            hdrText = listeningHeaderText(rc: rc)
        } else {
            hdrText = alignTwoColumns(
                left: "✦ \(clipVisual(question, maxUnits: 30))",
                right: compactStatusRight(rc: rc),
                totalUnits: 46
            )
        }

        let header = G2TextContainer(
            id: 1, name: "hdr", x: 20, y: 6, width: 536, height: 34,
            text: hdrText,
            captureEvents: true,
            borderWidth: 0, borderColor: 0, borderRadius: 0, padding: 4
        )

        let visible = 5
        let maxOff = max(0, answerLines.count - visible)
        let safeOff = max(0, min(maxOff, scrollOffset))
        var slice = Array(answerLines.dropFirst(safeOff).prefix(visible))
        if safeOff < maxOff && !slice.isEmpty {
            slice[slice.count - 1] = slice[slice.count - 1] + "  ▾"
        }

        let bodyText = slice.joined(separator: "\n")
        let bodyCard = G2TextContainer(
            id: 2, name: "abody", x: 20, y: 44, width: 536, height: 236,
            text: bodyText.isEmpty ? " " : bodyText,
            captureEvents: false,
            borderWidth: 2, borderColor: 13, borderRadius: 10, padding: 12
        )

        return G2PageSpec(
            layoutKey: "studio_ai_reply",
            textContainers: [header, bodyCard],
            imageContainers: [],
            summaryText: "\(hdrText)\n\(answerLines.joined(separator: "\n"))"
        )
    }

    // MARK: - Compact High-Speed 4-Bit Graphic Generators (4096 B Chunked)

    /// Giant 78pt SF Pro UltraLight clock + date + vector weather (`240 x 120` = 14.5 KB = 4 chunks ~0.6s, cached!).
    public static func makeHomeClockImage(
        timeStr: String,
        dateStr: String,
        tempStr: String,
        weatherCode: String
    ) -> G2ImageContainer {
        let w = 240
        let h = 120
        let hash = "hclk_\(timeStr)_\(dateStr)_\(tempStr)_\(weatherCode)"

        #if canImport(UIKit)
        let packed = render4bpp(width: w, height: h) { ctx in
            drawText(
                ctx, timeStr,
                x: CGFloat(w) / 2.0, y: 74,
                font: .systemFont(ofSize: 78, weight: .ultraLight),
                level: 15, align: .center, baseline: .alphabetic
            )

            let metaY: CGFloat = 102
            drawText(
                ctx, dateStr,
                x: 112, y: metaY,
                font: .systemFont(ofSize: 16.5, weight: .regular),
                level: 11, align: .right, baseline: .middle
            )
            fillCircle(ctx, cx: 124, cy: metaY, r: 1.8, level: 5)
            drawWeatherGlyph(ctx, code: weatherCode, cx: 146, cy: metaY, size: 21, level: 14)
            drawText(
                ctx, tempStr,
                x: 163, y: metaY + 0.5,
                font: .systemFont(ofSize: 17.5, weight: .medium),
                level: 14, align: .left, baseline: .middle
            )
        }
        #else
        let canvas = G2PixelCanvas(width: w, height: h)
        canvas.drawBigClock(timeStr, originX: 32, originY: 12, digitW: 28, digitH: 52, thickness: 4, spacing: 7, level: 15)
        canvas.drawWeatherIcon(code: weatherCode, cx: 146, cy: 102)
        let packed = canvas.pack4bpp()
        #endif

        return G2ImageContainer(id: 10, name: "homeclk", x: 168, y: 34, width: w, height: h, packed4bpp: packed, contentHash: hash)
    }

    /// Top-right 3x3 Tailscale dot matrix + battery gauge (`112 x 24` = 1.4 KB = 1 chunk ~0.12s).
    public static func makeTopStatusImage(
        tailscaleOn: Bool,
        sparkConnected: Bool,
        batteryPercent: Int,
        charging: Bool
    ) -> G2ImageContainer {
        let w = 112
        let h = 24
        let clamped = max(0, min(100, batteryPercent))
        let hash = "tsbat_\(tailscaleOn ? 1 : 0)_\(sparkConnected ? 1 : 0)_\(clamped)_\(charging ? 1 : 0)"

        #if canImport(UIKit)
        let packed = render4bpp(width: w, height: h) { ctx in
            drawTailscale(ctx, cx: 16, cy: 12, on: tailscaleOn, spark: sparkConnected)
            drawBattery(ctx, x: 38, y: 6, pct: clamped, charging: charging)
        }
        #else
        let packed = Data(count: (w / 2) * h)
        #endif

        return G2ImageContainer(id: 11, name: "tsbat", x: 444, y: 10, width: w, height: h, packed4bpp: packed, contentHash: hash)
    }

    /// Minimalist 8-Slot Menu Bottom Dock split into 2 compact `256 x 48` strips (`6.2 KB` each = 2 chunks ~0.25s).
    public static func makeMenuDockImages(selectedIdx: Int, dockFocused: Bool) -> [G2ImageContainer] {
        let tileW = 256
        let tileH = 48
        let totalW = tileW * 2 // 512 px centered at x = 32
        let slotCount = 8
        let spacing: CGFloat = 62
        let startX: CGFloat = CGFloat(totalW) / 2.0 - (CGFloat(slotCount - 1) * spacing) / 2.0
        let iconY: CGFloat = 22
        let safeSel = max(0, min(slotCount - 1, selectedIdx))

        return (0..<2).map { half in
            let containerId = 12 + half
            let name = (half == 0) ? "dockL" : "dockR"
            let originX = 32 + half * tileW

            #if canImport(UIKit)
            let packed = render4bpp(width: tileW, height: tileH) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: -CGFloat(half * tileW), y: 0)

                // Top hairline
                strokeLine(ctx, x0: 4, y0: 1, x1: CGFloat(totalW - 4), y1: 1, level: 3, lineWidth: 1)

                // 8 Minimalist Dock Slots
                for idx in 0..<slotCount {
                    let cx = startX + CGFloat(idx) * spacing
                    let sel = (idx == safeSel)
                    let empty = (idx > 0)
                    if sel {
                        fillStrokeRoundedRect(
                            ctx, x: cx - 22, y: iconY - 17, w: 44, h: 34, r: 10,
                            fillLevel: dockFocused ? 4 : 2,
                            strokeLevel: empty ? 9 : (dockFocused ? 15 : 8),
                            lineWidth: dockFocused ? 1.8 : 1.1
                        )
                    }
                    if !empty {
                        drawCompassIcon(ctx, cx: cx, cy: iconY, size: sel ? 20 : 17, level: sel ? (dockFocused ? 15 : 12) : 9)
                    } else {
                        strokeDashedRoundedRect(ctx, x: cx - 7, y: iconY - 7, w: 14, h: 14, r: 3.5, level: sel ? 10 : 5, lineWidth: 1.2)
                    }
                }

                // Bottom 8-slot horizontal scrollbar track
                let trackX: CGFloat = 136, trackW: CGFloat = 240, trackY: CGFloat = 43
                let thumbW = trackW / CGFloat(slotCount)
                let thumbX = trackX + (trackW - thumbW) * (CGFloat(safeSel) / CGFloat(slotCount - 1))
                fillRoundedRect(ctx, x: trackX, y: trackY, w: trackW, h: 3, r: 1.5, level: 4)
                fillRoundedRect(ctx, x: thumbX, y: trackY, w: thumbW, h: 3, r: 1.5, level: 14)

                ctx.restoreGState()
            }
            let hash = "\(name)_\(fnv1aHex(packed))"
            #else
            let packed = Data(count: (tileW / 2) * tileH)
            let hash = "\(name)_\(safeSel)_\(dockFocused ? 1 : 0)"
            #endif

            return G2ImageContainer(
                id: containerId, name: name,
                x: originX, y: 226, width: tileW, height: tileH,
                packed4bpp: packed, contentHash: hash
            )
        }
    }

    // MARK: - Text Formatting Helpers (Clean Minimalist Typography)

    private static func formatBalancedRowText(
        article: G2FeedArticle,
        numIndex: Int,
        focused: Bool,
        showOutlet: Bool
    ) -> String {
        let prefix = focused ? "▌" : " "
        let num = String(format: "%02d", numIndex + 1)
        let meta = showOutlet ? "\(article.outlet)·\(article.timeLabel)" : "\(article.category)·\(article.timeLabel)"
        let leftBase = "\(prefix)\(num) "
        let titleAvail = max(14, 42 - visualUnits(leftBase) - visualUnits(meta) - 2)
        let title = clipVisual(article.title, maxUnits: titleAvail)
        let line1 = alignTwoColumns(left: "\(leftBase)\(title)", right: meta, totalUnits: 42)
        let line2 = "   \(clipVisual(article.snippet, maxUnits: 39))"
        return "\(line1)\n\(line2)"
    }

    private static func listeningHeaderText(rc: RenderContext) -> String {
        let icon = rc.voiceSearchMode ? "⌕" : "✦"
        let text: String
        if !rc.livePartialSTT.isEmpty {
            text = "“\(rc.livePartialSTT)”"
        } else {
            text = rc.voiceSearchMode ? "검색어 듣는 중..." : "듣는 중..."
        }
        return "\(icon)  \(clipVisual(text, maxUnits: 40))"
    }

    private static func compactStatusRight(rc: RenderContext) -> String {
        let ts = rc.tailscaleConnected ? (rc.sparkConnected ? "●" : "◐") : "○"
        let bat = "\(rc.charging ? "+" : "")\(rc.batteryPercent)%"
        return "\(rc.timeStr)  \(ts)  \(bat)"
    }

    private static func glyphSymbol(_ kind: String) -> String {
        switch kind {
        case "kakao": return "💬"
        case "agy":   return "✦"
        case "bell":  return "🔔"
        default:      return "✦"
        }
    }

    private static func visualUnits(_ text: String) -> Int {
        var u = 0
        for ch in text { u += ch.isASCII ? 1 : 2 }
        return u
    }

    private static func clipVisual(_ text: String, maxUnits: Int) -> String {
        var out = ""
        var units = 0
        for ch in text {
            let w = ch.isASCII ? 1 : 2
            if units + w > maxUnits { return out + "…" }
            out.append(ch)
            units += w
        }
        return out
    }

    private static func alignTwoColumns(left: String, right: String, totalUnits: Int) -> String {
        let l = visualUnits(left)
        let r = visualUnits(right)
        let gap = max(2, totalUnits - l - r)
        return left + String(repeating: " ", count: gap) + right
    }

    private static func wrapVisual(_ text: String, maxUnits: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        var u = 0
        for ch in text {
            let w = ch.isASCII ? 1 : 2
            if u + w > maxUnits && !cur.isEmpty {
                out.append(cur)
                cur = String(ch)
                u = w
            } else {
                cur.append(ch)
                u += w
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func fnv1aHex(_ data: Data) -> String {
        var h: UInt64 = 14695981039346656037
        for b in data {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(format: "%016llx", h)
    }

    // MARK: - CoreGraphics 4-bit Bitmap Rendering Primitives

    #if canImport(UIKit)
    private enum TextAlign { case left, center, right }
    private enum TextBaseline { case middle, alphabetic }

    private static func render4bpp(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
        var gray = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        gray.withUnsafeMutableBytes { rawBuf in
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
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
        }

        let stride = (width + 1) / 2
        var packed = Data(count: stride * height)
        packed.withUnsafeMutableBytes { outRaw in
            let out = outRaw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let srcRow = y * width
                let dstRow = y * stride
                var x = 0
                while x < width {
                    let hi = UInt8((Int(gray[srcRow + x]) * 15 + 127) / 255)
                    let lo: UInt8 = (x + 1 < width) ? UInt8((Int(gray[srcRow + x + 1]) * 15 + 127) / 255) : 0
                    out[dstRow + (x >> 1)] = (hi << 4) | lo
                    x += 2
                }
            }
        }
        return packed
    }

    private static func gVal(_ level: Int) -> CGFloat {
        CGFloat(max(0, min(15, level))) / 15.0
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

    private static func fillCircle(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, level: Int) {
        ctx.saveGState()
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    private static func drawTailscale(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, on: Bool, spark: Bool) {
        let gap: CGFloat = 5.2
        for r in -1...1 {
            for col in -1...1 {
                let isT = (r == 0) || (r == 1 && col == 0)
                let level: Int
                if on {
                    level = isT ? (spark ? 15 : 12) : 5
                } else {
                    level = isT ? 5 : 2
                }
                fillCircle(ctx, cx: cx + CGFloat(col) * gap, cy: cy + CGFloat(r) * gap, r: isT ? 1.8 : 1.4, level: level)
            }
        }
    }

    private static func drawBattery(_ ctx: CGContext, x: CGFloat, y: CGFloat, pct: Int, charging: Bool) {
        let clamped = max(0, min(100, pct))
        ctx.saveGState()
        let outline = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: 22, height: 12), cornerRadius: 3)
        ctx.setStrokeColor(gray: gVal(10), alpha: 1.0)
        ctx.setLineWidth(1.4)
        ctx.addPath(outline.cgPath)
        ctx.strokePath()
        ctx.setFillColor(gray: gVal(10), alpha: 1.0)
        ctx.fill(CGRect(x: x + 23.5, y: y + 3.5, width: 2, height: 5))
        ctx.restoreGState()

        fillRoundedRect(ctx, x: x + 2.2, y: y + 2.2, w: max(1, 17.5 * CGFloat(clamped) / 100.0), h: 7.6, r: 1.3, level: 14)
        drawText(ctx, "\(charging ? "+" : "")\(clamped)%", x: x + 30, y: y + 6.5, font: .monospacedSystemFont(ofSize: 11.5, weight: .medium), level: 11, align: .left, baseline: .middle)
    }

    private static func drawCompassIcon(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(max(1.5, size * 0.08))
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

    private static func drawWeatherGlyph(_ ctx: CGContext, code: String, cx: CGFloat, cy: CGFloat, size: CGFloat, level: Int) {
        let r = size / 2.0
        ctx.saveGState()
        ctx.setStrokeColor(gray: gVal(level), alpha: 1.0)
        ctx.setFillColor(gray: gVal(level), alpha: 1.0)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        switch code {
        case "rain", "storm":
            ctx.fillEllipse(in: CGRect(x: cx - 7.5, y: cy - 5.5, width: 9.5, height: 9.5))
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: cy - 8.5, width: 11, height: 11))
            ctx.fill(CGRect(x: cx - 5.5, y: cy - 1, width: 13, height: 4))
            for ox: CGFloat in [-3.5, 1.0, 5.5] {
                ctx.move(to: CGPoint(x: cx + ox, y: cy + 4.5))
                ctx.addLine(to: CGPoint(x: cx + ox - 2, y: cy + 8.5))
            }
            ctx.strokePath()
        case "cloud", "cloudy", "snow":
            ctx.fillEllipse(in: CGRect(x: cx - 8.5, y: cy - 3, width: 9.5, height: 9.5))
            ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy - 6.5, width: 11, height: 11))
            ctx.fillEllipse(in: CGRect(x: cx + 2.5, y: cy - 3, width: 8.5, height: 8.5))
            ctx.fill(CGRect(x: cx - 5.5, y: cy + 1.5, width: 14, height: 4.5))
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
