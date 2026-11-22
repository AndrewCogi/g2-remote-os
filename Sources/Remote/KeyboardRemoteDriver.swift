import SwiftUI
import UIKit

/// Bonus foreground/OLED-pocket-mode driver for Bluetooth HID keyboards (e.g., 8BitDo Micro in K-mode).
/// Note: iOS blocks HID keyboard input when the device is hardware-locked, so this only operates
/// while the app is in the foreground (including OLED black pocket mode).
public struct KeyboardCaptureView: UIViewControllerRepresentable {
    public let onAction: (RemoteCommandEvent) -> Void

    public init(onAction: @escaping (RemoteCommandEvent) -> Void) {
        self.onAction = onAction
    }

    public func makeUIViewController(context: Context) -> KeyCaptureController {
        let vc = KeyCaptureController()
        vc.onAction = onAction
        return vc
    }

    public func updateUIViewController(_ uiViewController: KeyCaptureController, context: Context) {
        uiViewController.onAction = onAction
    }
}

public final class KeyCaptureController: UIViewController {
    public var onAction: ((RemoteCommandEvent) -> Void)?

    public override var canBecomeFirstResponder: Bool { true }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    public override var keyCommands: [UIKeyCommand]? {
        let bindings: [(String, Selector, String)] = [
            (UIKeyCommand.inputUpArrow, #selector(handleUp), "Up"),
            (UIKeyCommand.inputDownArrow, #selector(handleDown), "Down"),
            (UIKeyCommand.inputLeftArrow, #selector(handleLeft), "Left"),
            (UIKeyCommand.inputRightArrow, #selector(handleRight), "Right"),
            ("\r", #selector(handleSelect), "Enter"),
            (" ", #selector(handleSelect), "Space"),
            (UIKeyCommand.inputEscape, #selector(handleBack), "Esc"),
            ("\u{8}", #selector(handleBack), "Backspace"),
            ("m", #selector(handleMic), "Mic"),
            ("h", #selector(handleHome), "Home"),
            ("w", #selector(handleScrollUp), "ScrollUp"),
            ("s", #selector(handleScrollDown), "ScrollDown"),
            ("[", #selector(handleBrightnessDown), "BrightDown"),
            ("]", #selector(handleBrightnessUp), "BrightUp")
        ]
        return bindings.map { input, action, title in
            let cmd = UIKeyCommand(input: input, modifierFlags: [], action: action)
            cmd.wantsPriorityOverSystemBehavior = true
            cmd.discoverabilityTitle = title
            return cmd
        }
    }

    private func fire(_ action: RemoteAction, key: String) {
        onAction?(RemoteCommandEvent(action: action, source: .keyboard, detail: "Key(\(key))"))
    }

    @objc private func handleUp() { fire(.up, key: "↑") }
    @objc private func handleDown() { fire(.down, key: "↓") }
    @objc private func handleLeft() { fire(.left, key: "←") }
    @objc private func handleRight() { fire(.right, key: "→") }
    @objc private func handleSelect() { fire(.select, key: "Enter") }
    @objc private func handleBack() { fire(.back, key: "Esc") }
    @objc private func handleMic() { fire(.micToggle, key: "M") }
    @objc private func handleHome() { fire(.home, key: "H") }
    @objc private func handleScrollUp() { fire(.scrollUp, key: "W") }
    @objc private func handleScrollDown() { fire(.scrollDown, key: "S") }
    @objc private func handleBrightnessUp() { fire(.brightnessUp, key: "]") }
    @objc private func handleBrightnessDown() { fire(.brightnessDown, key: "[") }
}
