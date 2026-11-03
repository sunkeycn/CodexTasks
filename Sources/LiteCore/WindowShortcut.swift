import Foundation

public struct WindowShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool
    public init(keyCode: UInt32 = 49, key: String = "空格", command: Bool = true, shift: Bool = true, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode; self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
    public var label: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key }
    public func validate() throws {
        guard keyCode <= 126, ![54,55,56,57,58,59,60,61,62,63,53].contains(keyCode),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 16,
              command || option || control else { throw LiteError.message("快捷键需要包含 ⌘、⌥ 或 ⌃，并搭配一个按键。") }
        if command && !shift && !option && !control && [0,6,7,8,9,12,29,43,45].contains(keyCode) {
            throw LiteError.message("该快捷键已用于应用菜单，请增加修饰键或换一个组合。")
        }
    }
}
