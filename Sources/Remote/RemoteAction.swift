import Foundation

/// Unified high-level control actions emitted by any remote driver
/// (Flic Duo, on-screen virtual pad, Bluetooth keyboard/8BitDo, or G2 temple touch).
public enum RemoteAction: String, CaseIterable, Identifiable {
    case up = "위 (UP)"
    case down = "아래 (DOWN)"
    case left = "왼쪽 (LEFT)"
    case right = "오른쪽 (RIGHT)"
    case scrollUp = "스크롤 업"
    case scrollDown = "스크롤 다운"
    case select = "확인 / 선택"
    case back = "뒤로가기"
    case home = "홈 런처"
    case micToggle = "마이크 On/Off"
    case brightnessUp = "밝기 +"
    case brightnessDown = "밝기 -"
    case screenToggle = "화면 절전/깨우기"

    public var id: String { rawValue }
}

public enum RemoteSource: String {
    case flicDuo = "Flic Duo"
    case virtualPad = "가상 패드"
    case keyboard = "키보드/HID"
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
