import AppKit

/// Editing keys only: app shortcuts such as Command-W must never leave the controlled page.
struct BrowserKey {
    let code: UInt16
    let characters: String
    let modifiers: NSEvent.ModifierFlags

    init(_ value: String) throws {
        var parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let raw = parts.removeLast()
        let name = raw.count == 1 ? raw.lowercased() : raw
        let flags = try Self.modifiers(parts, key: name)
        let keys: [String: (UInt16, String)] = [
            "Enter": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Backspace": (51, "\u{7f}"),
            "Delete": (117, "\u{f728}"), "Space": (49, " "), "Home": (115, "\u{f729}"), "End": (119, "\u{f72b}"),
            "PageUp": (116, "\u{f72c}"), "PageDown": (121, "\u{f72d}"),
            "ArrowLeft": (123, "\u{f702}"), "ArrowRight": (124, "\u{f703}"),
            "ArrowDown": (125, "\u{f701}"), "ArrowUp": (126, "\u{f700}"),
        ]
        let letters = Array("asdfhgzxcvbqwertyuiopljknm")
        let codes: [UInt16] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 37, 38, 40, 45, 46,
        ]
        if let key = keys[name] {
            code = key.0
            characters = key.1
        } else if name.count == 1, let index = name.first.flatMap({ letters.firstIndex(of: $0) }) {
            code = codes[index]
            characters = flags.contains(.shift) ? name.uppercased() : name
        } else {
            throw BrowserAutomationError.unavailable("Unsupported key. See browser --help.")
        }
        modifiers = flags
    }
    private static func modifiers(_ parts: [String], key name: String) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            let flag: NSEvent.ModifierFlags
            switch part {
            case "Shift": flag = .shift
            case "Control": flag = .control
            case "Alt": flag = .option
            case "Meta": flag = .command
            default: throw BrowserAutomationError.unavailable("Unknown key modifier.")
            }
            guard !flags.contains(flag) else { throw BrowserAutomationError.unavailable("Repeated key modifier.") }
            flags.insert(flag)
        }
        let arrows = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace", "Delete"]
        if flags.contains(.command) {
            guard parts.allSatisfy({ ["Meta", "Shift"].contains($0) }),
                ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace"].contains(name)
            else { throw BrowserAutomationError.unavailable("Only browser editing shortcuts are supported.") }
        } else if !flags.isDisjoint(with: [.control, .option]) && !arrows.contains(name) {
            throw BrowserAutomationError.unavailable("Control and Alt are supported with arrows and deletion keys.")
        }
        return flags
    }

}
