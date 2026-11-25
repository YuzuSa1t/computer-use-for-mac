import Foundation
import Cocoa
import CoreGraphics

/// CGEvent synthesis — the "coordinate track". All events are posted with a
/// *private event source* via `CGEventPostToPid`, which:
///   1. does not move or touch the user's real cursor,
///   2. does not steal focus / raise windows,
/// so agents operate apps in the background while the user keeps working.
final class EventEngine {
    static let shared = EventEngine()

    private let source: CGEventSource?

    init() {
        // kCGEventSourceStatePrivate (-1): a private source keeps synthetic events
        // out of the combined session state — the user's cursor never moves.
        if let privateState = CGEventSourceStateID(rawValue: -1) {
            source = CGEventSource(stateID: privateState)
        } else {
            source = CGEventSource(stateID: .combinedSessionState)
        }
    }

    // MARK: - coordinate conversion

    /// Convert a point in global top-left (AppKit/AX) space to CG (bottom-left)
    /// space, flipping within the screen that contains the point.
    static func cgPoint(fromTopLeft p: CGPoint) -> CGPoint {
        var result = p
        runOnMain {
            for screen in NSScreen.screens {
                if NSPointInRect(p, screen.frame) {
                    let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
                    let cgBounds = CGDisplayBounds(did)
                    result = CGPoint(x: p.x, y: cgBounds.maxY - (p.y - screen.frame.minY))
                    return
                }
            }
        }
        return result
    }

    private func flags(for holdKeys: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for k in holdKeys {
            switch k.lowercased() {
            case "cmd", "command", "meta": f.insert(.maskCommand)
            case "ctrl", "control": f.insert(.maskControl)
            case "alt", "option", "opt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            default: break
            }
        }
        return f
    }

    // MARK: - mouse

    func click(pid: pid_t, at point: CGPoint, button: String = "left",
               count: Int = 1, holdKeys: [String] = []) -> String? {
        let type: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp
        let cgBtn: CGMouseButton = button == "right" ? .right : .left
        let f = flags(for: holdKeys)
        for _ in 0..<max(1, count) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: type,
                                     mouseCursorPosition: point, mouseButton: cgBtn),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: cgBtn) else {
                return "failed to create click events"
            }
            if !f.isEmpty { down.flags = f }
            down.postToPid(pid)
            usleep(45_000)
            up.postToPid(pid)
            usleep(80_000)
        }
        return nil
    }

    func drag(pid: pid_t, from start: CGPoint, to end: CGPoint, button: String = "left") -> String? {
        let cgBtn: CGMouseButton = button == "right" ? .right : .left
        let downType: CGEventType = button == "right" ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == "right" ? .rightMouseUp : .leftMouseUp
        guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                 mouseCursorPosition: start, mouseButton: cgBtn),
              let up = CGEvent(mouseEventSource: source, mouseType: upType,
                               mouseCursorPosition: end, mouseButton: cgBtn) else {
            return "failed to create drag events"
        }
        down.postToPid(pid)
        usleep(60_000)
        let steps = 10
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mid = CGPoint(x: start.x + (end.x - start.x) * t,
                              y: start.y + (end.y - start.y) * t)
            guard let mv = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                   mouseCursorPosition: mid, mouseButton: cgBtn) else { continue }
            mv.postToPid(pid)
            usleep(25_000)
        }
        up.postToPid(pid)
        return nil
    }

    func scroll(pid: pid_t, at point: CGPoint, direction: String, pixels: Int) -> String? {
        let delta: Int32 = {
            let d = Int32(clamping: pixels)
            return direction == "up" ? d : -d
        }()
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                               wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
            return "failed to create scroll event"
        }
        // pixel scroll events also carry a position
        ev.location = point
        ev.postToPid(pid)
        return nil
    }

    // MARK: - keyboard

    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 98, "f5": 97, "f6": 96, "f7": 95,
        "f8": 94, "f9": 93, "f10": 92, "f11": 91, "f12": 90,
        "cmd": 55, "command": 55, "meta": 55, "shift": 56, "ctrl": 59, "control": 59,
        "alt": 58, "option": 58, "opt": 58,
    ]

    static func keyCode(for name: String) -> CGKeyCode? {
        let lower = name.lowercased()
        if let code = keyCodes[lower] { return code }
        if lower.count == 1, let scalar = lower.unicodeScalars.first {
            // US layout: a-z, 0-9
            if scalar.value >= 97 && scalar.value <= 122 { return CGKeyCode(scalar.value - 97 + 0x41) }
            if scalar.value >= 48 && scalar.value <= 57 { return CGKeyCode(scalar.value - 48 + 0x1D) }
        }
        return nil
    }

    /// Press a key chord like ["cmd","c"] on a target process (background-safe for
    /// menu shortcuts on many apps; for unreliable targets use keyboard typing mode
    /// which briefly focuses the app).
    func keyChord(pid: pid_t, keys: [String]) -> String? {
        guard !keys.isEmpty else { return "empty keys" }
        var held: [CGKeyCode] = []
        var mainKey: CGKeyCode?
        for k in keys {
            let lower = k.lowercased()
            if ["cmd", "command", "meta", "ctrl", "control", "alt", "option", "opt", "shift"].contains(lower) {
                if let c = EventEngine.keyCodes[lower] { held.append(c) }
            } else if mainKey == nil {
                mainKey = EventEngine.keyCode(for: k)
                if mainKey == nil { return "unknown key: \(k)" }
            }
        }
        func post(_ code: CGKeyCode, _ down: Bool) {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            ev.postToPid(pid)
        }
        for m in held { post(m, true) }
        if let k = mainKey {
            post(k, true)
            usleep(35_000)
            post(k, false)
        }
        for m in held.reversed() { post(m, false) }
        return nil
    }

    /// Type unicode text via CGEventKeyboardSetUnicodeString (background-safe).
    func typeText(pid: pid_t, text: String) -> String? {
        var sent = 0
        for chunk in splitForUnicode(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            let units = Array(chunk.utf16)
            units.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            }
            down.postToPid(pid)
            usleep(20_000)
            up.postToPid(pid)
            usleep(15_000)
            sent += chunk.unicodeScalars.count
        }
        return sent == text.unicodeScalars.count ? nil : "typed \(sent)/\(text.count) chars"
    }

    /// CGEvent unicode strings cap around 20 UTF-16 code units; split safely.
    private func splitForUnicode(_ s: String) -> [String] {
        var utf16 = Array(s.utf16)
        guard utf16.count > 20 else { return [s] }
        var out: [String] = []
        while !utf16.isEmpty {
            let take = min(20, utf16.count)
            let units = Array(utf16.prefix(take))
            utf16.removeFirst(take)
            out.append(String(utf16CodeUnits: units, count: take))
        }
        return out
    }
}
