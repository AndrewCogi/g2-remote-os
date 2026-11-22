import CoreBluetooth
import Foundation

public struct DiscoveredG2Pair: Identifiable, Equatable {
    public let id: String // pairId
    public var leftId: UUID?
    public var leftName: String?
    public var leftRSSI: Int?
    public var rightId: UUID?
    public var rightName: String?
    public var rightRSSI: Int?

    public var isComplete: Bool { leftId != nil && rightId != nil }
}

public enum G2ConnectionPhase: String {
    case disconnected = "연결 안 됨"
    case scanning = "안경 검색 중..."
    case connecting = "좌/우 렌즈 연결 중..."
    case handshaking = "인증 및 세션 초기화 중..."
    case connected = "연결됨 (세션 활성)"
}

/// Manages dual-lens CoreBluetooth links to Even Realities G2 glasses with:
/// - Background `bluetooth-central` State Restoration
/// - Serialized packet write queue (prevents multi-fragment reassembly corruption)
/// - Live-confirmed Auth -> Prelude -> EvenHub CreatePage / TextUpgrade -> 4s Heartbeat -> 60s Keepalive
/// - Raw LC3 microphone stream subscription on 0x6402
public final class G2BLEManager: NSObject, ObservableObject {
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var phase: G2ConnectionPhase = .disconnected
    @Published public private(set) var discoveredPairs: [DiscoveredG2Pair] = []
    @Published public private(set) var leftConnected: Bool = false
    @Published public private(set) var rightConnected: Bool = false
    @Published public private(set) var batteryLevel: Int?
    @Published public private(set) var isCharging: Bool = false
    @Published public private(set) var silentMode: Bool = false
    @Published public private(set) var brightnessLevel: Int = 25
    @Published public private(set) var firmwareLeft: String = "-"
    @Published public private(set) var firmwareRight: String = "-"
    @Published public private(set) var isMicEnabled: Bool = false
    @Published public private(set) var micPacketCount: Int = 0
    @Published public private(set) var micDurationMs: Int = 0
    @Published public private(set) var micSignalRatio: Int16 = 0
    @Published public private(set) var micDirectionDegrees: Int16 = 0
    @Published public private(set) var isScreenAsleep: Bool = false

    public var onLog: ((String) -> Void)?
    public var onGlassesEvent: ((G2DeviceEvent) -> Void)?
    public var onMicPacket: ((G2MicPacket) -> Void)?

    private let bleQueue = DispatchQueue(label: "com.g2remote.os.ble", qos: .userInitiated)
    private var central: CBCentralManager!

    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?

    private var leftWriteChar: CBCharacteristic?
    private var rightWriteChar: CBCharacteristic?
    private var leftNotifyReady = false
    private var rightNotifyReady = false

    private var assemblers: [G2Constants.LensSide: G2FrameAssembler] = [
        .left: G2FrameAssembler(),
        .right: G2FrameAssembler()
    ]

    private var magicCounter: Int = 100
    private var seqCounter: UInt8 = 10
    private var authCounter: UInt8 = 1

    private var sessionReady = false
    private var pageCreated = false
    private var lastRenderedText: String = "G2 Remote OS Ready"
    private var lastHeartbeatSentAt: Date = .distantPast
    private var heartbeatTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var handshakeStarted = false

    // Serialized write pipeline (ensures multi-fragment writes never interleave with heartbeats)
    private struct WriteTask {
        let side: G2Constants.LensSide
        let data: Data
    }
    private var writeQueue: [WriteTask] = []
    private var isDrainingWrites = false

    // Saved lens UUIDs for instant auto-reconnect
    private let defaults = UserDefaults.standard
    private let savedLeftKey = "g2_saved_left_uuid"
    private let savedRightKey = "g2_saved_right_uuid"

    // Mic recording buffer (optional raw LC3 dump)
    private var micRecordingData = Data()

    public override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.g2remote.os.g2ble.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    // MARK: - Public Controls

    public func startScan() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.central.state == .poweredOn else {
                self.emitLog("[G2] 블루투스가 꺼져 있어 스캔할 수 없습니다.")
                return
            }
            self.setPhase(.scanning)
            self.emitLog("[G2] G2 좌/우 렌즈 스캔 시작 (공식 Even 앱이 연결 중이면 먼저 종료하세요)")

            // Also inspect already-connected peripherals carrying the G2 control service.
            let connected = self.central.retrieveConnectedPeripherals(withServices: [G2Constants.serviceControl])
            for p in connected {
                self.registerDiscoveredPeripheral(p, name: p.name, rssi: -50)
            }

            // Foreground scan without service filter (G2 advertises by name + manufacturer data 0x5245).
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    public func stopScan() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if self.phase == .scanning {
                self.setPhase(.disconnected)
            }
            self.emitLog("[G2] 스캔 중지")
        }
    }

    public func connect(pair: DiscoveredG2Pair) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard let lId = pair.leftId, let rId = pair.rightId,
                  let lp = self.peripheralsById[lId], let rp = self.peripheralsById[rId]
            else {
                self.emitLog("[G2] 좌/우 양쪽 렌즈가 모두 검색되어야 연결할 수 있습니다.")
                return
            }
            self.central.stopScan()
            self.defaults.set(lId.uuidString, forKey: self.savedLeftKey)
            self.defaults.set(rId.uuidString, forKey: self.savedRightKey)
            self.connectPeripherals(left: lp, right: rp)
        }
    }

    public func reconnectSavedPair() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.central.state == .poweredOn else { return }
            guard let lStr = self.defaults.string(forKey: self.savedLeftKey),
                  let rStr = self.defaults.string(forKey: self.savedRightKey),
                  let lId = UUID(uuidString: lStr),
                  let rId = UUID(uuidString: rStr)
            else {
                self.emitLog("[G2] 저장된 안경 페어 정보가 없습니다. 먼저 스캔해 주세요.")
                return
            }
            let retrieved = self.central.retrievePeripherals(withIdentifiers: [lId, rId])
            guard let lp = retrieved.first(where: { $0.identifier == lId }),
                  let rp = retrieved.first(where: { $0.identifier == rId })
            else {
                self.emitLog("[G2] 저장된 렌즈 핸들을 찾지 못해 스캔을 시작합니다.")
                self.startScan()
                return
            }
            self.peripheralsById[lId] = lp
            self.peripheralsById[rId] = rp
            self.emitLog("[G2] 저장된 좌/우 렌즈로 자동 재연결 시도...")
            self.connectPeripherals(left: lp, right: rp)
        }
    }

    public func disconnect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.stopTimers()
            self.sessionReady = false
            self.pageCreated = false
            self.handshakeStarted = false
            self.writeQueue.removeAll()

            if let lp = self.leftPeripheral { self.central.cancelPeripheralConnection(lp) }
            if let rp = self.rightPeripheral { self.central.cancelPeripheralConnection(rp) }
            self.leftNotifyReady = false
            self.rightNotifyReady = false
            self.leftWriteChar = nil
            self.rightWriteChar = nil
            DispatchQueue.main.async {
                self.leftConnected = false
                self.rightConnected = false
                self.isMicEnabled = false
                self.isScreenAsleep = false
            }
            self.setPhase(.disconnected)
            self.emitLog("[G2] 연결 해제됨")
        }
    }

    /// Renders full-screen text on the G2 576x288 EvenHub canvas.
    /// Automatically recovers the page if the glasses slept during background idle.
    public func renderScreenText(_ text: String) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.lastRenderedText = text
            guard self.sessionReady else { return }

            let now = Date()
            let heartbeatStale = now.timeIntervalSince(self.lastHeartbeatSentAt) > 9.0

            if self.isScreenAsleep || !self.pageCreated || heartbeatStale {
                DispatchQueue.main.async { self.isScreenAsleep = false }
                self.startHeartbeatTimer()
                self.enqueue(side: .right, data: G2Commands.preludeFrame)
                let createPb = G2Commands.buildCreateInputPage(magic: self.nextMagic(), text: text)
                self.enqueueProtobuf(createPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
                self.pageCreated = true
                self.emitLog("[G2] 화면 깨우기/페이지 생성 완료")
            } else {
                let upgradePb = G2Commands.buildTextUpgrade(magic: self.nextMagic(), text: text)
                self.enqueueProtobuf(upgradePb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            }
        }
    }

    /// Toggles the G2 built-in microphone (SID 0xE0 cmd 15). Raw LC3 streams on 0x6402.
    public func setMicrophoneEnabled(_ enabled: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.micRecordingData.removeAll(keepingCapacity: true)
                DispatchQueue.main.async {
                    self.micPacketCount = 0
                    self.micDurationMs = 0
                }
            }
            DispatchQueue.main.async { self.isMicEnabled = enabled }
            guard self.sessionReady else {
                self.emitLog("[G2] 마이크 \(enabled ? "ON" : "OFF") (오프라인 시뮬레이션)")
                return
            }
            if !self.pageCreated {
                self.renderScreenText(self.lastRenderedText)
            }
            let pb = G2Commands.buildAudioControl(magic: self.nextMagic(), enable: enabled)
            self.enqueueProtobuf(pb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 내장 마이크 \(enabled ? "켜기 (0x6402 LC3 수신 대기)" : "끄기") 명령 전송")
        }
    }

    /// Exports the last recorded raw LC3 bytes to the app's Documents folder.
    public func saveLastMicRecording() -> URL? {
        var snapshot = Data()
        bleQueue.sync { snapshot = self.micRecordingData }
        guard !snapshot.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "g2_mic_\(formatter.string(from: Date())).lc3"
        guard let url = docs?.appendingPathComponent(filename) else { return nil }
        do {
            try snapshot.write(to: url)
            emitLog("[G2] 마이크 녹음 저장 완료: \(filename) (\(snapshot.count) bytes)")
            return url
        } catch {
            emitLog("[G2] 녹음 저장 실패: \(error.localizedDescription)")
            return nil
        }
    }

    public func setBrightness(_ level: Int) {
        let clamped = max(1, min(50, level))
        DispatchQueue.main.async { self.brightnessLevel = clamped }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildBrightness(magic: self.nextMagic(), level: clamped)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 밝기 설정: \(clamped)/50")
        }
    }

    public func setSilentMode(_ enabled: Bool) {
        DispatchQueue.main.async { self.silentMode = enabled }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildSilentMode(magic: self.nextMagic(), enabled: enabled)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 무음 모드: \(enabled ? "ON" : "OFF")")
        }
    }

    public func querySettings() {
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildReadSettings(magic: self.nextMagic())
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 기기 상태(배터리/밝기/펌웨어) 조회 요청")
        }
    }

    /// Puts the EvenHub canvas to sleep (stops 4s heartbeat) or wakes it back up immediately.
    public func setScreenAsleep(_ asleep: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.isScreenAsleep = asleep }
            if asleep {
                self.heartbeatTimer?.cancel()
                self.heartbeatTimer = nil
                self.pageCreated = false
                self.emitLog("[G2] 화면 절전 요청 (EvenHub 하트비트 정지 → ~5초 후 절전)")
            } else if self.sessionReady {
                self.renderScreenText(self.lastRenderedText)
            }
        }
    }

    // MARK: - Internal Connection & Handshake

    private func connectPeripherals(left: CBPeripheral, right: CBPeripheral) {
        stopTimers()
        sessionReady = false
        pageCreated = false
        handshakeStarted = false
        leftNotifyReady = false
        rightNotifyReady = false
        leftWriteChar = nil
        rightWriteChar = nil
        assemblers[.left]?.reset()
        assemblers[.right]?.reset()

        leftPeripheral = left
        rightPeripheral = right
        left.delegate = self
        right.delegate = self

        setPhase(.connecting)
        central.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        central.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func maybeBeginHandshake() {
        guard !handshakeStarted,
              leftWriteChar != nil, rightWriteChar != nil,
              leftNotifyReady, rightNotifyReady
        else { return }
        handshakeStarted = true
        setPhase(.handshaking)
        emitLog("[G2] 양쪽 렌즈 GATT 준비 완료 → 인증 및 세션 시퀀스 시작")

        bleQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // 1. Auth Right, then Left (LIVE-CONFIRMED order)
            let rightAuth = G2Frame.authFrame(magic: self.nextAuthMagic())
            self.enqueue(side: .right, data: rightAuth)

            self.bleQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                let leftAuth = G2Frame.authFrame(magic: self.nextAuthMagic())
                self.enqueue(side: .left, data: leftAuth)

                // 2. Prelude on Right lens (SID 0x01)
                self.bleQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.enqueue(side: .right, data: G2Commands.preludeFrame)

                    // 3. Connect housekeeping + Initial EvenHub page + Heartbeat
                    self.bleQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { return }
                        self.enqueueProtobuf(G2Commands.buildRoleChange(magic: self.nextMagic(), role: 1), sid: G2SID.deviceConfig, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildTimeSync(magic: self.nextMagic()), sid: G2SID.deviceConfig, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildOnboardingFinish(magic: self.nextMagic()), sid: G2SID.onboarding, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildReadSettings(magic: self.nextMagic()), sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)

                        let createPb = G2Commands.buildCreateInputPage(magic: self.nextMagic(), text: self.lastRenderedText)
                        self.enqueueProtobuf(createPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)

                        self.pageCreated = true
                        self.sessionReady = true
                        self.setPhase(.connected)
                        self.startHeartbeatTimer()
                        self.startKeepaliveTimer()
                        self.emitLog("[G2] 세션 연결 완료! (4초 하트비트 + 60초 Keepalive 동작 중)")
                    }
                }
            }
        }
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 4.0, repeating: 4.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionReady, !self.isScreenAsleep else { return }
            self.lastHeartbeatSentAt = Date()
            let hb = G2Commands.buildHeartbeat(magic: self.nextMagic())
            self.enqueueProtobuf(hb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
        }
        timer.resume()
        heartbeatTimer = timer
        lastHeartbeatSentAt = Date()
    }

    private func startKeepaliveTimer() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 60.0, repeating: 60.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionReady else { return }
            let kaL = G2Commands.buildKeepalive(magic: self.nextMagic())
            self.enqueueProtobuf(kaL, sid: G2SID.deviceConfig, flag: G2Frame.flagPlain, side: .left)
            self.bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.sessionReady else { return }
                let kaR = G2Commands.buildKeepalive(magic: self.nextMagic())
                self.enqueueProtobuf(kaR, sid: G2SID.deviceConfig, flag: G2Frame.flagPlain, side: .right)
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopTimers() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Serialized BLE Write Queue

    private func enqueueProtobuf(_ pb: Data, sid: UInt8, flag: UInt8, side: G2Constants.LensSide) {
        let maxWrite: Int
        if let p = (side == .right ? rightPeripheral : leftPeripheral) {
            maxWrite = min(240, max(20, p.maximumWriteValueLength(for: .withoutResponse)))
        } else {
            maxWrite = 240
        }
        let frames = G2Frame.framePb(pb, sid: sid, flag: flag, seq: nextSeq(), maxWrite: maxWrite)
        for frame in frames {
            writeQueue.append(WriteTask(side: side, data: frame))
        }
        drainWriteQueue()
    }

    private func enqueue(side: G2Constants.LensSide, data: Data) {
        writeQueue.append(WriteTask(side: side, data: data))
        drainWriteQueue()
    }

    private func drainWriteQueue() {
        guard !isDrainingWrites else { return }
        guard !writeQueue.isEmpty else { return }
        isDrainingWrites = true

        let task = writeQueue.removeFirst()
        let peripheral = (task.side == .right) ? rightPeripheral : leftPeripheral
        let char = (task.side == .right) ? rightWriteChar : leftWriteChar

        if let peripheral, let char, peripheral.state == .connected {
            peripheral.writeValue(task.data, for: char, type: .withoutResponse)
        }

        // 30ms pacing between BLE write-without-response packets keeps the firmware reassembly buffer healthy.
        bleQueue.asyncAfter(deadline: .now() + 0.030) { [weak self] in
            guard let self else { return }
            self.isDrainingWrites = false
            self.drainWriteQueue()
        }
    }

    // MARK: - Helpers

    private func nextMagic() -> Int {
        magicCounter = (magicCounter % 255) + 1
        return magicCounter
    }

    private func nextSeq() -> UInt8 {
        seqCounter &+= 1
        return seqCounter
    }

    private func nextAuthMagic() -> UInt8 {
        let v = authCounter
        authCounter = (authCounter >= 126) ? 1 : (authCounter + 1)
        return v
    }

    private func side(of peripheral: CBPeripheral) -> G2Constants.LensSide? {
        if peripheral.identifier == rightPeripheral?.identifier { return .right }
        if peripheral.identifier == leftPeripheral?.identifier { return .left }
        return nil
    }

    private func setPhase(_ newPhase: G2ConnectionPhase) {
        DispatchQueue.main.async { self.phase = newPhase }
    }

    private func emitLog(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }

    private func registerDiscoveredPeripheral(_ peripheral: CBPeripheral, name: String?, rssi: Int) {
        guard let parsed = G2Constants.parseLensName(name) else { return }
        peripheralsById[peripheral.identifier] = peripheral
        DispatchQueue.main.async {
            var pairs = self.discoveredPairs
            if let idx = pairs.firstIndex(where: { $0.id == parsed.pairId }) {
                if parsed.side == .left {
                    pairs[idx].leftId = peripheral.identifier
                    pairs[idx].leftName = name
                    pairs[idx].leftRSSI = rssi
                } else {
                    pairs[idx].rightId = peripheral.identifier
                    pairs[idx].rightName = name
                    pairs[idx].rightRSSI = rssi
                }
            } else {
                var newPair = DiscoveredG2Pair(id: parsed.pairId)
                if parsed.side == .left {
                    newPair.leftId = peripheral.identifier
                    newPair.leftName = name
                    newPair.leftRSSI = rssi
                } else {
                    newPair.rightId = peripheral.identifier
                    newPair.rightName = name
                    newPair.rightRSSI = rssi
                }
                pairs.append(newPair)
            }
            self.discoveredPairs = pairs
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension G2BLEManager: CBCentralManagerDelegate {
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in peripherals {
                peripheralsById[p.identifier] = p
                p.delegate = self
                if let parsed = G2Constants.parseLensName(p.name) {
                    if parsed.side == .left { leftPeripheral = p }
                    else { rightPeripheral = p }
                }
            }
            emitLog("[G2] 백그라운드 BLE 상태 복원 완료 (\(peripherals.count)개 렌즈)")
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let st = central.state
        DispatchQueue.main.async { self.bluetoothState = st }
        if st == .poweredOn {
            emitLog("[G2] CoreBluetooth 준비 완료")
            // If peripherals were restored in connected state, re-discover their services.
            for p in [rightPeripheral, leftPeripheral].compactMap({ $0 }) where p.state == .connected {
                p.discoverServices([G2Constants.serviceControl, G2Constants.serviceAudio])
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        registerDiscoveredPeripheral(peripheral, name: localName, rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let lensSide = side(of: peripheral) else { return }
        DispatchQueue.main.async {
            if lensSide == .left { self.leftConnected = true }
            else { self.rightConnected = true }
        }
        emitLog("[G2] \(lensSide.displayName) 연결됨 → 서비스 탐색 중")
        peripheral.discoverServices([G2Constants.serviceControl, G2Constants.serviceAudio])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let lensSide = side(of: peripheral)?.displayName ?? "?"
        emitLog("[G2] \(lensSide) 연결 실패: \(error?.localizedDescription ?? "알 수 없음")")
        setPhase(.disconnected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let lensSide = side(of: peripheral) else { return }
        DispatchQueue.main.async {
            if lensSide == .left { self.leftConnected = false }
            else { self.rightConnected = false }
        }
        stopTimers()
        sessionReady = false
        pageCreated = false
        handshakeStarted = false
        setPhase(.disconnected)
        emitLog("[G2] \(lensSide.displayName) 연결 끊김 (\(error?.localizedDescription ?? "정상 종료"))")

        // Automatic background reconnection on unexpected drops.
        if error != nil {
            emitLog("[G2] 예기치 않은 끊김 → 자동 재연결 예약")
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G2BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            if service.uuid == G2Constants.serviceControl {
                peripheral.discoverCharacteristics([G2Constants.charWrite, G2Constants.charNotify], for: service)
            } else if service.uuid == G2Constants.serviceAudio {
                peripheral.discoverCharacteristics([G2Constants.charAudioNotify], for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics, let lensSide = side(of: peripheral) else { return }
        for char in chars {
            if char.uuid == G2Constants.charWrite {
                if lensSide == .left { leftWriteChar = char }
                else { rightWriteChar = char }
            } else if char.uuid == G2Constants.charNotify {
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == G2Constants.charAudioNotify {
                peripheral.setNotifyValue(true, for: char)
            }
        }
        maybeBeginHandshake()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let lensSide = side(of: peripheral) else { return }
        if let error {
            emitLog("[G2] \(lensSide.displayName) Notify 구독 오류 (\(characteristic.uuid.uuidString.suffix(4))): \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == G2Constants.charNotify && characteristic.isNotifying {
            if lensSide == .left { leftNotifyReady = true }
            else { rightNotifyReady = true }
            maybeBeginHandshake()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, let lensSide = side(of: peripheral) else { return }

        // 1. Raw LC3 Microphone stream (0x6402)
        if characteristic.uuid == G2Constants.charAudioNotify {
            guard let mic = G2MicPacket.parse(data) else { return }
            // Prefer Left lens for recording to avoid duplicating frames if both lenses emit.
            if lensSide == .left || !leftConnected {
                micRecordingData.append(mic.rawAudioBytes)
                DispatchQueue.main.async {
                    self.micPacketCount += 1
                    self.micDurationMs = self.micPacketCount * 50
                    if let sig = mic.signalRatio { self.micSignalRatio = sig }
                    if let doa = mic.directionDegrees { self.micDirectionDegrees = doa }
                    self.onMicPacket?(mic)
                }
            }
            return
        }

        // 2. Control & event replies (0x5402)
        guard characteristic.uuid == G2Constants.charNotify else { return }
        guard let assembled = assemblers[lensSide]?.feed(data),
              let frame = G2Frame.parseFrame(assembled)
        else { return }

        switch frame.sid {
        case G2SID.evenHub:
            if let event = G2Commands.decodeDeviceEvent(frame.payload) {
                emitLog("[G2 템플] \(event.source): \(event.eventType.label)")
                DispatchQueue.main.async { self.onGlassesEvent?(event) }
            }
        case G2SID.settings:
            if let readback = G2Commands.decodeSettingsReadback(frame.payload) {
                DispatchQueue.main.async {
                    if let b = readback.battery { self.batteryLevel = b }
                    if let c = readback.charging { self.isCharging = c }
                    if let s = readback.silentMode { self.silentMode = s }
                    if let br = readback.brightnessLevel { self.brightnessLevel = br }
                    if let l = readback.leftFirmware { self.firmwareLeft = l }
                    if let r = readback.rightFirmware { self.firmwareRight = r }
                }
            }
        default:
            break
        }
    }
}
