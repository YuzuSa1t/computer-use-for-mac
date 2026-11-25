import Foundation
import Cocoa

/// High-level operation implementations over the core engines, shared by all
/// RPC methods. `target` resolution + policy guard + AX/CG dual-track logic
/// all live here.
enum Ops {
    struct Resolved {
        let pid: pid_t
        let name: String       // localized app name, for the announcement badge
        let windowID: CGWindowID?
        let frame: CGRect?     // top-left space
    }

    static func resolveTarget(_ params: [String: Any]) -> (String, Resolved)? {
        let target = params["target_id"] as? String
            ?? params["target"] as? String
            ?? params["app"] as? String ?? ""
        guard !target.isEmpty else { return nil }
        guard let t = AppInventory.resolve(target) else { return nil }
        var windowID: CGWindowID?
        var frame: CGRect?
        if let n = params["window_id"] as? NSNumber {
            windowID = CGWindowID(n.uint64Value)
        } else if let first = t.windows.first, let n = first["window_id"] as? Int {
            windowID = CGWindowID(n)
        }
        if let wid = windowID, let info = ScreenEngine.windowInfo(windowID: wid) {
            frame = info.frame
        }
        return (t.id, Resolved(pid: t.pid, name: t.name, windowID: windowID, frame: frame))
    }

    /// Tell the person that this app is now under control. Cheap to call from
    /// every action: the overlay absorbs repeats and holds one standing
    /// announcement for as long as the actions keep arriving.
    ///
    /// A buried window gets no announcement, and one that becomes buried loses
    /// the announcement it had. The overlay sits above everything, so outlining
    /// a hidden window would paint a rectangle on top of whatever the person is
    /// actually looking at — and naming the wrong window is worse than saying
    /// nothing.
    static func announce(targetID: String, _ res: Resolved) {
        announce(targetID: targetID, res, windowID: res.windowID)
    }

    /// Same, but naming the window explicitly.
    ///
    /// An app can own several windows, and an element belongs to one of them.
    /// Announcing the app's first window while pressing a button in its second
    /// one would outline the wrong rectangle — worse than outlining none.
    static func announce(targetID: String, _ res: Resolved, windowID: CGWindowID?) {
        guard let wid = windowID else { return }
        let frame = ScreenEngine.windowInfo(windowID: wid)?.frame ?? res.frame
        guard let frame else { return }
        guard ScreenEngine.isWindowVisible(pid: res.pid, windowID: wid) else {
            CursorOverlay.shared.endEngagement()
            return
        }
        CursorOverlay.shared.announceControl(appName: res.name, targetID: targetID,
                                             windowFrameTopLeft: frame,
                                             pid: res.pid, windowID: wid)
    }

    private static func toDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Parse a coordinate: [x,y] array or {"x":..,"y":..} in view/screenshot space,
    /// or already-global top-left if no view_id is given.
    static func globalPoint(from params: [String: Any], key: String = "coordinate",
                            view: ScreenEngine.View?) -> CGPoint? {
        guard let x = toDouble((params[key] as? [Any])?.count == 2
                ? (params[key] as? [Any])?[0]
                : (params[key] as? [String: Any])?["x"]) else { return nil }
        guard let y = toDouble((params[key] as? [Any])?.count == 2
                ? (params[key] as? [Any])?[1]
                : (params[key] as? [String: Any])?["y"]) else { return nil }
        if let view {
            return ScreenEngine.shared.globalPoint(view: view, x: x, y: y)
        }
        return CGPoint(x: x, y: y)
    }

    static func view(from params: [String: Any]) -> ScreenEngine.View? {
        guard let vid = params["view_id"] as? String else { return nil }
        return ScreenEngine.shared.lookupView(vid)
    }
}

enum AppState {
    /// Build app state: window list + AX element tree + a fresh screenshot view.
    /// NEVER activates the target app — AX tree reading and screenshots both
    /// work on background apps. If the app has no on-screen window, return
    /// an error so the caller can decide whether to open it.
    static func build(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params) else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found or not running"]
        }
        var out: [String: Any] = ["target_id": targetID]

        // Every agent reads state before acting, so this is the first honest
        // moment to say "this app is now being driven".
        Ops.announce(targetID: targetID, res)

        if let winID = res.windowID {
            let maxNodes = params["max_nodes"] as? Int ?? 600
            let maxDepth = params["max_depth"] as? Int ?? 14
            // Synthetic focus: set the AX window as focused WITHOUT activating
            // the app. This makes some apps process subsequent CGEvents even
            // when not frontmost, but doesn't steal the user's focus.
            let axWins = AXEngine.shared.windows(pid: res.pid)
            if axWins.isEmpty {
                out["tree_error"] = "AX returned 0 windows for pid \(res.pid) — app may need restart"
            }
            var chosen: AXUIElement?
            for w in axWins {
                if let f = AXEngine.shared.frame(w), let rf = res.frame,
                   abs(f.minX - rf.minX) < 40, abs(f.minY - rf.minY) < 40 {
                    chosen = w; break
                }
            }
            if chosen == nil, let first = axWins.first { chosen = first }
            if let chosen {
                // Synthetic focus — trick the app into thinking its window is key,
                // without changing NSWorkspace.frontmostApplication.
                AXEngine.shared.syntheticFocus(element: chosen)
                let box = AXEngine.shared.buildTree(window: chosen, pid: res.pid,
                                                    windowID: winID,
                                                    maxNodes: maxNodes, maxDepth: maxDepth)
                out["state_id"] = box.id
                out["tree"] = box.tree
            }
            if params["with_view"] as? Bool ?? true {
                if let view = ScreenEngine.shared.captureView(pid: res.pid, windowID: winID) {
                    out["view"] = view
                } else {
                    out["view_error"] = "capture failed — check Screen Recording permission"
                }
            }
        } else {
            out["windows"] = []
            out["hint"] = "no on-screen window; pass show=true or open the app first"
        }
        return out
    }

    /// Element-level action: press / set value / generic AX action.
    static func elementAction(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params) else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found"]
        }
        Ops.announce(targetID: targetID, res)
        guard let stateID = params["state_id"] as? String,
              let index = params["element"] as? Int,
              let (element, _) = AXEngine.shared.element(byIndex: index, stateID: stateID) else {
            return ["code": "BAD_ELEMENT", "message": "missing/invalid state_id or element index — call app.state first"]
        }
        let action = params["action"] as? String ?? "press"
        if action == "set_value" || action == "type" {
            guard let value = params["value"] as? String else {
                return ["code": "BAD_PARAMS", "message": "set_value requires value"]
            }
            if let err = AXEngine.shared.setValue(element, value) {
                return ["code": "SET_FAILED", "message": err]
            }
            return ["ok": true, "action": "set_value"] as [String: Any]
        }
        let axAction: String
        switch action {
        case "press": axAction = kAXPressAction as String
        case "raise": axAction = kAXRaiseAction as String
        case "show_menu": axAction = kAXShowMenuAction as String
        case "increment": axAction = kAXIncrementAction as String
        case "decrement": axAction = kAXDecrementAction as String
        case "confirm": axAction = kAXConfirmAction as String
        case "cancel": axAction = kAXCancelAction as String
        case "pick": axAction = kAXPickAction as String
        default:
            return ["code": "BAD_PARAMS", "message": "unsupported action \(action)"]
        }
        let err = AXUIElementPerformAction(element, axAction as CFString)
        guard err == .success else {
            return ["code": "AX_ACTION_FAILED", "message": "AXAction \(action) failed (\(err.rawValue))"]
        }
        _ = targetID
        return ["ok": true, "action": action] as [String: Any]
    }

    /// Screenshot of a captured view (PNG base64).
    static func shot(params: [String: Any]) -> Any {
        if let vid = params["view_id"] as? String,
           let png = ScreenEngine.shared.imagePNG(viewID: vid, maxEdge: params["max_edge"] as? Int ?? 1600) {
            return ["view_id": vid, "png_base64": png.base64EncodedString()] as [String: Any]
        }
        guard let (_, res) = Ops.resolveTarget(params), let winID = res.windowID else {
            return ["code": "NO_WINDOW", "message": "no window to capture"]
        }
        guard let view = ScreenEngine.shared.captureView(pid: res.pid, windowID: winID,
                                                        maxEdge: params["max_edge"] as? Int ?? 1600) else {
            return ["code": "CAPTURE_FAILED", "message": "capture failed — check Screen Recording permission"]
        }
        return view
    }
}

enum InputOps {
    /// Click. Two tracks:
    ///  - element index → AXPress (~ms, instant)
    ///  - coordinate → CGEvent at pixel position
    /// BOTH tracks show a glide cursor animation, so the user can follow what
    /// is happening even when the press itself is instant.
    /// NEITHER track calls activate() — the target app stays in the background.
    static func click(params: [String: Any]) -> Any {
        if let stateID = params["state_id"] as? String, let index = params["element"] as? Int {
            guard let (element, box) = AXEngine.shared.element(byIndex: index, stateID: stateID) else {
                return ["code": "BAD_ELEMENT", "message": "invalid state_id/element — call app.state first"]
            }
            // Announce here too, not only on the coordinate track. This is the
            // fast path, so an agent that reads state once and then clicks a
            // dozen times would otherwise drive the app with the engagement
            // never raised — and the badge, which is supposed to live as long
            // as the actions do, would have nothing holding it open.
            //
            // The window comes from the element's own state box rather than
            // from the app's first window: the click is about *that* window.
            if let (targetID, res) = Ops.resolveTarget(params) {
                Ops.announce(targetID: targetID, res, windowID: box.windowID)
            }
            let acts = AXEngine.shared.actions(element)
            // Glide to the element's center BEFORE pressing — visual feedback
            // that makes an otherwise invisible action followable.
            //
            // The window frame comes from AX, which is also the thing that
            // decides whether an element has a frame at all. When AX is having
            // a bad day it returns neither, and pressing anyway would move a
            // button with no pointer anywhere near it — the exact "did
            // something just happen?" the overlay exists to prevent. So fall
            // back to the window server, which knows the window regardless.
            //
            // The fallback goes through `box.windowID`, not the app: an app can
            // own several windows, and outlining the wrong one is worse than
            // outlining none.
            let winFrame = box.windowFrame
                ?? ScreenEngine.windowInfo(windowID: box.windowID)?.frame
            if let elemFrame = AXEngine.shared.frame(element),
               PolicyEngine.shared.isCursorEnabled(),
               let winFrame {
                CursorOverlay.shared.glideClick(windowFrameTopLeft: winFrame,
                                                targetTopLeft: CGPoint(x: elemFrame.midX, y: elemFrame.midY))
                // Let the cursor land before the press: action follows the
                // pointer, never the other way round. `instant` opts out of the
                // wait — same contract as the coordinate track, so a caller
                // that cannot afford the delay gets it on both routes.
                if !(params["instant"] as? Bool ?? false) {
                    Thread.sleep(forTimeInterval: 0.30)
                }
            }
            if acts.contains(kAXPressAction as String) {
                if let err = AXEngine.shared.press(element) {
                    return ["code": "AX_FAILED", "message": err]
                }
                return ["ok": true, "route": "ax"] as [String: Any]
            }
            // no press action → fall through to coordinate click at element center
            guard let f = AXEngine.shared.frame(element) else {
                return ["code": "AX_FAILED", "message": "element not pressable and has no frame"]
            }
            var merged = params
            merged["coordinate"] = [f.midX, f.midY]
            merged["coordinate_space"] = "global_top_left"
            merged.removeValue(forKey: "state_id")
            merged.removeValue(forKey: "element")
            return click(params: merged)
        }

        guard let (targetID, res) = Ops.resolveTarget(params), let pid = res.windowID != nil ? res.pid : nil else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found or no window"]
        }
        Ops.announce(targetID: targetID, res)
        let view = Ops.view(from: params)
        let space = params["coordinate_space"] as? String ?? (view != nil ? "view" : "global_top_left")
        guard space == "global_top_left" || view != nil else {
            return ["code": "BAD_PARAMS", "message": "coordinate with view space requires view_id from app.state"]
        }
        if let v = view, ScreenEngine.shared.isStale(v) {
            return ["code": "VIEW_STALE", "message": "window moved since capture — call app.state again"]
        }
        guard let gtl = Ops.globalPoint(from: params, view: space == "view" ? view : nil) else {
            return ["code": "BAD_PARAMS", "message": "coordinate must be [x, y]"]
        }
        let button = params["button"] as? String ?? "left"
        let count = params["count"] as? Int ?? 1
        let hold = params["hold_keys"] as? [String] ?? []

        // NO activate() — CGEventPostToPid sends events directly to the target
        // process without requiring it to be frontmost. The user's focus is
        // never stolen. Synthetic focus was already set during app.state.

        // glide cursor over the target window, then synthetic click
        if PolicyEngine.shared.isCursorEnabled(), let frameTL = res.frame ?? view.map({ $0.frame }) {
            CursorOverlay.shared.glideClick(windowFrameTopLeft: frameTL, targetTopLeft: gtl)
            if !(params["instant"] as? Bool ?? false) { Thread.sleep(forTimeInterval: 0.30) }
        }
        let cg = EventEngine.cgPoint(fromTopLeft: gtl)
        if let err = EventEngine.shared.click(pid: pid, at: cg, button: button, count: count, holdKeys: hold) {
            return ["code": "EVENT_FAILED", "message": err]
        }
        return ["ok": true, "route": "cg",
                "global": [Int(gtl.x), Int(gtl.y)]] as [String: Any]
    }

    static func drag(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params), res.windowID != nil else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found or no window"]
        }
        Ops.announce(targetID: targetID, res)
        let view = Ops.view(from: params)
        guard let from = Ops.globalPoint(from: params, key: "from", view: view),
              let to = Ops.globalPoint(from: params, key: "to", view: view) else {
            return ["code": "BAD_PARAMS", "message": "drag requires from/to coordinates"]
        }
        let cgFrom = EventEngine.cgPoint(fromTopLeft: from)
        let cgTo = EventEngine.cgPoint(fromTopLeft: to)
        if let err = EventEngine.shared.drag(pid: res.pid, from: cgFrom, to: cgTo,
                                             button: params["button"] as? String ?? "left") {
            return ["code": "EVENT_FAILED", "message": err]
        }
        _ = targetID
        return ["ok": true, "route": "cg"] as [String: Any]
    }

    static func scroll(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params), res.windowID != nil else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found or no window"]
        }
        Ops.announce(targetID: targetID, res)
        let view = Ops.view(from: params)
        let gtl = Ops.globalPoint(from: params, view: view) ?? (res.frame.map { CGPoint(x: $0.midX, y: $0.midY) })
        guard let gtl else { return ["code": "BAD_PARAMS", "message": "scroll needs a coordinate or window"] }
        let direction = params["direction"] as? String ?? "down"
        let pixels = params["pixels"] as? Int ?? 300
        let cg = EventEngine.cgPoint(fromTopLeft: gtl)
        if let err = EventEngine.shared.scroll(pid: res.pid, at: cg, direction: direction, pixels: pixels) {
            return ["code": "EVENT_FAILED", "message": err]
        }
        return ["ok": true] as [String: Any]
    }

    static func key(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params) else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found"]
        }
        Ops.announce(targetID: targetID, res)
        let keys = params["keys"] as? [String]
            ?? (params["keys"] as? String).map { [$0] }
            ?? []
        guard !keys.isEmpty else { return ["code": "BAD_PARAMS", "message": "keys required"] }
        if let err = EventEngine.shared.keyChord(pid: res.pid, keys: keys) {
            return ["code": "EVENT_FAILED", "message": err]
        }
        return ["ok": true] as [String: Any]
    }

    /// Type text. Mode "ax" sets AXValue on the app's focused element (background,
    /// no IME); mode "keyboard" posts unicode CGEvents to the pid.
    static func type(params: [String: Any]) -> Any {
        guard let (targetID, res) = Ops.resolveTarget(params) else {
            return ["code": "TARGET_NOT_FOUND", "message": "app not found"]
        }
        Ops.announce(targetID: targetID, res)
        guard let text = params["text"] as? String else {
            return ["code": "BAD_PARAMS", "message": "text required"]
        }
        let mode = params["mode"] as? String ?? "ax"

        if mode == "ax" || mode == "auto" {
            if let stateID = params["state_id"] as? String, let index = params["element"] as? Int,
               let (element, _) = AXEngine.shared.element(byIndex: index, stateID: stateID) {
                if let err = AXEngine.shared.setValue(element, text) {
                    return ["code": "SET_FAILED", "message": err]
                }
                return ["ok": true, "route": "ax", "mode": "element_set"] as [String: Any]
            }
            if let focused = AXEngine.shared.focusedElement(pid: res.pid) {
                if let err = AXEngine.shared.setValue(focused, text) {
                    return ["code": "SET_FAILED", "message": err + " — try mode=keyboard"]
                }
                return ["ok": true, "route": "ax", "mode": "focused_set"] as [String: Any]
            }
            if mode == "ax" {
                return ["code": "NO_FIELD", "message": "no focused text field — pass element index, or mode=keyboard"]
            }
        }
        if let err = EventEngine.shared.typeText(pid: res.pid, text: text) {
            return ["code": "EVENT_FAILED", "message": err]
        }
        return ["ok": true, "route": "cg", "mode": "keyboard"] as [String: Any]
    }
}
