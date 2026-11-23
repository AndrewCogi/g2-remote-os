import Foundation

/// Unified high-level control actions emitted by any input driver
/// (fullscreen phone Motion Pad, Flic Duo, Bluetooth keyboard, or G2 temple touch).
public enum RemoteAction: String, CaseIterable, Identifiable {
    case up = "위"
    case down = "아래"
    case left = "왼쪽"
    case right = "오른쪽"
    case scrollUp = "스크롤 업"
    case scrollDown = "스크롤 다운"
    case select = "클릭"
    case back = "뒤로가기"
    case home = "홈"
    case micStart = "마이크 열기"
    case micStop = "마이크 끄기"
    case micToggle = "마이크 토글"
    case brightnessUp = "밝기 +"
    case brightnessDown = "밝기 -"
    case screenToggle = "화면 절전"

    public var id: String { rawValue }
}

public enum RemoteSource: String {
    case motionPad = "모션 패드"
    case flicDuo = "Flic Duo"
    case virtualPad = "가상 패드"
    case keyboard = "키보드"
    case glassesTemple = "G2 템플"
}

public struct RemoteCommandEvent {
    public let action: RemoteAction
    public let source: RemoteSource
    public let detail: String
    public let timestamp: Date

    public init(action: RemoteAction, source: RemoteSource, detail: String = "", timestamp: Date = Date()) {
        self.action = action
        self.source = source
        self.detail = detail
        self.timestamp = timestamp
    }
}
