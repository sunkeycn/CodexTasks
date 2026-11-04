import AppKit
import SwiftUI
import Carbon
import LiteCore

extension WindowShortcut {
    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0)
            | (option ? UInt32(optionKey) : 0) | (control ? UInt32(controlKey) : 0)
    }
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }; if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }; if control { flags.insert(.control) }
        return flags
    }
    var keyEquivalent: String {
        let special: [UInt32: String] = [49: " ", 36: "\r", 48: "\t", 51: "\u{8}", 117: "\u{f728}",
                                        123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}",
                                        122: "\u{f704}", 120: "\u{f705}", 99: "\u{f706}", 118: "\u{f707}",
                                        96: "\u{f708}", 97: "\u{f709}", 98: "\u{f70a}", 100: "\u{f70b}",
                                        101: "\u{f70c}", 109: "\u{f70d}", 103: "\u{f70e}", 111: "\u{f70f}"]
        return special[keyCode] ?? key.lowercased()
    }
    static func recorded(from event: NSEvent) -> WindowShortcut {
        let names: [UInt16: String] = [49: "空格", 36: "回车", 48: "Tab", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let flags = event.modifierFlags
        return WindowShortcut(keyCode: UInt32(event.keyCode), key: names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased(),
                              command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control))
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: WindowShortcut
    @ObservedObject var model: AppModel
    let onError: (String?) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("window-shortcut-recorder")
        button.setAccessibilityLabel("显示／隐藏窗口快捷键")
        return button
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onRecording = { model.isRecordingShortcut = $0 }
        button.onCapture = { shortcut = $0; onError(nil) }
        button.onError = onError
        button.updateTitle()
    }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.stopRecording() }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = WindowShortcut()
    var onRecording: (Bool) -> Void = { _ in }
    var onCapture: (WindowShortcut) -> Void = { _ in }
    var onError: (String?) -> Void = { _ in }
    private var recording = false
    private var windowObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stopRecording() }
        }
    }
    @objc private func beginRecording() {
        guard !recording else { stopRecording(); return }
        recording = true; onRecording(true); updateTitle()
        window?.makeFirstResponder(self)
    }
    func updateTitle() {
        title = recording ? "请按组合键…（Esc 取消）" : shortcut.label
        setAccessibilityValue(recording ? "正在录制" : shortcut.label)
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; onRecording(false); updateTitle()
    }
    override func resignFirstResponder() -> Bool { stopRecording(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording(); return }
        let candidate = WindowShortcut.recorded(from: event)
        do {
            try candidate.validate()
            shortcut = candidate; onCapture(candidate); stopRecording()
        } catch { onError(error.localizedDescription) }
    }
}
