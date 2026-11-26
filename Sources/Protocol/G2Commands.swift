import Foundation

/// Service IDs (SID) and protobuf builders/decoders for the Even Realities G2 stock firmware.
/// Byte-exact port of the live-confirmed `open-g2-hub` / `even-g2-protocol` specifications.
public enum G2SID {
    public static let dashboard: UInt8 = 0x01
    public static let menu: UInt8 = 0x03
    public static let notification: UInt8 = 0x04
    public static let translate: UInt8 = 0x05
    public static let teleprompter: UInt8 = 0x06
    public static let evenAI: UInt8 = 0x07
    public static let navigation: UInt8 = 0x08
    public static let settings: UInt8 = 0x09
    public static let transcribe: UInt8 = 0x0A
    public static let conversate: UInt8 = 0x0B
    public static let quicklist: UInt8 = 0x0C
    public static let appSync: UInt8 = 0x0D
    public static let health: UInt8 = 0x0E
    public static let onboarding: UInt8 = 0x10
    public static let moduleConfig: UInt8 = 0x20
    public static let deviceConfig: UInt8 = 0x80
    public static let caseInfo: UInt8 = 0x81
    public static let ring: UInt8 = 0x90
    public static let evenHub: UInt8 = 0xE0

    public static func name(for sid: UInt8) -> String {
        switch sid {
        case dashboard: return "Dashboard"
        case menu: return "Menu"
        case notification: return "Notification"
        case translate: return "Translate"
        case teleprompter: return "Teleprompter"
        case evenAI: return "EvenAI"
        case navigation: return "Navigation"
        case settings: return "Settings"
        case transcribe: return "Transcribe"
        case conversate: return "Conversate"
        case quicklist: return "Quicklist"
        case appSync: return "AppSync"
        case health: return "Health"
        case onboarding: return "Onboarding"
        case moduleConfig: return "ModuleConfig"
        case deviceConfig: return "DeviceConfig"
        case caseInfo: return "Case"
        case ring: return "Ring"
        case evenHub: return "EvenHub"
        default: return String(format: "0x%02X", sid)
        }
    }
}

public enum G2GlassesEventType: Int {
    case click = 0
    case scrollTop = 1
    case scrollBottom = 2
    case doubleClick = 3
    case foregroundEnter = 4
    case foregroundExit = 5
    case abnormalExit = 6
    case systemExit = 7
    case imuData = 8
    case longPress = 9
    case longPressRelease = 10

    public var label: String {
        switch self {
        case .click: return "CLICK"
        case .scrollTop: return "SCROLL_TOP"
        case .scrollBottom: return "SCROLL_BOTTOM"
        case .doubleClick: return "DOUBLE_CLICK"
        case .foregroundEnter: return "FOREGROUND_ENTER"
        case .foregroundExit: return "FOREGROUND_EXIT"
        case .abnormalExit: return "ABNORMAL_EXIT"
        case .systemExit: return "SYSTEM_EXIT"
        case .imuData: return "IMU_DATA"
        case .longPress: return "LONG_PRESS"
        case .longPressRelease: return "LONG_PRESS_RELEASE"
        }
    }
}

public struct G2ImuSample: Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Estimates pitch angle in degrees from a 3-axis accelerometer/orientation vector.
    /// Used together with relative baseline calibration for reliable Raise-to-Wake (Head-Up) detection.
    public var pitchDegrees: Double {
        let horizontal = sqrt(Double(x) * Double(x) + Double(z) * Double(z))
        if horizontal < 0.0001 && abs(Double(y)) < 0.0001 { return 0 }
        return atan2(Double(y), max(0.0001, horizontal)) * 180.0 / .pi
    }
}

public struct G2DeviceEvent: Equatable {
    public let source: String
    public let eventType: G2GlassesEventType
    public let containerName: String?
    public let itemIndex: Int?
    public let imu: G2ImuSample?

    public init(
        source: String,
        eventType: G2GlassesEventType,
        containerName: String? = nil,
        itemIndex: Int? = nil,
        imu: G2ImuSample? = nil
    ) {
        self.source = source
        self.eventType = eventType
        self.containerName = containerName
        self.itemIndex = itemIndex
        self.imu = imu
    }
}

public struct G2SettingsReadback: Equatable {
    public var battery: Int?
    public var charging: Bool?
    public var silentMode: Bool?
    public var brightnessLevel: Int?
    public var brightnessAuto: Bool?
    public var displayHeight: Int?
    public var displayDistance: Int?
    public var headUpEnabled: Bool?
    public var headUpAngle: Int?
    public var wearDetection: Bool?
    public var unreadCount: Int?
    public var leftFirmware: String?
    public var rightFirmware: String?
}

public enum G2Commands {
    public static let preludeAckMagic = 156
    public static let defaultWidgetId = 10000
    public static let containerName = "dashboard"
    public static let containerID = 1
    public static let canvasWidth = 576
    public static let canvasHeight = 288

    public static let maxContainerNameBytes = 14
    public static let maxCreateTextBytes = 998
    public static let maxUpgradeTextBytes = 1998
    /// Official Even App BTSnoop app-level BMP chunk size (4096 B -> ~18 AA packets per chunk, ~5x faster than 200 B).
    public static let imageFragmentBytes = 4096
    public static let timeoutNever = 65365

    // MARK: - EvenHub (SID 0xE0) & Prelude (SID 0x01)

    /// Session prelude `{1: 2, 2: 156, 4: {3: {2: {2: {1: 0, 2: 0}}}}}` sent on SID 0x01 after auth.
    public static func buildPreludePayload() -> Data {
        let innermost = ProtobufLite.encodeVarintField(1, 0) + ProtobufLite.encodeVarintField(2, 0)
        let f4 = ProtobufLite.encodeMessageField(
            3,
            ProtobufLite.encodeMessageField(
                2,
                ProtobufLite.encodeMessageField(2, innermost)
            )
        )
        return ProtobufLite.encodeVarintField(1, 2)
            + ProtobufLite.encodeVarintField(2, preludeAckMagic)
            + ProtobufLite.encodeMessageField(4, f4)
    }

    public static var preludeFrame: Data {
        G2Frame.framePb(buildPreludePayload(), sid: G2SID.dashboard, flag: G2Frame.flagRequest, seq: 0x92)[0]
    }

    public static func wrapEvenHub(cmd: Int, magic: Int, innerField: Int, inner: Data) -> Data {
        ProtobufLite.encodeVarintField(1, cmd)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(innerField, inner)
    }

    public static func encodeTextObject(
        name: String,
        containerId: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        text: String,
        captureEvents: Bool,
        borderWidth: Int = 0,
        borderColor: Int = 0,
        borderRadius: Int = 0,
        padding: Int = 0,
        textColor: Int? = nil
    ) -> Data {
        let safeName = ProtobufLite.utf8Fit(name, maxBytes: maxContainerNameBytes)
        let safeText = ProtobufLite.utf8Fit(text, maxBytes: maxCreateTextBytes)
        let pb = PbBuilder()
            .varint(1, x)
            .varint(2, y)
            .varint(3, width)
            .varint(4, height)
        if borderWidth != 0 { pb.varint(5, min(5, max(0, borderWidth))) }
        if borderColor != 0 { pb.varint(6, min(16, max(0, borderColor))) }
        if borderRadius != 0 { pb.varint(7, min(10, max(0, borderRadius))) }
        if padding != 0 { pb.varint(8, min(32, max(0, padding))) }
        pb.varint(9, containerId)
        pb.string(10, safeName)
        if captureEvents { pb.varint(11, 1) }
        pb.string(12, safeText)
        if let tc = textColor {
            pb.varint(14, min(4, max(0, tc)))
        }
        return pb.build()
    }

    public static func encodeImageObject(
        name: String,
        containerId: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Data {
        let safeName = ProtobufLite.utf8Fit(name, maxBytes: maxContainerNameBytes)
        return PbBuilder()
            .varint(1, x)
            .varint(2, y)
            .varint(3, min(288, max(20, width)))
            .varint(4, min(144, max(20, height)))
            .varint(5, containerId)
            .string(6, safeName)
            .build()
    }

    /// SID 0xE0 cmd 0: Create full-screen text container ("dashboard", 576x288). LIVE-CONFIRMED.
    public static func buildCreateInputPage(magic: Int, text: String) -> Data {
        let textObj = encodeTextObject(
            name: containerName,
            containerId: containerID,
            x: 0,
            y: 0,
            width: canvasWidth,
            height: canvasHeight,
            text: text,
            captureEvents: true
        )
        let inner = PbBuilder()
            .varint(1, 1)
            .message(3, textObj)
            .varint(5, defaultWidgetId)
            .build()
        return wrapEvenHub(cmd: 0, magic: magic, innerField: 3, inner: inner)
    }

    /// SID 0xE0 cmd 0: Create multi-container page (up to 8 text containers + 4 image containers).
    public static func buildCreatePage(magic: Int, page: G2PageSpec) -> Data {
        let total = page.textContainers.count + page.imageContainers.count
        let inner = PbBuilder().varint(1, max(1, total))
        for t in page.textContainers {
            let obj = encodeTextObject(
                name: t.name,
                containerId: t.id,
                x: t.x,
                y: t.y,
                width: t.width,
                height: t.height,
                text: t.text,
                captureEvents: t.captureEvents,
                borderWidth: t.borderWidth,
                borderColor: t.borderColor,
                borderRadius: t.borderRadius,
                padding: t.padding,
                textColor: t.textColor
            )
            inner.message(3, obj)
        }
        for img in page.imageContainers {
            let obj = encodeImageObject(
                name: img.name,
                containerId: img.id,
                x: img.x,
                y: img.y,
                width: img.width,
                height: img.height
            )
            inner.message(4, obj)
        }
        inner.varint(5, defaultWidgetId)
        return wrapEvenHub(cmd: 0, magic: magic, innerField: 3, inner: inner.build())
    }

    /// SID 0xE0 cmd 7: Rebuild active page with a new container layout without closing the EvenHub session.
    public static func buildRebuildPage(magic: Int, page: G2PageSpec) -> Data {
        let total = page.textContainers.count + page.imageContainers.count
        let inner = PbBuilder().varint(1, max(1, total))
        for t in page.textContainers {
            let obj = encodeTextObject(
                name: t.name,
                containerId: t.id,
                x: t.x,
                y: t.y,
                width: t.width,
                height: t.height,
                text: t.text,
                captureEvents: t.captureEvents,
                borderWidth: t.borderWidth,
                borderColor: t.borderColor,
                borderRadius: t.borderRadius,
                padding: t.padding,
                textColor: t.textColor
            )
            inner.message(3, obj)
        }
        for img in page.imageContainers {
            let obj = encodeImageObject(
                name: img.name,
                containerId: img.id,
                x: img.x,
                y: img.y,
                width: img.width,
                height: img.height
            )
            inner.message(4, obj)
        }
        return wrapEvenHub(cmd: 7, magic: magic, innerField: 7, inner: inner.build())
    }

    /// SID 0xE0 cmd 3: Upload one <=4096-byte chunk of a 4-bit BMP image into an image container.
    public static func buildImageRawData(
        magic: Int,
        containerId: Int,
        name: String,
        totalSize: Int,
        fragmentIndex: Int,
        fragmentData: Data,
        mapSessionId: Int = 1,
        compressMode: Int = 0
    ) -> Data {
        let safeName = ProtobufLite.utf8Fit(name, maxBytes: maxContainerNameBytes)
        let inner = PbBuilder()
            .varint(1, containerId)
            .string(2, safeName)
            .varint(3, mapSessionId)
            .varint(4, totalSize)
        if compressMode != 0 {
            inner.varint(5, compressMode)
        }
        inner
            .varint(6, fragmentIndex)
            .varint(7, fragmentData.count)
            .bytes(8, fragmentData)
        return wrapEvenHub(cmd: 3, magic: magic, innerField: 5, inner: inner.build())
    }

    /// Splits a G2ImageContainer's 4-bit BMP into sequential <=4096-byte `cmd 3` protobuf payloads paired with their `msgId`.
    public static func buildImageUploadChunks(
        image: G2ImageContainer,
        mapSessionId: Int = 1,
        nextMagic: () -> Int
    ) -> [(magic: Int, payload: Data)] {
        let bmp = G2PixelCanvas.encodeBmp4bpp(packed: image.packed4bpp, width: image.width, height: image.height)
        guard !bmp.isEmpty else { return [] }
        var out: [(magic: Int, payload: Data)] = []
        var offset = 0
        var fragIdx = 0
        while offset < bmp.count {
            let end = min(bmp.count, offset + imageFragmentBytes)
            let chunk = Data(bmp[offset..<end])
            let magic = nextMagic()
            let pb = buildImageRawData(
                magic: magic,
                containerId: image.id,
                name: image.name,
                totalSize: bmp.count,
                fragmentIndex: fragIdx,
                fragmentData: chunk,
                mapSessionId: mapSessionId
            )
            out.append((magic: magic, payload: pb))
            offset = end
            fragIdx += 1
        }
        return out
    }

    /// Convenience wrapper returning only protobuf payloads.
    public static func buildImageUploadMessages(
        image: G2ImageContainer,
        mapSessionId: Int = 1,
        nextMagic: () -> Int
    ) -> [Data] {
        buildImageUploadChunks(image: image, mapSessionId: mapSessionId, nextMagic: nextMagic).map(\.payload)
    }

    /// SID 0xE0 cmd 5: Replace text inside an existing text container. LIVE-CONFIRMED.
    public static func buildTextUpgrade(
        magic: Int,
        containerId: Int = containerID,
        containerName: String = containerName,
        text: String
    ) -> Data {
        let safeName = ProtobufLite.utf8Fit(containerName, maxBytes: maxContainerNameBytes)
        let safeText = ProtobufLite.utf8Fit(text, maxBytes: maxUpgradeTextBytes)
        let utf8Len = safeText.utf8.count
        let inner = PbBuilder()
            .varint(1, containerId)
            .string(2, safeName)
            .varint(3, 0)
            .varint(4, utf8Len)
            .string(5, safeText)
            .build()
        return wrapEvenHub(cmd: 5, magic: magic, innerField: 9, inner: inner)
    }

    /// SID 0xE0 cmd 12: Session heartbeat (must be sent every ~3.5-4s to keep EvenHub canvas alive). LIVE-CONFIRMED.
    public static func buildHeartbeat(magic: Int) -> Data {
        wrapEvenHub(cmd: 12, magic: magic, innerField: 14, inner: ProtobufLite.encodeVarintField(1, 0))
    }

    /// SID 0xE0 cmd 15: Enable/disable G2 built-in microphone (raw LC3 streams on 0x6402). LIVE-CONFIRMED.
    public static func buildAudioControl(magic: Int, enable: Bool) -> Data {
        wrapEvenHub(cmd: 15, magic: magic, innerField: 18, inner: ProtobufLite.encodeVarintField(1, enable ? 1 : 0))
    }

    /// SID 0xE0 cmd 19: Enable/disable G2 glasses IMU orientation stream (used for Head-Up Raise-to-Wake).
    public static func buildImuControl(magic: Int, enable: Bool, reportFreqMs: Int = 250) -> Data {
        let inner = PbBuilder().varint(1, enable ? 1 : 0)
        if enable && reportFreqMs > 0 {
            inner.varint(2, reportFreqMs)
        }
        return wrapEvenHub(cmd: 19, magic: magic, innerField: 22, inner: inner.build())
    }

    // MARK: - Device Config (SID 0x80), Onboarding (SID 0x10), Notification ANCS (SID 0x04)

    /// SID 0x80 cmd 5: Set right lens as command pipe.
    public static func buildRoleChange(magic: Int, role: Int = 1) -> Data {
        ProtobufLite.encodeVarintField(1, 5)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(4, ProtobufLite.encodeVarintField(1, role))
    }

    /// SID 0x80 cmd 128: Sync wall-clock timestamp and timezone (15-min units).
    public static func buildTimeSync(magic: Int, date: Date = Date(), timeZone: TimeZone = .current) -> Data {
        let unixSecs = UInt64(max(0, Int64(date.timeIntervalSince1970)))
        let tzUnits = max(-128, min(127, timeZone.secondsFromGMT(for: date) / 900))
        let inner = ProtobufLite.encodeUInt64Field(1, unixSecs)
            + ProtobufLite.encodeKey(field: 2, wireType: 0)
            + ProtobufLite.encodeSignedVarint(Int64(tzUnits))
        return ProtobufLite.encodeVarintField(1, 128)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(128, inner)
    }

    /// SID 0x80 cmd 14: 60-second base link keep-alive (send with flagPlain 0x00).
    public static func buildKeepalive(magic: Int) -> Data {
        ProtobufLite.encodeVarintField(1, 14)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(13, Data())
    }

    /// SID 0x10 cmd 1: Finish onboarding tutorial state.
    public static func buildOnboardingFinish(magic: Int) -> Data {
        ProtobufLite.encodeVarintField(1, 1)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, ProtobufLite.encodeVarintField(1, 4))
    }

    /// SID 0x04 cmd 1: Enable/configure firmware-side ANCS notification display.
    public static func buildNotificationCtrl(
        magic: Int,
        enable: Bool = true,
        autoDisplay: Bool = true,
        dispTime: Int = 5,
        dnd: Bool = false
    ) -> Data {
        let ctrl = PbBuilder()
            .varint(1, enable ? 1 : 0)
            .varint(2, autoDisplay ? 1 : 0)
            .varint(3, max(1, min(30, dispTime)))
        if dnd { ctrl.varint(5, 1) }
        return ProtobufLite.encodeVarintField(1, 1)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, ctrl.build())
    }

    /// SID 0x04 cmd 3: Bypass firmware notification app whitelist so all iOS ANCS alerts are eligible.
    public static func buildWhitelistDisable(magic: Int, disable: Bool = true) -> Data {
        ProtobufLite.encodeVarintField(1, 3)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(6, ProtobufLite.encodeVarintField(1, disable ? 1 : 0))
    }

    // MARK: - Full Hardware Settings (SID 0x09) & Module Config (SID 0x20)

    private static func buildSettingsSet(magic: Int, field: Int, inner: Data) -> Data {
        ProtobufLite.encodeVarintField(1, 1)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, ProtobufLite.encodeMessageField(field, inner))
    }

    /// SID 0x09 cmd 2: Read battery, charging, silent mode, brightness, display pos, head-up, wear, firmware.
    public static func buildReadSettings(magic: Int) -> Data {
        ProtobufLite.encodeVarintField(1, 2)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(4, ProtobufLite.encodeVarintField(1, 1))
    }

    /// SID 0x09 cmd 1: Set manual brightness level (1...50).
    public static func buildBrightness(magic: Int, level: Int) -> Data {
        let clamped = max(1, min(50, level))
        return buildSettingsSet(magic: magic, field: 1, inner: ProtobufLite.encodeVarintField(2, clamped))
    }

    /// SID 0x09 cmd 1: Toggle auto-brightness.
    public static func buildAutoBrightness(magic: Int, enabled: Bool) -> Data {
        buildSettingsSet(magic: magic, field: 1, inner: ProtobufLite.encodeVarintField(1, enabled ? 1 : 0))
    }

    /// SID 0x09 cmd 1: Set vertical display height (0...20).
    public static func buildDisplayHeight(magic: Int, level: Int) -> Data {
        buildSettingsSet(magic: magic, field: 2, inner: ProtobufLite.encodeVarintField(1, max(0, min(20, level))))
    }

    /// SID 0x09 cmd 1: Set optical display distance / depth preset (0...20).
    public static func buildDisplayDistance(magic: Int, level: Int) -> Data {
        buildSettingsSet(magic: magic, field: 3, inner: ProtobufLite.encodeVarintField(1, max(0, min(20, level))))
    }

    /// SID 0x09 cmd 1: Configure hardware Head-Up (Raise-to-Wake) enable & angle (0...60 deg).
    public static func buildHeadUp(magic: Int, enabled: Bool, angle: Int? = nil) -> Data {
        let inner = PbBuilder().varint(1, enabled ? 1 : 0)
        if let angle {
            inner.varint(2, max(0, min(60, angle)))
        }
        return buildSettingsSet(magic: magic, field: 4, inner: inner.build())
    }

    /// SID 0x09 cmd 1: Toggle wear detection sensor.
    public static func buildWearDetection(magic: Int, enabled: Bool) -> Data {
        buildSettingsSet(magic: magic, field: 5, inner: ProtobufLite.encodeVarintField(1, enabled ? 1 : 0))
    }

    /// SID 0x09 cmd 1: Toggle silent mode.
    public static func buildSilentMode(magic: Int, enabled: Bool) -> Data {
        buildSettingsSet(magic: magic, field: 6, inner: ProtobufLite.encodeVarintField(1, enabled ? 1 : 0))
    }

    /// SID 0x20 cmd 2: Configure hardware auto screen-off timeout (nil = never / 65365).
    public static func buildDisplayTimeout(magic: Int, seconds: Int?) -> Data {
        let val = seconds ?? timeoutNever
        return ProtobufLite.encodeVarintField(1, 2)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(4, ProtobufLite.encodeVarintField(1, val))
    }

    /// SID 0x20 cmd 0: Set glasses firmware UI language (0=English, 8=Korean).
    public static func buildLanguage(magic: Int, index: Int) -> Data {
        let clamped = max(0, min(8, index))
        return ProtobufLite.encodeVarintField(1, 0)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, ProtobufLite.encodeVarintField(1, clamped))
    }

    // MARK: - Decoders

    /// Decodes async temple/ring/IMU events arriving on SID 0xE0.
    public static func decodeDeviceEvent(_ pb: Data) -> G2DeviceEvent? {
        guard let deviceEvent = ProtobufLite.readBytesField(pb, field: 13) else { return nil }

        if let listEv = ProtobufLite.readBytesField(deviceEvent, field: 1) {
            let evRaw = ProtobufLite.readVarintField(listEv, field: 5, default: 0)
            let evType = G2GlassesEventType(rawValue: evRaw) ?? .click
            return G2DeviceEvent(
                source: "list",
                eventType: evType,
                containerName: ProtobufLite.readStringField(listEv, field: 2),
                itemIndex: ProtobufLite.readVarintField(listEv, field: 4, default: 0)
            )
        }
        if let textEv = ProtobufLite.readBytesField(deviceEvent, field: 2) {
            let evRaw = ProtobufLite.readVarintField(textEv, field: 3, default: 0)
            let evType = G2GlassesEventType(rawValue: evRaw) ?? .click
            return G2DeviceEvent(
                source: "text",
                eventType: evType,
                containerName: ProtobufLite.readStringField(textEv, field: 2)
            )
        }
        if let sysEv = ProtobufLite.readBytesField(deviceEvent, field: 3) {
            let evRaw = ProtobufLite.readVarintField(sysEv, field: 1, default: 0)
            let evType = G2GlassesEventType(rawValue: evRaw) ?? .click
            var imuSample: G2ImuSample?
            if let imuBytes = ProtobufLite.readBytesField(sysEv, field: 3) {
                let x = ProtobufLite.readFloatField(imuBytes, field: 1)
                let y = ProtobufLite.readFloatField(imuBytes, field: 2)
                let z = ProtobufLite.readFloatField(imuBytes, field: 3)
                imuSample = G2ImuSample(x: x, y: y, z: z)
            }
            return G2DeviceEvent(
                source: "sys",
                eventType: evType,
                imu: imuSample
            )
        }
        return nil
    }

    /// Decodes full SID 0x09 settings readback (battery, charging, brightness, display position, head-up, wear, firmware).
    public static func decodeSettingsReadback(_ pb: Data) -> G2SettingsReadback? {
        guard let req = ProtobufLite.readBytesField(pb, field: 4) else { return nil }
        var out = G2SettingsReadback()
        let brightness = ProtobufLite.readVarintField(req, field: 2, default: -1)
        if brightness >= 0 { out.brightnessLevel = brightness }
        let height = ProtobufLite.readVarintField(req, field: 3, default: -1)
        if height >= 0 { out.displayHeight = height }
        let distance = ProtobufLite.readVarintField(req, field: 4, default: -1)
        if distance >= 0 { out.displayDistance = distance }
        let leftFw = ProtobufLite.readStringField(req, field: 5)
        if !leftFw.isEmpty { out.leftFirmware = leftFw }
        let rightFw = ProtobufLite.readStringField(req, field: 6)
        if !rightFw.isEmpty { out.rightFirmware = rightFw }
        let headUp = ProtobufLite.readVarintField(req, field: 7, default: -1)
        if headUp >= 0 { out.headUpEnabled = (headUp == 1) }
        let headUpAngle = ProtobufLite.readVarintField(req, field: 8, default: -1)
        if headUpAngle >= 0 { out.headUpAngle = headUpAngle }
        let wear = ProtobufLite.readVarintField(req, field: 10, default: -1)
        if wear >= 0 { out.wearDetection = (wear == 1) }
        let battery = ProtobufLite.readVarintField(req, field: 12, default: -1)
        if battery >= 0 { out.battery = battery }
        let charging = ProtobufLite.readVarintField(req, field: 13, default: -1)
        if charging >= 0 { out.charging = (charging == 1) }
        let silent = ProtobufLite.readVarintField(req, field: 14, default: -1)
        if silent >= 0 { out.silentMode = (silent == 1) }
        let autoB = ProtobufLite.readVarintField(req, field: 18, default: -1)
        if autoB >= 0 { out.brightnessAuto = (autoB == 1) }
        let unread = ProtobufLite.readVarintField(req, field: 19, default: -1)
        if unread >= 0 { out.unreadCount = unread }
        return out
    }
}
