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
    case connected = "연결됨"
}

/// Manages dual-lens CoreBluetooth links to Even Realities G2 glasses with:
/// - Background `bluetooth-central` State Restoration & unexpected-drop auto-reconnection
/// - Always-On OS Guard: 3.5s heartbeat + iOS suspension gap detection + stock-OS exit interception
/// - Multi-container EvenHub rendering (`cmd 0` Create, `cmd 7` Rebuild, `cmd 5` Text diff, `cmd 3` 4-bit BMP image upload)
/// - Live G2 IMU stream (`cmd 19`) for Head-Up Raise-to-Wake inside our custom OS
/// - Full `SID 0x09` / `0x20` hardware settings & `SID 0x04` ANCS notification whitelist control
/// - Raw LC3 microphone stream subscription on `0x6402`
public final class G2BLEManager: NSObject, ObservableObject {
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var phase: G2ConnectionPhase = .disconnected
    @Published public private(set) var discoveredPairs: [DiscoveredG2Pair] = []
    @Published public private(set) var leftConnected: Bool = false
    @Published public private(set) var rightConnected: Bool = false
    @Published public private(set) var hasSavedPair: Bool = false
    @Published public private(set) var alwaysStayInCustomOS: Bool = true
    @Published public private(set) var batteryLevel: Int?
    @Published public private(set) var isCharging: Bool = false
    @Published public private(set) var silentMode: Bool = false
    @Published public private(set) var brightnessLevel: Int = 25
    @Published public private(set) var brightnessAuto: Bool = false
    @Published public private(set) var displayHeight: Int = 10
    @Published public private(set) var displayDistance: Int = 10
    @Published public private(set) var headUpEnabled: Bool = false
    @Published public private(set) var headUpAngle: Int = 20
    @Published public private(set) var wearDetection: Bool = true
    @Published public private(set) var ancsEnabled: Bool = true
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
    public var onImuSample: ((G2ImuSample) -> Void)?
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
    private var imageMapSessionId: Int = 1

    private var sessionReady = false
    private var pageCreated = false
    private var screenAsleepLocked = false
    private var alwaysStayLocked = true
    private var micEnabledLocked = false
    private var imuDesiredLocked = false
    private var imuActiveLocked = false
    private var ancsEnabledLocked = true
    private var userInitiatedDisconnect = false
    private var autoReconnectAttemptedOnBoot = false

    private var lastRenderedPage: G2PageSpec = .blankTransparent()
    private var activeLayoutKey: String?
    private var lastPushedTexts: [Int: String] = [:]
    private var uploadedImageHashes: [Int: String] = [:]

    private var lastHeartbeatSentAt: Date = .distantPast
    private var lastPageCreatedAt: Date = .distantPast
    private var recentExitRecoveries: [Date] = []
    private var exitRecoveryWorkItem: DispatchWorkItem?
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
        let saved = (defaults.string(forKey: savedLeftKey) != nil && defaults.string(forKey: savedRightKey) != nil)
        self.hasSavedPair = saved
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.g2remote.os.g2ble.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    // MARK: - Connection Controls

    public func setAlwaysStayInCustomOS(_ enabled: Bool) {
        DispatchQueue.main.async { self.alwaysStayInCustomOS = enabled }
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.alwaysStayLocked = enabled
            if enabled && self.sessionReady {
                self.screenAsleepLocked = false
                DispatchQueue.main.async { self.isScreenAsleep = false }
                self.ensureScreenActiveLocked(forceRecreate: !self.pageCreated, reason: "항시 OS 유지 활성화")
            }
        }
    }

    public func startScan() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.central.state == .poweredOn else {
                self.emitLog("[G2] 블루투스가 꺼져 있어 스캔할 수 없습니다.")
                return
            }
            if !self.sessionReady {
                if let lp = self.leftPeripheral, lp.state == .connecting {
                    self.central.cancelPeripheralConnection(lp)
                }
                if let rp = self.rightPeripheral, rp.state == .connecting {
                    self.central.cancelPeripheralConnection(rp)
                }
            }
            self.setPhase(.scanning)
            self.emitLog("[G2] G2 좌/우 렌즈 스캔 시작 (공식 Even 앱이 연결 중이면 먼저 종료하세요)")

            let connected = self.central.retrieveConnectedPeripherals(withServices: [G2Constants.serviceControl])
            for p in connected {
                self.registerDiscoveredPeripheral(p, name: p.name, rssi: -50)
            }

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
            self.userInitiatedDisconnect = false
            self.defaults.set(lId.uuidString, forKey: self.savedLeftKey)
            self.defaults.set(rId.uuidString, forKey: self.savedRightKey)
            DispatchQueue.main.async { self.hasSavedPair = true }
            self.connectPeripherals(left: lp, right: rp)
        }
    }

    public func reconnectSavedPair(fallbackToScan: Bool = true) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.central.state == .poweredOn else { return }
            guard let lStr = self.defaults.string(forKey: self.savedLeftKey),
                  let rStr = self.defaults.string(forKey: self.savedRightKey),
                  let lId = UUID(uuidString: lStr),
                  let rId = UUID(uuidString: rStr)
            else {
                if fallbackToScan {
                    self.emitLog("[G2] 저장된 안경 페어 정보가 없습니다. 먼저 스캔해 주세요.")
                }
                return
            }
            let retrieved = self.central.retrievePeripherals(withIdentifiers: [lId, rId])
            guard let lp = retrieved.first(where: { $0.identifier == lId }),
                  let rp = retrieved.first(where: { $0.identifier == rId })
            else {
                if fallbackToScan {
                    self.emitLog("[G2] 저장된 렌즈 핸들을 찾지 못해 스캔을 시작합니다.")
                    self.startScan()
                }
                return
            }
            self.userInitiatedDisconnect = false
            self.peripheralsById[lId] = lp
            self.peripheralsById[rId] = rp
            self.emitLog("[G2] 저장된 좌/우 렌즈로 자동 재연결 시도...")
            self.connectPeripherals(left: lp, right: rp)
        }
    }

    public func disconnect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.userInitiatedDisconnect = true
            self.exitRecoveryWorkItem?.cancel()
            self.exitRecoveryWorkItem = nil
            self.stopTimers()
            self.sessionReady = false
            self.pageCreated = false
            self.activeLayoutKey = nil
            self.lastPushedTexts.removeAll()
            self.uploadedImageHashes.removeAll()
            self.handshakeStarted = false
            self.micEnabledLocked = false
            self.imuActiveLocked = false
            self.screenAsleepLocked = false
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

    public func ensureScreenActive(forceRecreate: Bool = false) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if self.sessionReady {
                self.ensureScreenActiveLocked(
                    forceRecreate: forceRecreate,
                    reason: forceRecreate ? "수동 화면 복구" : "포그라운드 복귀 화면 확인"
                )
            } else if !self.userInitiatedDisconnect && self.central.state == .poweredOn && self.phase == .disconnected {
                self.reconnectSavedPair(fallbackToScan: false)
            }
        }
    }

    // MARK: - Multi-Container & 4-bit Image Display Rendering

    /// Renders a multi-container G2PageSpec onto the 576x288 EvenHub canvas.
    /// Uses fast differential `cmd 5` text upgrades when layout is unchanged, `cmd 7` rebuild on layout change,
    /// and cached `cmd 3` 4-bit BMP fragment uploads for changed pixel graphics.
    public func renderPage(_ page: G2PageSpec) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.lastRenderedPage = page
            guard self.sessionReady else { return }

            let now = Date()
            let heartbeatStale = now.timeIntervalSince(self.lastHeartbeatSentAt) > 8.5

            if self.screenAsleepLocked || !self.pageCreated || heartbeatStale {
                self.recreatePageLocked(reason: "화면 깨우기/페이지 생성")
                return
            }

            if self.activeLayoutKey != page.layoutKey {
                let rebuildPb = G2Commands.buildRebuildPage(magic: self.nextMagic(), page: page)
                self.enqueueProtobuf(rebuildPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
                self.activeLayoutKey = page.layoutKey
                self.lastPushedTexts = Dictionary(uniqueKeysWithValues: page.textContainers.map { ($0.id, $0.text) })
                self.uploadedImageHashes.removeAll()
                self.enqueueImageUploadsLocked(page.imageContainers)
                return
            }

            // Same layout -> push only text/image diffs (ultra-fast ~30ms per text container)
            for tc in page.textContainers {
                if self.lastPushedTexts[tc.id] != tc.text {
                    let upgradePb = G2Commands.buildTextUpgrade(
                        magic: self.nextMagic(),
                        containerId: tc.id,
                        containerName: tc.name,
                        text: tc.text
                    )
                    self.enqueueProtobuf(upgradePb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
                    self.lastPushedTexts[tc.id] = tc.text
                }
            }
            self.enqueueImageUploadsLocked(page.imageContainers)
        }
    }

    /// Backwards-compatible plain text wrapper.
    public func renderScreenText(_ text: String) {
        let single = G2PageSpec(
            layoutKey: "plain_single",
            textContainers: [
                G2TextContainer(id: 1, name: "dashboard", x: 0, y: 0, width: 576, height: 288, text: text, captureEvents: true)
            ]
        )
        renderPage(single)
    }

    private func enqueueImageUploadsLocked(_ images: [G2ImageContainer]) {
        for img in images {
            guard uploadedImageHashes[img.id] != img.contentHash else { continue }
            uploadedImageHashes[img.id] = img.contentHash
            imageMapSessionId = (imageMapSessionId % 250) + 1
            let payloads = G2Commands.buildImageUploadMessages(
                image: img,
                mapSessionId: imageMapSessionId,
                nextMagic: { self.nextMagic() }
            )
            for pb in payloads {
                enqueueProtobuf(pb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            }
        }
    }

    // MARK: - Microphone & IMU Controls

    public func setMicrophoneEnabled(_ enabled: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if enabled == self.micEnabledLocked { return }
            self.micEnabledLocked = enabled

            if enabled {
                self.micRecordingData.removeAll(keepingCapacity: true)
                DispatchQueue.main.async {
                    self.micPacketCount = 0
                    self.micDurationMs = 0
                }
            }
            DispatchQueue.main.async { self.isMicEnabled = enabled }
            guard self.sessionReady else {
                self.emitLog("[G2] 마이크 \(enabled ? "열기" : "끄기") (오프라인)")
                return
            }
            if !self.pageCreated || self.screenAsleepLocked {
                self.recreatePageLocked(reason: "마이크 시작 전 세션 복구")
            }
            let pb = G2Commands.buildAudioControl(magic: self.nextMagic(), enable: enabled)
            self.enqueueProtobuf(pb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 내장 마이크 \(enabled ? "열기 (0x6402 LC3)" : "끄기")")
        }
    }

    public func setImuStreaming(_ enabled: Bool, reportFreqMs: Int = 250) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.imuDesiredLocked = enabled
            guard self.sessionReady else { return }
            if enabled == self.imuActiveLocked { return }
            self.imuActiveLocked = enabled
            let pb = G2Commands.buildImuControl(magic: self.nextMagic(), enable: enabled, reportFreqMs: reportFreqMs)
            self.enqueueProtobuf(pb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] IMU 센서 스트림 \(enabled ? "시작 (\(reportFreqMs)ms)" : "중지")")
        }
    }

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
            emitLog("[G2] 마이크 녹음 저장: \(filename) (\(snapshot.count) bytes)")
            return url
        } catch {
            emitLog("[G2] 녹음 저장 실패: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Full Hardware Settings (SID 0x09 / 0x20 / 0x04)

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

    public func setAutoBrightness(_ enabled: Bool) {
        DispatchQueue.main.async { self.brightnessAuto = enabled }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildAutoBrightness(magic: self.nextMagic(), enabled: enabled)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 자동 밝기: \(enabled ? "ON" : "OFF")")
        }
    }

    public func setDisplayHeight(_ level: Int) {
        let clamped = max(0, min(20, level))
        DispatchQueue.main.async { self.displayHeight = clamped }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildDisplayHeight(magic: self.nextMagic(), level: clamped)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 화면 높이(Y): \(clamped)/20")
        }
    }

    public func setDisplayDistance(_ level: Int) {
        let clamped = max(0, min(20, level))
        DispatchQueue.main.async { self.displayDistance = clamped }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildDisplayDistance(magic: self.nextMagic(), level: clamped)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 화면 거리(X): \(clamped)/20")
        }
    }

    public func setHeadUp(enabled: Bool, angle: Int) {
        let clamped = max(0, min(60, angle))
        DispatchQueue.main.async {
            self.headUpEnabled = enabled
            self.headUpAngle = clamped
        }
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.imuDesiredLocked = enabled
            guard self.sessionReady else { return }
            let pb = G2Commands.buildHeadUp(magic: self.nextMagic(), enabled: enabled, angle: clamped)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            if enabled != self.imuActiveLocked {
                self.imuActiveLocked = enabled
                let imuPb = G2Commands.buildImuControl(magic: self.nextMagic(), enable: enabled, reportFreqMs: 250)
                self.enqueueProtobuf(imuPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
            }
            self.emitLog("[G2] 들어깨우기: \(enabled ? "ON (\(clamped)°)" : "OFF")")
        }
    }

    public func setWearDetection(_ enabled: Bool) {
        DispatchQueue.main.async { self.wearDetection = enabled }
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildWearDetection(magic: self.nextMagic(), enabled: enabled)
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 착용 감지: \(enabled ? "ON" : "OFF")")
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

    public func setAncsNotifications(enabled: Bool) {
        DispatchQueue.main.async { self.ancsEnabled = enabled }
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.ancsEnabledLocked = enabled
            guard self.sessionReady else { return }
            let ctrlPb = G2Commands.buildNotificationCtrl(magic: self.nextMagic(), enable: enabled, autoDisplay: enabled, dispTime: 5, dnd: !enabled)
            self.enqueueProtobuf(ctrlPb, sid: G2SID.notification, flag: G2Frame.flagRequest, side: .right)
            if enabled {
                let wlPb = G2Commands.buildWhitelistDisable(magic: self.nextMagic(), disable: true)
                self.enqueueProtobuf(wlPb, sid: G2SID.notification, flag: G2Frame.flagRequest, side: .right)
            }
            self.emitLog("[G2] ANCS 알림 허용: \(enabled ? "ON (화이트리스트 해제)" : "OFF")")
        }
    }

    public func querySettings() {
        bleQueue.async { [weak self] in
            guard let self, self.sessionReady else { return }
            let pb = G2Commands.buildReadSettings(magic: self.nextMagic())
            self.enqueueProtobuf(pb, sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)
            self.emitLog("[G2] 기기 상태 조회 요청")
        }
    }

    public func setScreenAsleep(_ asleep: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if asleep && self.alwaysStayLocked {
                self.emitLog("[G2] 항시 OS 유지 모드이므로 절전(기본 OS 복귀)을 차단했습니다.")
                return
            }
            self.screenAsleepLocked = asleep
            DispatchQueue.main.async { self.isScreenAsleep = asleep }
            if asleep {
                self.heartbeatTimer?.cancel()
                self.heartbeatTimer = nil
                self.pageCreated = false
                self.activeLayoutKey = nil
                self.emitLog("[G2] 화면 절전 요청")
            } else if self.sessionReady {
                self.recreatePageLocked(reason: "화면 깨우기")
            }
        }
    }

    // MARK: - Internal Connection, Handshake & Always-On Recovery

    private func connectPeripherals(left: CBPeripheral, right: CBPeripheral) {
        exitRecoveryWorkItem?.cancel()
        exitRecoveryWorkItem = nil
        stopTimers()
        sessionReady = false
        pageCreated = false
        activeLayoutKey = nil
        lastPushedTexts.removeAll()
        uploadedImageHashes.removeAll()
        imuActiveLocked = false
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
        emitLog("[G2] 양쪽 렌즈 GATT 준비 완료 → 인증 및 세션 초기화 시작")

        bleQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let rightAuth = G2Frame.authFrame(magic: self.nextAuthMagic())
            self.enqueue(side: .right, data: rightAuth)

            self.bleQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                let leftAuth = G2Frame.authFrame(magic: self.nextAuthMagic())
                self.enqueue(side: .left, data: leftAuth)

                self.bleQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    self.enqueue(side: .right, data: G2Commands.preludeFrame)

                    self.bleQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { return }
                        self.enqueueProtobuf(G2Commands.buildRoleChange(magic: self.nextMagic(), role: 1), sid: G2SID.deviceConfig, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildTimeSync(magic: self.nextMagic()), sid: G2SID.deviceConfig, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildOnboardingFinish(magic: self.nextMagic()), sid: G2SID.onboarding, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildDisplayTimeout(magic: self.nextMagic(), seconds: nil), sid: G2SID.moduleConfig, flag: G2Frame.flagRequest, side: .right)
                        self.enqueueProtobuf(G2Commands.buildLanguage(magic: self.nextMagic(), index: 8), sid: G2SID.moduleConfig, flag: G2Frame.flagRequest, side: .right)

                        if self.ancsEnabledLocked {
                            self.enqueueProtobuf(G2Commands.buildNotificationCtrl(magic: self.nextMagic(), enable: true, autoDisplay: true, dispTime: 5), sid: G2SID.notification, flag: G2Frame.flagRequest, side: .right)
                            self.enqueueProtobuf(G2Commands.buildWhitelistDisable(magic: self.nextMagic(), disable: true), sid: G2SID.notification, flag: G2Frame.flagRequest, side: .right)
                        }
                        self.enqueueProtobuf(G2Commands.buildReadSettings(magic: self.nextMagic()), sid: G2SID.settings, flag: G2Frame.flagRequest, side: .right)

                        let createPb = G2Commands.buildCreatePage(magic: self.nextMagic(), page: self.lastRenderedPage)
                        self.enqueueProtobuf(createPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
                        self.activeLayoutKey = self.lastRenderedPage.layoutKey
                        self.lastPushedTexts = Dictionary(uniqueKeysWithValues: self.lastRenderedPage.textContainers.map { ($0.id, $0.text) })
                        self.uploadedImageHashes.removeAll()
                        self.enqueueImageUploadsLocked(self.lastRenderedPage.imageContainers)

                        if self.imuDesiredLocked {
                            self.imuActiveLocked = true
                            self.enqueueProtobuf(G2Commands.buildImuControl(magic: self.nextMagic(), enable: true, reportFreqMs: 250), sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
                        }

                        self.pageCreated = true
                        self.screenAsleepLocked = false
                        self.sessionReady = true
                        self.lastPageCreatedAt = Date()
                        self.lastHeartbeatSentAt = Date()
                        DispatchQueue.main.async { self.isScreenAsleep = false }
                        self.setPhase(.connected)
                        self.startHeartbeatTimer()
                        self.startKeepaliveTimer()
                        self.emitLog("[G2] 세션 연결 완료! (3.5초 하트비트 + 항시 OS 유지 + ANCS 준비)")
                    }
                }
            }
        }
    }

    private func ensureScreenActiveLocked(forceRecreate: Bool, reason: String) {
        guard sessionReady else { return }
        let stale = Date().timeIntervalSince(lastHeartbeatSentAt) > 7.5
        if forceRecreate || !pageCreated || screenAsleepLocked || stale {
            recreatePageLocked(reason: reason)
        } else if heartbeatTimer == nil {
            startHeartbeatTimer()
        }
    }

    private func recreatePageLocked(reason: String) {
        guard sessionReady else { return }
        screenAsleepLocked = false
        DispatchQueue.main.async { self.isScreenAsleep = false }

        enqueue(side: .right, data: G2Commands.preludeFrame)
        let createPb = G2Commands.buildCreatePage(magic: nextMagic(), page: lastRenderedPage)
        enqueueProtobuf(createPb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)

        activeLayoutKey = lastRenderedPage.layoutKey
        lastPushedTexts = Dictionary(uniqueKeysWithValues: lastRenderedPage.textContainers.map { ($0.id, $0.text) })
        uploadedImageHashes.removeAll()
        enqueueImageUploadsLocked(lastRenderedPage.imageContainers)

        if imuDesiredLocked {
            imuActiveLocked = true
            enqueueProtobuf(G2Commands.buildImuControl(magic: nextMagic(), enable: true, reportFreqMs: 250), sid: G2SID.evenHub, flag: G2Frame.flagRequest, side: .right)
        }

        pageCreated = true
        lastPageCreatedAt = Date()
        lastHeartbeatSentAt = Date()
        if heartbeatTimer == nil {
            startHeartbeatTimer()
        }
        emitLog("[G2] \(reason)")
    }

    private func scheduleExitRecoveryLocked(eventLabel: String) {
        guard alwaysStayLocked, sessionReady, !screenAsleepLocked else { return }
        let now = Date()
        if now.timeIntervalSince(lastPageCreatedAt) < 1.2 { return }

        recentExitRecoveries = recentExitRecoveries.filter { now.timeIntervalSince($0) < 10.0 }
        let delay: TimeInterval = recentExitRecoveries.count >= 3 ? 2.0 : 0.35
        recentExitRecoveries.append(now)

        exitRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alwaysStayLocked, self.sessionReady, !self.screenAsleepLocked, !self.pageCreated else { return }
            self.recreatePageLocked(reason: "기본 OS 이탈(\(eventLabel)) 차단 → 우리 OS 자동 복귀")
        }
        exitRecoveryWorkItem = work
        bleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 3.5, repeating: 3.5, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionReady, !self.screenAsleepLocked else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.lastHeartbeatSentAt)

            if gap > 8.5 || !self.pageCreated {
                self.recreatePageLocked(reason: String(format: "하트비트 공백(%.1f초) 감지 → OS 화면 자동 복구", gap))
                return
            }

            self.lastHeartbeatSentAt = now
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

        bleQueue.asyncAfter(deadline: .now() + 0.028) { [weak self] in
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
            let restored = [rightPeripheral, leftPeripheral].compactMap { $0 }
            if !restored.isEmpty {
                for p in restored {
                    if p.state == .connected {
                        if let s = side(of: p) {
                            DispatchQueue.main.async {
                                if s == .left { self.leftConnected = true }
                                else { self.rightConnected = true }
                            }
                        }
                        p.discoverServices([G2Constants.serviceControl, G2Constants.serviceAudio])
                    } else if !userInitiatedDisconnect {
                        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
                    }
                }
            } else if !autoReconnectAttemptedOnBoot && !userInitiatedDisconnect {
                autoReconnectAttemptedOnBoot = true
                reconnectSavedPair(fallbackToScan: false)
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
            self.isMicEnabled = false
        }
        if lensSide == .left {
            leftWriteChar = nil
            leftNotifyReady = false
        } else {
            rightWriteChar = nil
            rightNotifyReady = false
        }
        assemblers[lensSide]?.reset()

        exitRecoveryWorkItem?.cancel()
        exitRecoveryWorkItem = nil
        stopTimers()
        sessionReady = false
        pageCreated = false
        activeLayoutKey = nil
        imuActiveLocked = false
        handshakeStarted = false
        micEnabledLocked = false

        emitLog("[G2] \(lensSide.displayName) 연결 끊김 (\(error?.localizedDescription ?? "링크 해제"))")

        if !userInitiatedDisconnect {
            setPhase(.connecting)
            emitLog("[G2] 백그라운드 자동 재연결 대기 중...")
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        } else {
            setPhase(.disconnected)
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
                if char.isNotifying {
                    if lensSide == .left { leftNotifyReady = true }
                    else { rightNotifyReady = true }
                }
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
                if event.eventType == .imuData, let imu = event.imu {
                    DispatchQueue.main.async { self.onImuSample?(imu) }
                    return
                }
                switch event.eventType {
                case .foregroundExit, .abnormalExit, .systemExit:
                    self.pageCreated = false
                    self.activeLayoutKey = nil
                    self.emitLog("[G2] 세션 이탈 이벤트: \(event.eventType.label)")
                    self.scheduleExitRecoveryLocked(eventLabel: event.eventType.label)
                default:
                    emitLog("[G2 템플] \(event.source): \(event.eventType.label)")
                }
                DispatchQueue.main.async { self.onGlassesEvent?(event) }
            }
        case G2SID.settings:
            if let readback = G2Commands.decodeSettingsReadback(frame.payload) {
                DispatchQueue.main.async {
                    if let b = readback.battery { self.batteryLevel = b }
                    if let c = readback.charging { self.isCharging = c }
                    if let s = readback.silentMode { self.silentMode = s }
                    if let br = readback.brightnessLevel { self.brightnessLevel = br }
                    if let autoB = readback.brightnessAuto { self.brightnessAuto = autoB }
                    if let h = readback.displayHeight { self.displayHeight = h }
                    if let d = readback.displayDistance { self.displayDistance = d }
                    if let hu = readback.headUpEnabled { self.headUpEnabled = hu }
                    if let ha = readback.headUpAngle { self.headUpAngle = ha }
                    if let w = readback.wearDetection { self.wearDetection = w }
                    if let l = readback.leftFirmware { self.firmwareLeft = l }
                    if let r = readback.rightFirmware { self.firmwareRight = r }
                }
            }
        default:
            break
        }
    }
}
