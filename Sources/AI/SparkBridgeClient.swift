import Foundation

public enum SparkVoiceMode: String, Codable {
    case evenAI = "even_ai"
    case translate = "translate"
    case conversate = "conversate"
    case transcribe = "transcribe"
}

public enum SparkOSCommand: Equatable {
    case timer(seconds: Int)
    case alarm(hour: Int, minute: Int, label: String)
    case task(title: String)
    case brightness(level: Int)
    case silent(enabled: Bool)
}

public enum SparkBridgeEvent {
    case connected(host: String, latencyMs: Int, sttModel: String)
    case disconnected(reason: String)
    case sttPartial(mode: SparkVoiceMode, text: String, elapsedMs: Double)
    case sttFinal(mode: SparkVoiceMode, text: String, language: String, elapsedMs: Double)
    case aiStatus(mode: SparkVoiceMode, status: String)
    case aiDelta(mode: SparkVoiceMode, fullText: String)
    case aiDone(mode: SparkVoiceMode, text: String, commands: [SparkOSCommand], durationSeconds: Double?)
    case error(message: String)
}

/// Real-time WebSocket client streaming raw G2 LC3 audio (0x6402) over Tailscale to DGX Spark 2x:
/// tries `spark01` (100.101.25.64:8765) first and automatically fails over to `spark02` (100.101.25.65:8765).
public final class SparkBridgeClient: ObservableObject {
    @Published public var primaryEndpoint: String {
        didSet { UserDefaults.standard.set(primaryEndpoint, forKey: Self.primaryKey) }
    }
    @Published public var fallbackEndpoint: String {
        didSet { UserDefaults.standard.set(fallbackEndpoint, forKey: Self.fallbackKey) }
    }
    @Published public var effort: String {
        didSet { UserDefaults.standard.set(effort, forKey: Self.effortKey) }
    }

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isConnecting: Bool = false
    @Published public private(set) var activeNodeLabel: String = "미연결"
    @Published public private(set) var activeHostAddress: String = ""
    @Published public private(set) var latencyMs: Int = 0
    @Published public private(set) var sttModelName: String = "-"
    @Published public private(set) var lastError: String?

    public var onEvent: ((SparkBridgeEvent) -> Void)?
    public var onLog: ((String) -> Void)?

    private static let primaryKey = "g2_spark_primary_endpoint"
    private static let fallbackKey = "g2_spark_fallback_endpoint"
    private static let effortKey = "g2_spark_agy_effort"

    private let workQueue = DispatchQueue(label: "com.g2remote.os.sparkbridge", qos: .userInitiated)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 0 // long-lived WebSocket
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private var wsTask: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var audioBatchBuffer = Data()
    private var pendingAudioStart: (mode: SparkVoiceMode, srcLang: String, dstLang: String)?
    private var isStreamingAudio = false

    public init() {
        self.primaryEndpoint = UserDefaults.standard.string(forKey: Self.primaryKey) ?? "100.101.25.64:8765"
        self.fallbackEndpoint = UserDefaults.standard.string(forKey: Self.fallbackKey) ?? "100.101.25.65:8765"
        self.effort = UserDefaults.standard.string(forKey: Self.effortKey) ?? "low"
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection & Failover (spark01 -> spark02)

    public func connectWithFailover(completion: ((Bool) -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.isConnected && self.wsTask != nil {
                DispatchQueue.main.async { completion?(true) }
                return
            }
            DispatchQueue.main.async {
                self.isConnecting = true
                self.lastError = nil
            }

            let candidates: [(label: String, host: String)] = [
                ("spark01", self.normalizedHost(self.primaryEndpoint)),
                ("spark02", self.normalizedHost(self.fallbackEndpoint))
            ].filter { !$0.host.isEmpty }

            self.probeAndConnect(candidates: candidates, index: 0, completion: completion)
        }
    }

    public func disconnect() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.wsTask?.cancel(with: .normalClosure, reason: nil)
            self.wsTask = nil
            self.isStreamingAudio = false
            self.audioBatchBuffer.removeAll()
            self.pendingAudioStart = nil
            DispatchQueue.main.async {
                self.isConnected = false
                self.isConnecting = false
                self.activeNodeLabel = "미연결"
                self.activeHostAddress = ""
            }
        }
    }

    // MARK: - Live Audio & Prompt Streaming

    public func startAudioStream(mode: SparkVoiceMode, srcLang: String = "auto", dstLang: String = "ko") {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.audioBatchBuffer.removeAll(keepingCapacity: true)
            self.isStreamingAudio = true

            if self.isConnected, self.wsTask != nil {
                self.sendStartAudioJSON(mode: mode, srcLang: srcLang, dstLang: dstLang)
            } else {
                // Buffer early LC3 audio while establishing failover WebSocket so zero syllables are dropped!
                self.pendingAudioStart = (mode, srcLang, dstLang)
                self.connectWithFailover { [weak self] ok in
                    guard let self else { return }
                    self.workQueue.async {
                        guard ok, let pending = self.pendingAudioStart else {
                            if !ok {
                                self.isStreamingAudio = false
                                self.audioBatchBuffer.removeAll()
                                self.pendingAudioStart = nil
                                self.emitEvent(.error(message: "DGX Spark(64/65) 연결 실패 — Tailscale 상태를 확인하세요"))
                            }
                            return
                        }
                        self.pendingAudioStart = nil
                        self.sendStartAudioJSON(mode: pending.mode, srcLang: pending.srcLang, dstLang: pending.dstLang)
                        self.flushAudioBufferLocked(force: true)
                    }
                }
            }
        }
    }

    /// Streams raw G2 0x6402 LC3 bytes (typically 200B = 50ms per BLE notify) in crisp 150ms batches.
    public func sendAudioChunk(_ rawLC3Bytes: Data) {
        guard !rawLC3Bytes.isEmpty else { return }
        workQueue.async { [weak self] in
            guard let self, self.isStreamingAudio else { return }
            self.audioBatchBuffer.append(rawLC3Bytes)
            // Cap pre-connect buffer at ~5 seconds of LC3 (20KB) to avoid memory growth if offline
            if self.audioBatchBuffer.count > 20_000 {
                self.audioBatchBuffer.removeFirst(self.audioBatchBuffer.count - 20_000)
            }
            if self.pendingAudioStart == nil {
                self.flushAudioBufferLocked(force: false)
            }
        }
    }

    public func stopAudioStream() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.isStreamingAudio = false
            self.pendingAudioStart = nil
            self.flushAudioBufferLocked(force: true)
            self.sendJSONLocked(["type": "stop_audio"])
        }
    }

    public func sendTextPrompt(mode: SparkVoiceMode, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let sendNow = {
                self.sendJSONLocked([
                    "type": "text_prompt",
                    "mode": mode.rawValue,
                    "text": trimmed,
                    "effort": self.effort
                ])
            }
            if self.isConnected, self.wsTask != nil {
                sendNow()
            } else {
                self.connectWithFailover { [weak self] ok in
                    guard let self else { return }
                    if ok {
                        self.workQueue.async { sendNow() }
                    } else {
                        self.emitEvent(.error(message: "DGX Spark 연결 실패 (64/65)"))
                    }
                }
            }
        }
    }

    public func resetSession(mode: SparkVoiceMode) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.sendJSONLocked(["type": "reset_session", "mode": mode.rawValue])
        }
    }

    // MARK: - Internal Failover Probe & WebSocket Loop

    private func normalizedHost(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : "\(trimmed):8765"
    }

    private func probeAndConnect(
        candidates: [(label: String, host: String)],
        index: Int,
        completion: ((Bool) -> Void)?
    ) {
        guard index < candidates.count else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.isConnecting = false
                self.activeNodeLabel = "연결 실패"
                self.lastError = "spark01 / spark02 응답 없음"
                completion?(false)
            }
            emitLog("[Spark] spark01 / spark02 모두 연결 실패 (Tailscale 및 브릿지 실행 확인)")
            return
        }

        let target = candidates[index]
        guard let healthURL = URL(string: "http://\(target.host)/health") else {
            probeAndConnect(candidates: candidates, index: index + 1, completion: completion)
            return
        }

        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 1.8
        let startedAt = Date()
        emitLog("[Spark] \(target.label) (\(target.host)) 연결 확인 중...")

        session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            self.workQueue.async {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200, let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (json["ok"] as? Bool) == true
                {
                    let rtt = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
                    let hostName = (json["host"] as? String) ?? target.label
                    let sttModel = (json["stt_model"] as? String) ?? "large-v3-turbo"
                    self.openWebSocketLocked(label: hostName, host: target.host, rttMs: rtt, sttModel: sttModel, completion: completion)
                } else {
                    self.emitLog("[Spark] \(target.label) 응답 없음 → 다음 노드로 페일오버")
                    self.probeAndConnect(candidates: candidates, index: index + 1, completion: completion)
                }
            }
        }.resume()
    }

    private func openWebSocketLocked(
        label: String,
        host: String,
        rttMs: Int,
        sttModel: String,
        completion: ((Bool) -> Void)?
    ) {
        guard let wsURL = URL(string: "ws://\(host)/ws") else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        wsTask?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: wsURL)
        wsTask = task
        task.resume()

        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
            self.activeNodeLabel = label
            self.activeHostAddress = host
            self.latencyMs = rttMs
            self.sttModelName = sttModel
            self.lastError = nil
            completion?(true)
        }
        emitLog("[Spark] \(label) (\(host)) 실시간 연결 완료 (\(rttMs)ms · \(sttModel))")
        emitEvent(.connected(host: label, latencyMs: rttMs, sttModel: sttModel))

        startPingTimerLocked()
        receiveLoopLocked(task: task)
    }

    private func startPingTimerLocked() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.sendJSONLocked(["type": "ping"])
        }
        timer.resume()
        pingTimer = timer
    }

    private func receiveLoopLocked(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                guard self.wsTask === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleIncomingJSON(text)
                    }
                    self.receiveLoopLocked(task: task)
                case .failure(let err):
                    self.handleSocketDropLocked(reason: err.localizedDescription)
                }
            }
        }
    }

    private func handleSocketDropLocked(reason: String) {
        pingTimer?.cancel()
        pingTimer = nil
        wsTask = nil
        let wasConnected = isConnected
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.activeNodeLabel = "재연결 대기"
        }
        if wasConnected {
            emitLog("[Spark] WebSocket 연결 끊김: \(reason)")
            emitEvent(.disconnected(reason: reason))
        }
    }

    private func sendStartAudioJSON(mode: SparkVoiceMode, srcLang: String, dstLang: String) {
        sendJSONLocked([
            "type": "start_audio",
            "mode": mode.rawValue,
            "codec": "lc3_16k",
            "src_lang": srcLang,
            "dst_lang": dstLang,
            "effort": effort
        ])
    }

    private func flushAudioBufferLocked(force: Bool) {
        guard let wsTask, isConnected else { return }
        // 600 bytes = 150ms of 16kHz 32kbps LC3 audio -> fast real-time streaming without socket churn
        let minBatch = force ? 1 : 600
        guard audioBatchBuffer.count >= minBatch else { return }
        let payload = audioBatchBuffer
        audioBatchBuffer.removeAll(keepingCapacity: true)
        wsTask.send(.data(payload)) { _ in }
    }

    private func sendJSONLocked(_ dict: [String: Any]) {
        guard let wsTask, isConnected,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8)
        else { return }
        wsTask.send(.string(text)) { _ in }
    }

    // MARK: - Incoming Bridge Event Parser

    private func handleIncomingJSON(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        let mode = SparkVoiceMode(rawValue: json["mode"] as? String ?? "even_ai") ?? .evenAI

        switch type {
        case "stt_partial":
            let text = json["text"] as? String ?? ""
            let ms = json["elapsed_ms"] as? Double ?? 0
            if !text.isEmpty {
                emitEvent(.sttPartial(mode: mode, text: text, elapsedMs: ms))
            }
        case "stt_final":
            let text = json["text"] as? String ?? ""
            let lang = json["language"] as? String ?? "ko"
            let ms = json["elapsed_ms"] as? Double ?? 0
            emitEvent(.sttFinal(mode: mode, text: text, language: lang, elapsedMs: ms))
        case "ai_status":
            let status = json["status"] as? String ?? "처리 중..."
            emitEvent(.aiStatus(mode: mode, status: status))
        case "ai_delta":
            let full = json["full_text"] as? String ?? ""
            emitEvent(.aiDelta(mode: mode, fullText: full))
        case "ai_done":
            let text = json["text"] as? String ?? ""
            let dur = json["duration_s"] as? Double
            let cmds = parseCommands(json["commands"] as? [[String: Any]] ?? [])
            emitEvent(.aiDone(mode: mode, text: text, commands: cmds, durationSeconds: dur))
        case "error":
            let msg = json["message"] as? String ?? "알 수 없는 브릿지 오류"
            DispatchQueue.main.async { self.lastError = msg }
            emitEvent(.error(message: msg))
        default:
            break
        }
    }

    private func parseCommands(_ rawList: [[String: Any]]) -> [SparkOSCommand] {
        var out: [SparkOSCommand] = []
        for item in rawList {
            guard let cmd = item["cmd"] as? String else { continue }
            switch cmd {
            case "timer":
                if let secs = item["seconds"] as? Int, secs > 0 {
                    out.append(.timer(seconds: secs))
                }
            case "alarm":
                if let h = item["hour"] as? Int, let m = item["minute"] as? Int {
                    let label = item["label"] as? String ?? "음성 알람"
                    out.append(.alarm(hour: h, minute: m, label: label))
                }
            case "task":
                if let title = item["title"] as? String, !title.isEmpty {
                    out.append(.task(title: title))
                }
            case "brightness":
                if let lvl = item["level"] as? Int {
                    out.append(.brightness(level: max(1, min(50, lvl))))
                }
            case "silent":
                if let en = item["enabled"] as? Bool {
                    out.append(.silent(enabled: en))
                }
            default:
                break
            }
        }
        return out
    }

    private func emitEvent(_ event: SparkBridgeEvent) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    private func emitLog(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }
}
