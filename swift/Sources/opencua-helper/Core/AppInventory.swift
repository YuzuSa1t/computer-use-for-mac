import Foundation
import Cocoa

/// Running app inventory: the union of NSWorkspace running apps and
/// CGWindowList on-screen windows, with policy annotations.
enum AppInventory {
    struct Target {
        let id: String          // bundle id when available, else app name
        let name: String
        let pid: pid_t
        let bundleID: String?
        let focused: Bool
        let windows: [[String: Any]]   // {window_id, title, frame, layer}
        let blocked: Bool
    }

    static func list() -> [Target] {
        // 1) collect on-screen regular-layer windows by pid
        var windowsByPid: [pid_t: [[String: Any]]] = [:]
        guard let winList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        for info in winList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pidNum = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
                  w > 40, h > 40 else { continue }
            let winID = info[kCGWindowNumber as String] as? Int ?? 0
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let x = bounds["X"] as? CGFloat ?? 0
            let y = bounds["Y"] as? CGFloat ?? 0
            let entry: [String: Any] = ["window_id": winID, "title": title,
                                        "frame": [Int(x), Int(y), Int(w), Int(h)], "layer": layer]
            windowsByPid[pidNum, default: []].append(entry)
        }

        // 2) compose targets from running regular apps (with or without windows)
        var results: [Target] = []
        let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "pid-\(pid)"
            let bundleID = app.bundleIdentifier
            let id = bundleID ?? name
            let decision = PolicyEngine.shared.decide(target: id)
            results.append(Target(
                id: id, name: name, pid: pid, bundleID: bundleID,
                focused: focusedPID == pid,
                windows: windowsByPid[pid] ?? [],
                blocked: decision == .blocked
            ))
        }
        return results
    }

    /// Resolve a target by id / localized name / bundle id, case-insensitive,
    /// and also matching the last path component of the bundle id
    /// (e.g. "calculator" → com.apple.calculator) for localization-proof lookups.
    static func resolve(_ target: String) -> Target? {
        let lower = target.lowercased()
        let list = AppInventory.list()
        return list.first { $0.id == target || $0.name == target }
            ?? list.first { $0.id.lowercased() == lower || $0.name.lowercased() == lower }
            ?? list.first { $0.bundleID?.lowercased().hasSuffix("." + lower) == true }
    }

    /// Open an app (background by default — never steals focus). If already
    /// running and `show`, uses AX raise (synthetic, not NSRunningApplication.activate).
    static func open(app named: String, hidden: Bool) -> String? {
        let ws = NSWorkspace.shared
        if let running = ws.runningApplications.first(where: {
            $0.localizedName == named || $0.bundleIdentifier == named
        }) {
            // App already running. Never call activate() — if show=true,
            // use AX raise on its windows (visual only, doesn't change frontmost).
            if !hidden {
                let axWins = AXEngine.shared.windows(pid: running.processIdentifier)
                for w in axWins { AXEngine.shared.raise(w) }
            }
            return nil
        }
        if let url = ws.urlForApplication(withBundleIdentifier: named) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false   // always background launch
            let sem = DispatchSemaphore(value: 0)
            var failure: String?
            ws.openApplication(at: url, configuration: cfg) { _, err in
                failure = err?.localizedDescription
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 8)
            return failure
        }
        // try by name via /usr/bin/open -a
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = hidden ? ["-gj", "-a", named] : ["-a", named]
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "failed to open \(named) (exit \(p.terminationStatus))"
    }

    static func open(url: String, app named: String?) -> String? {
        guard let u = URL(string: url) else { return "invalid url" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-g"]
        if let named, !named.isEmpty { args += ["-a", named] }
        args.append(u.absoluteString)
        p.arguments = args
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : "failed to open url (exit \(p.terminationStatus))"
    }
}
