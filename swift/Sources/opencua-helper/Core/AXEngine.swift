import Foundation
import Cocoa
import ApplicationServices

/// AX (Accessibility) engine — the element track of the dual-track design.
/// Reads the accessibility tree and acts on elements directly
/// (AXPress / AXSetValue): fast, coordinate-independent, and immune to window
/// movement or occlusion.
final class AXEngine {
    static let shared = AXEngine()

    func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    func appElement(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    /// Copy an attribute value as a raw CF object.
    private func copyRef(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }

    /// Copy an attribute that holds an array. Returns AnyObject elements
    /// (CFTypeRef values are pointer-sized reference types), so callers can
    /// safely unsafeBitCast to AXUIElement / AXValue when the AX API contract
    /// guarantees the element type.
    private func copyArray(_ element: AXUIElement, _ attr: String) -> [AnyObject]? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard err == .success, let ref else {
            log("ax", "copyArray(\(attr)) error: \(err.rawValue)")
            return nil
        }
        let arr = unsafeBitCast(ref, to: NSArray.self)
        // NSArray elements are already reference types; bridging through
        // `as? AnyObject` only produced a compiler warning.
        return (0..<arr.count).map { arr.object(at: $0) as AnyObject }
    }

    /// String attribute, safely. AX attributes are not always strings — sliders
    /// and checkboxes return NSNumber for kAXValueAttribute, and force-casting
    /// those to NSString triggers -[__NSCFNumber length] and crashes the helper.
    /// Use `as? String` so non-strings simply yield nil.
    func string(_ element: AXUIElement, _ attr: String) -> String? {
        guard let ref = copyRef(element, attr) else { return nil }
        return ref as? String
    }

    /// Numeric attribute, safely (used for kAXValueAttribute on sliders etc.).
    func number(_ element: AXUIElement, _ attr: String) -> Double? {
        guard let ref = copyRef(element, attr) else { return nil }
        return (ref as? NSNumber)?.doubleValue
    }

    /// Any attribute, returned as the best Swift representation we can get.
    func anyValue(_ element: AXUIElement, _ attr: String) -> Any? {
        guard let ref = copyRef(element, attr) else { return nil }
        return ref as Any
    }

    /// Children that are AXUIElements. kAXChildrenAttribute always holds
    /// AXUIElement refs (AX API contract), so the bitcast is safe here.
    func axElements(_ element: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let arr = copyArray(element, attr) else { return [] }
        return arr.map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    func windows(pid: pid_t) -> [AXUIElement] {
        axElements(appElement(pid: pid), kAXWindowsAttribute)
    }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        guard let ref = copyRef(appElement(pid: pid), kAXFocusedUIElementAttribute) else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    /// Frame in global top-left (AppKit-like) coordinates.
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = copyRef(element, kAXPositionAttribute) else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &pt) else { return nil }
        var sz = CGSize.zero
        if let sizeRef = copyRef(element, kAXSizeAttribute) {
            _ = AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &sz)
        }
        return CGRect(origin: pt, size: sz)
    }

    func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }

    /// Press an element (button / menu item / row). Returns nil on success.
    func press(_ element: AXUIElement) -> String? {
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return err == .success ? nil : "AXPress failed (\(err.rawValue))"
    }

    /// Set string value on a text-ish element (background typing, no IME involved).
    /// AX string values are plain CFStrings — no AXValue wrapping needed.
    func setValue(_ element: AXUIElement, _ value: String) -> String? {
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        return err == .success ? nil : "AXSetValue failed (\(err.rawValue))"
    }

    func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Synthetic focus — set kAXFocusedAttribute=true on a window element.
    /// This makes the app's event loop treat the window as key, so background
    /// CGEvent clicks get processed, WITHOUT calling NSRunningApplication.activate()
    /// or changing NSWorkspace.frontmostApplication. The user's focus is untouched.
    func syntheticFocus(element: AXUIElement) {
        // AX boolean attributes accept NSNumber/CFBoolean
        let focused = NSNumber(value: true)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, focused)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, focused)
    }

    // MARK: - Tree building

    struct StateBox {
        let id: String
        let pid: pid_t
        let windowID: CGWindowID
        let windowFrame: CGRect?    // global top-left space, for cursor overlay
        let elements: [AXUIElement]     // index -> element
        let tree: [[String: Any]]
        let createdAt: Date
    }

    private var stateBoxes: [String: StateBox] = [:]
    private let statesLock = NSLock()

    func storeState(_ box: StateBox) {
        statesLock.lock(); defer { statesLock.unlock() }
        for (k, v) in stateBoxes where Date().timeIntervalSince(v.createdAt) > 600 { stateBoxes[k] = nil }
        if stateBoxes.count > 16, let k = stateBoxes.keys.sorted(by: >).first { stateBoxes[k] = nil }
        stateBoxes[box.id] = box
    }

    func lookupState(_ id: String) -> StateBox? {
        statesLock.lock(); defer { statesLock.unlock() }
        return stateBoxes[id]
    }

    /// Build a compact, flat element tree for a window. Nodes carry an integer index
    /// usable by later `element` calls; parent links keep structure navigable.
    func buildTree(window: AXUIElement, pid: pid_t, windowID: CGWindowID,
                   maxNodes: Int, maxDepth: Int) -> StateBox {
        var nodes: [[String: Any]] = []
        var elements: [AXUIElement] = []
        var count = 0

        func describe(_ e: AXUIElement, _ parent: Int, _ depth: Int) {
            if count >= maxNodes || depth > maxDepth { return }
            let idx = count
            count += 1
            elements.append(e)
            var node: [String: Any] = ["i": idx, "p": parent]
            if let role = string(e, kAXRoleAttribute) { node["role"] = role }
            if let title = string(e, kAXTitleAttribute), !title.isEmpty {
                node["title"] = String(title.prefix(120))
            }
            if let desc = string(e, kAXDescriptionAttribute), !desc.isEmpty { node["desc"] = String(desc.prefix(120)) }
            if let val = string(e, kAXValueAttribute), !val.isEmpty {
                node["value"] = String(val.prefix(200))
            } else if let num = number(e, kAXValueAttribute) {
                // sliders / checkboxes / steppers expose numeric values
                node["value"] = num
            }
            if let idf = string(e, kAXIdentifierAttribute), !idf.isEmpty { node["id"] = String(idf.prefix(80)) }
            if let f = frame(e), f.width > 0, f.height > 0 {
                node["frame"] = [Int(f.minX.rounded()), Int(f.minY.rounded()),
                                 Int(f.width.rounded()), Int(f.height.rounded())]
            }
            // One boolean instead of the full AX action list: `press: true` is
            // the only fact the caller acts on (everything else is noise in the
            // payload), and it keeps the tree small enough to read at a glance.
            if actions(e).contains(kAXPressAction as String) { node["press"] = true }
            nodes.append(node)
            let kids = axElements(e, kAXChildrenAttribute)
            if !kids.isEmpty {
                nodes[idx]["kids"] = kids.count
                for k in kids { describe(k, idx, depth + 1) }
            }
        }

        describe(window, -1, 0)
        let id = UUID().uuidString
        let winFrame = frame(window)
        let box = StateBox(id: id, pid: pid, windowID: windowID,
                           windowFrame: winFrame,
                           elements: elements, tree: nodes, createdAt: Date())
        storeState(box)
        return box
    }

    /// Find an AXUIElement by state box + index.
    func element(byIndex index: Int, stateID: String) -> (AXUIElement, StateBox)? {
        guard let box = lookupState(stateID), index >= 0, index < box.elements.count else { return nil }
        return (box.elements[index], box)
    }
}
