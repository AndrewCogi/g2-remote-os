import Foundation

/// Service IDs (SID) and protobuf builders/decoders for the Even Realities G2 stock firmware.
/// Ported from the live-confirmed open-g2-hub / even-g2-protocol implementations.
public enum G2SID {
    public static let dashboard: UInt8 = 0x01
    public static let menu: UInt8 = 0x03
    public static let notification: UInt8 = 0x04
    public static let translate: UInt8 = 0x05
    public static let teleprompter: UInt8 = 0x06
    public static let evenAI: UInt8 = 0x07
    public static let navigation: UInt8 = 0x08
    public static let settings: UInt8 = 0x09
    public static let appSync: UInt8 = 0x0D
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
        case appSync: return "AppSync"
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

public struct G2DeviceEvent: Equatable {
    public let source: String
    public let eventType: G2GlassesEventType
    public let containerName: String?
    public let itemIndex: Int?
}

public struct G2SettingsReadback: Equatable {
    public var battery: Int?
    public var charging: Bool?
    public var silentMode: Bool?
    public var brightnessLevel: Int?
    public var brightnessAuto: Bool?
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
        captureEvents: Bool
    ) -> Data {
        let safeName = ProtobufLite.utf8Fit(name, maxBytes: maxContainerNameBytes)
        let safeText = ProtobufLite.utf8Fit(text, maxBytes: maxCreateTextBytes)
        let pb = PbBuilder()
            .varint(1, x)
            .varint(2, y)
            .varint(3, width)
            .varint(4, height)
            .varint(9, containerId)
            .string(10, safeName)
        if captureEvents {
            pb.varint(11, 1)
        }
        pb.string(12, safeText)
        return pb.build()
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

    /// SID 0xE0 cmd 5: Replace text inside the active full-screen container. LIVE-CONFIRMED.
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

    /// SID 0xE0 cmd 12: Session heartbeat (must be sent every ~4s to keep EvenHub canvas alive). LIVE-CONFIRMED.
    public static func buildHeartbeat(magic: Int) -> Data {
        wrapEvenHub(cmd: 12, magic: magic, innerField: 14, inner: ProtobufLite.encodeVarintField(1, 0))
    }

    /// SID 0xE0 cmd 15: Enable/disable G2 built-in microphone (raw LC3 streams on 0x6402). LIVE-CONFIRMED.
    public static func buildAudioControl(magic: Int, enable: Bool) -> Data {
        wrapEvenHub(cmd: 15, magic: magic, innerField: 18, inner: ProtobufLite.encodeVarintField(1, enable ? 1 : 0))
    }

    // MARK: - Device Config (SID 0x80) & Onboarding (SID 0x10)

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

    // MARK: - Settings (SID 0x09)

    /// SID 0x09 cmd 2: Read battery, charging, silent mode, brightness, and firmware versions.
    public static func buildReadSettings(magic: Int) -> Data {
        ProtobufLite.encodeVarintField(1, 2)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(4, ProtobufLite.encodeVarintField(1, 1))
    }

    /// SID 0x09 cmd 1: Set brightness level (1...50).
    public static func buildBrightness(magic: Int, level: Int) -> Data {
        let clamped = max(1, min(50, level))
        let sub = ProtobufLite.encodeMessageField(1, ProtobufLite.encodeVarintField(2, clamped))
        return ProtobufLite.encodeVarintField(1, 1)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, sub)
    }

    /// SID 0x09 cmd 1: Toggle silent mode.
    public static func buildSilentMode(magic: Int, enabled: Bool) -> Data {
        let sub = ProtobufLite.encodeMessageField(6, ProtobufLite.encodeVarintField(1, enabled ? 1 : 0))
        return ProtobufLite.encodeVarintField(1, 1)
            + ProtobufLite.encodeVarintField(2, magic)
            + ProtobufLite.encodeMessageField(3, sub)
    }

    // MARK: - Decoders

    /// Decodes async temple/ring events arriving on SID 0xE0.
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
                containerName: ProtobufLite.readStringField(textEv, field: 2),
                itemIndex: nil
            )
        }
        if let sysEv = ProtobufLite.readBytesField(deviceEvent, field: 3) {
            let evRaw = ProtobufLite.readVarintField(sysEv, field: 1, default: 0)
            let evType = G2GlassesEventType(rawValue: evRaw) ?? .click
            return G2DeviceEvent(
                source: "sys",
                eventType: evType,
                containerName: nil,
                itemIndex: nil
            )
        }
        return nil
    }

    /// Decodes SID 0x09 settings readback (battery, charging, silent mode, brightness, firmware).
    public static func decodeSettingsReadback(_ pb: Data) -> G2SettingsReadback? {
        guard let req = ProtobufLite.readBytesField(pb, field: 4) else { return nil }
        var out = G2SettingsReadback()
        let battery = ProtobufLite.readVarintField(req, field: 12, default: -1)
        if battery >= 0 { out.battery = battery }
        let charging = ProtobufLite.readVarintField(req, field: 13, default: -1)
        if charging >= 0 { out.charging = (charging == 1) }
        let silent = ProtobufLite.readVarintField(req, field: 14, default: -1)
        if silent >= 0 { out.silentMode = (silent == 1) }
        let brightness = ProtobufLite.readVarintField(req, field: 2, default: -1)
        if brightness >= 0 { out.brightnessLevel = brightness }
        let autoB = ProtobufLite.readVarintField(req, field: 18, default: -1)
        if autoB >= 0 { out.brightnessAuto = (autoB == 1) }
        let leftFw = ProtobufLite.readStringField(req, field: 5)
        if !leftFw.isEmpty { out.leftFirmware = leftFw }
        let rightFw = ProtobufLite.readStringField(req, field: 6)
        if !rightFw.isEmpty { out.rightFirmware = rightFw }
        return out
    }
}
