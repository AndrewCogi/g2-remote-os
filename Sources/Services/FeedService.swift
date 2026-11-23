import Foundation

public struct G2FeedArticle: Identifiable, Equatable {
    public let id: String
    public let category: String
    public let outlet: String
    public let timeLabel: String
    public let title: String
    public let snippet: String
    public let bodyLines: [String]

    public init(
        id: String,
        category: String,
        outlet: String,
        timeLabel: String,
        title: String,
        snippet: String,
        bodyLines: [String]
    ) {
        self.id = id
        self.category = category
        self.outlet = outlet
        self.timeLabel = timeLabel
        self.title = title
        self.snippet = snippet
        self.bodyLines = bodyLines
    }
}

public struct G2FeedCategory: Identifiable, Equatable {
    public let id: String
    public let label: String
    public var articles: [G2FeedArticle]

    public init(id: String, label: String, articles: [G2FeedArticle]) {
        self.id = id
        self.label = label
        self.articles = articles
    }
}

/// Free ($0) RSS + instant curated fallback Feed service for G2 Spatial OS Slot #1 (`피드`).
public final class FeedService: ObservableObject {
    @Published public private(set) var categories: [G2FeedCategory] = FeedService.defaultCategories()
    @Published public private(set) var lastQuery: String = ""
    @Published public private(set) var isRefreshing: Bool = false

    public var onUpdated: (([G2FeedCategory]) -> Void)?

    private var allArticles: [G2FeedArticle] = FeedService.seedArticles()
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: cfg)
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let sources: [(cat: String, outlet: String, url: String)] = [
            ("AI·테크", "GeekNews", "https://news.hada.io/rss/news"),
            ("웨어러블", "9to5Mac", "https://9to5mac.com/feed/"),
            ("증시", "구글뉴스", "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=ko&gl=KR&ceid=KR:ko"),
            ("개발", "Hacker News", "https://hnrss.org/frontpage?count=6")
        ]

        let group = DispatchGroup()
        let lock = NSLock()
        var fetched: [G2FeedArticle] = []

        for src in sources {
            guard let url = URL(string: src.url) else { continue }
            group.enter()
            session.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard let data, !data.isEmpty else { return }
                let parsed = SimpleRSSParser.parse(data: data, category: src.cat, outlet: src.outlet, limit: 5)
                if !parsed.isEmpty {
                    lock.lock()
                    fetched.append(contentsOf: parsed)
                    lock.unlock()
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            if !fetched.isEmpty {
                self.allArticles = fetched
                self.rebuildCategories()
            }
        }
    }

    public func applyVoiceSearch(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lastQuery = clean
        rebuildCategories()
    }

    private func rebuildCategories() {
        let ai = allArticles.filter { $0.category == "AI·테크" }
        let wearable = allArticles.filter { $0.category == "웨어러블" }
        let market = allArticles.filter { $0.category == "증시" }
        let dev = allArticles.filter { $0.category == "개발" }

        // Recommended: interleave top articles across categories
        var rec: [G2FeedArticle] = []
        let buckets = [ai, wearable, market, dev]
        for idx in 0..<3 {
            for b in buckets where idx < b.count {
                rec.append(b[idx])
                if rec.count >= 6 { break }
            }
            if rec.count >= 6 { break }
        }
        if rec.isEmpty { rec = Array(allArticles.prefix(5)) }

        // Search tab results
        let searchItems: [G2FeedArticle]
        if lastQuery.isEmpty {
            searchItems = Array(rec.prefix(3))
        } else {
            let tokens = lastQuery.lowercased().split(separator: " ").map(String.init)
            let matched = allArticles.filter { art in
                let hay = "\(art.title) \(art.snippet) \(art.category) \(art.outlet)".lowercased()
                return tokens.contains { hay.contains($0) }
            }
            searchItems = matched.isEmpty ? Array(rec.prefix(3)) : matched
        }

        let built: [G2FeedCategory] = [
            G2FeedCategory(id: "rec", label: "추천", articles: rec),
            G2FeedCategory(id: "ai", label: "AI·테크", articles: ai.isEmpty ? Array(rec.prefix(3)) : ai),
            G2FeedCategory(id: "wearable", label: "웨어러블", articles: wearable.isEmpty ? Array(rec.prefix(3)) : wearable),
            G2FeedCategory(id: "market", label: "증시", articles: market.isEmpty ? Array(rec.prefix(2)) : market),
            G2FeedCategory(id: "dev", label: "개발", articles: dev.isEmpty ? Array(rec.prefix(3)) : dev),
            G2FeedCategory(id: "search", label: "⌕ 검색", articles: searchItems)
        ]
        categories = built
        onUpdated?(built)
    }

    public static func defaultCategories() -> [G2FeedCategory] {
        let seed = seedArticles()
        return [
            G2FeedCategory(id: "rec", label: "추천", articles: Array(seed.prefix(5))),
            G2FeedCategory(id: "ai", label: "AI·테크", articles: seed.filter { $0.category == "AI·테크" }),
            G2FeedCategory(id: "wearable", label: "웨어러블", articles: seed.filter { $0.category == "웨어러블" }),
            G2FeedCategory(id: "market", label: "증시", articles: seed.filter { $0.category == "증시" }),
            G2FeedCategory(id: "dev", label: "개발", articles: seed.filter { $0.category == "개발" }),
            G2FeedCategory(id: "search", label: "⌕ 검색", articles: Array(seed.prefix(3)))
        ]
    }

    public static func seedArticles() -> [G2FeedArticle] {
        [
            G2FeedArticle(
                id: "seed-1", category: "AI·테크", outlet: "GeekNews", timeLabel: "방금",
                title: "NVIDIA, Blackwell 온디바이스 추론 SDK 공개",
                snippet: "DGX Spark(GB10) 등 엣지 기기용 초저지연 추론 엔진 · Whisper 지연 35% 단축",
                bodyLines: [
                    "[핵심 요약]",
                    "NVIDIA가 DGX Spark(GB10) 등 엣지 Blackwell 장비 전용",
                    "초저지연 추론 최적화 SDK와 ARM64 네이티브 CUDA 휠을 공개했습니다.",
                    "",
                    "[주요 수치]",
                    "• Whisper large-v3-turbo bfloat16 기준 음성 지연 35% 단축",
                    "• 128GB 통합 메모리에서 STT + 로컬 LLM 동시 상주 지원"
                ]
            ),
            G2FeedArticle(
                id: "seed-2", category: "웨어러블", outlet: "The Verge", timeLabel: "25분 전",
                title: "스마트 안경 HUD, 고가독성 미니멀 리스트로 진화",
                snippet: "단색 광학 렌즈에서 장식을 빼고 즉각 열기·빠른보기 분리",
                bodyLines: [
                    "[핵심 요약]",
                    "초경량 단색 광학 안경의 UX가 복잡한 위젯을 덜어내고",
                    "핵심 정보만 선명하게 띄우는 미니멀 리스트로 자리잡고 있습니다.",
                    "",
                    "[포인트]",
                    "• 주머니 속 8BitDo Micro 왼손 세로 조작으로 시선 분산 최소화",
                    "• 6개 핵심 입력만으로 탐색·정독·AI 호출 완결"
                ]
            ),
            G2FeedArticle(
                id: "seed-3", category: "증시", outlet: "마켓 요약", timeLabel: "1시간 전",
                title: "나스닥 +0.84% 마감 · AI 반도체·클라우드 동반 강세",
                snippet: "빅테크 GPU 설비투자 상향에 반도체 지수 +1.9% · 환율 안정",
                bodyLines: [
                    "[핵심 요약]",
                    "미국 주요 지수가 상승 마감했으며, 특히 AI 인프라 및",
                    "반도체 장비·클라우드 종목에 매수세가 집중되었습니다.",
                    "",
                    "[주요 수치]",
                    "• 나스닥 +0.84% · S&P500 +0.52% · 필라델피아 반도체 +1.92%"
                ]
            ),
            G2FeedArticle(
                id: "seed-4", category: "개발", outlet: "Hacker News", timeLabel: "2시간 전",
                title: "로컬 Markdown 볼트 + 개인 AI 에이전트, 지식관리 표준화",
                snippet: "Obsidian 호환 폴더를 홈 서버 AI 장기 기억 DB로 활용",
                bodyLines: [
                    "[핵심 요약]",
                    "사람과 개인 AI가 같은 Markdown(.md) 볼트를 공유하며",
                    "피드·메모·회의 기록을 누적하는 패턴이 확산되고 있습니다."
                ]
            ),
            G2FeedArticle(
                id: "seed-5", category: "웨어러블", outlet: "9to5Mac", timeLabel: "3시간 전",
                title: "근접 센서 포켓 모드, iPhone 미니 컨트롤러 실사용 해법",
                snippet: "주머니에 넣으면 디스플레이·터치 전원을 끄고 게임패드 입력만 수신",
                bodyLines: [
                    "[핵심 요약]",
                    "iOS 공식 근접 센서 API를 활용해 주머니 속 화면과 터치를 끄고",
                    "8BitDo Micro 입력만 백그라운드 없이 즉각 수신합니다."
                ]
            )
        ]
    }
}

private final class SimpleRSSParser: NSObject, XMLParserDelegate {
    private let category: String
    private let outlet: String
    private let limit: Int

    private var items: [G2FeedArticle] = []
    private var inItem = false
    private var currentTag = ""
    private var curTitle = ""
    private var curDesc = ""
    private var curPubDate = ""
    private var curLink = ""

    init(category: String, outlet: String, limit: Int) {
        self.category = category
        self.outlet = outlet
        self.limit = limit
    }

    static func parse(data: Data, category: String, outlet: String, limit: Int) -> [G2FeedArticle] {
        let delegate = SimpleRSSParser(category: category, outlet: outlet, limit: limit)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let lower = elementName.lowercased()
        currentTag = lower
        if lower == "item" || lower == "entry" {
            inItem = true
            curTitle = ""
            curDesc = ""
            curPubDate = ""
            curLink = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch currentTag {
        case "title": curTitle += string
        case "description", "summary", "content": curDesc += string
        case "pubdate", "updated", "published": curPubDate += string
        case "link": curLink += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let lower = elementName.lowercased()
        if (lower == "item" || lower == "entry"), inItem {
            inItem = false
            guard items.count < limit else { return }
            let title = cleanHTML(curTitle)
            guard !title.isEmpty else { return }
            let desc = cleanHTML(curDesc)
            let snippet = desc.isEmpty ? "\(outlet) 최신 기사" : String(desc.prefix(80))
            let bodyText = desc.isEmpty ? title : desc
            let wrapped = wrapLines(bodyText, maxUnits: 44)
            let id = "\(category)_\(items.count)_\(title.hashValue)"
            items.append(
                G2FeedArticle(
                    id: id,
                    category: category,
                    outlet: outlet,
                    timeLabel: relativeTime(from: curPubDate),
                    title: title,
                    snippet: snippet,
                    bodyLines: wrapped
                )
            )
        }
    }

    private func cleanHTML(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativeTime(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "최신" }
        let fmts = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: trimmed) {
                let mins = max(1, Int(Date().timeIntervalSince(d) / 60))
                if mins < 60 { return "\(mins)분 전" }
                let hrs = mins / 60
                if hrs < 24 { return "\(hrs)시간 전" }
                return "\(hrs / 24)일 전"
            }
        }
        return "최신"
    }

    private func wrapLines(_ text: String, maxUnits: Int) -> [String] {
        var result: [String] = []
        var cur = ""
        var units = 0
        for ch in text {
            let w = ch.isASCII ? 1 : 2
            if units + w > maxUnits && !cur.isEmpty {
                result.append(cur.trimmingCharacters(in: .whitespaces))
                cur = String(ch)
                units = w
            } else {
                cur.append(ch)
                units += w
            }
        }
        if !cur.isEmpty { result.append(cur.trimmingCharacters(in: .whitespaces)) }
        return result.isEmpty ? ["(본문 없음)"] : Array(result.prefix(18))
    }
}
