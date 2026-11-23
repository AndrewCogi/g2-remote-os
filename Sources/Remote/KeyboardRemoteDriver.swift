import GameController
import SwiftUI
import UIKit

/// Minimal fallback UIKeyCommand capture (yields to `GameControllerDriver`'s `GCKeyboard` when active).
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
            ("\u{8}", #selector(handleBack), "Backspace")
        ]
        return bindings.map { input, action, title in
            let cmd = UIKeyCommand(input: input, modifierFlags: [], action: action)
            cmd.wantsPriorityOverSystemBehavior = true
            cmd.discoverabilityTitle = title
            return cmd
        }
    }

    private func fire(_ action: RemoteAction, key: String) {
        if GCKeyboard.coalesced != nil { return }
        onAction?(RemoteCommandEvent(action: action, source: .keyboard, detail: "Key(\(key))"))
    }

    @objc private func handleUp() { fire(.up, key: "↑") }
    @objc private func handleDown() { fire(.down, key: "↓") }
    @objc private func handleLeft() { fire(.left, key: "←") }
    @objc private func handleRight() { fire(.right, key: "→") }
    @objc private func handleSelect() { fire(.select, key: "Enter") }
    @objc private func handleBack() { fire(.back, key: "Esc") }
}
