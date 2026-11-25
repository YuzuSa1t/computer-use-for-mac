import Foundation
import Cocoa

/// Policy + safety: per-app approval, deny-list, lock-screen guardian.
/// Actions are refused *before* anything runs when policy says no.
final class PolicyEngine {
    static let shared = PolicyEngine()

    private(set) var config: [String: Any] = [:]
    private let lock = NSRecursiveLock()

    /// Runtime visual overrides, pushed by `lifecycle.set`.
    private var runtimeCursor: Bool?
    private var runtimeAnnounce: Bool?
    /// Once a client has pushed its policy, the helper's own environment is no
    /// longer consulted. A reused helper inherited the env of whichever process
    /// spawned it first, so honouring that env would pin the visuals to a stale
    /// setting for the rest of the helper's life.
    private var visualPolicySynced = false
    /// `zh` / `en`; nil follows the system locale.
    private var runtimeLang: String?

    /// sessionApprovals: runtime (non-persistent) approvals for this helper run.
    private var sessionApprovals: Set<String> = []
    /// pendingApprovalDefer: per-target waiters, woken by `approval.respond`.
    private var pending: [(target: String, waiter: () -> Void)] = []

    static let defaultDeny: [String] = [
        "com.apple.Terminal", "Terminal", "iTerm2", "com.googlecode.iterm2",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systemuiserver",
        "com.apple.preference.security", "com.apple.keychainaccess",
        "com.apple.Passwords", "1Password", "com.1password.1password",
        CUACore.helperBundleID, "com.apple.ScreenSaverServer", "com.apple.lockscreen",
    ]

    init() {
        loadConfig()
    }

    private func loadConfig() {
        let url = URL(fileURLWithPath: CUACore.configPath)
        config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        if config["version"] == nil { config["version"] = 1 }
        if config["cursor"] == nil { config["cursor"] = true }
        if config["announce"] == nil { config["announce"] = true }
    }

    private func saveConfig() {
        let dir = (CUACore.configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CUACore.configPath))
        }
    }

    func isCursorEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !visualPolicySynced,
           ProcessInfo.processInfo.environment["OPENCUA_CURSOR"] == "0" { return false }
        return runtimeCursor ?? (config["cursor"] as? Bool) ?? true
    }

    /// The engagement announcement — window outline + "controlling <app>" pill.
    /// Separate from `cursor` because the two answer different questions: the
    /// cursor says *where*, the announcement says *what is happening at all*.
    func isAnnounceEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !visualPolicySynced,
           ProcessInfo.processInfo.environment["OPENCUA_ANNOUNCE"] == "0" { return false }
        return runtimeAnnounce ?? (config["announce"] as? Bool) ?? true
    }

    /// Overrides pushed by `lifecycle.set`. The helper's own environment is
    /// frozen at spawn time, so a flag set on a later client would otherwise be
    /// ignored for the whole life of a reused helper.
    ///
    /// Assignment is unconditional: whichever client spoke last owns the
    /// policy, and a client that says nothing clears the override so the config
    /// file applies again. Keeping a stale `false` around would make the next
    /// client's defaults unreachable.
    func setVisualOverrides(cursor: Bool?, announce: Bool?) {
        lock.lock(); defer { lock.unlock() }
        visualPolicySynced = true
        runtimeCursor = cursor
        runtimeAnnounce = announce
    }

    /// Language for the on-screen announcement. `OPENCUA_LANG=zh|en` wins, then
    /// the system locale. Only the badge is translated — everything else the
    /// helper emits is machine-facing.
    func announcementLanguage() -> String {
        lock.lock(); defer { lock.unlock() }
        if let l = runtimeLang, l == "zh" || l == "en" { return l }
        if let l = ProcessInfo.processInfo.environment["OPENCUA_LANG"], l == "zh" || l == "en" {
            return l
        }
        return (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false) ? "zh" : "en"
    }

    func setLanguage(_ lang: String?) {
        lock.lock(); defer { lock.unlock() }
        runtimeLang = lang
    }

    /// When true, unknown apps (not in allow/deny) are treated as allowed
    /// without waiting for an interactive approval. Defaults to true so the
    /// tool works out-of-the-box for CLI/MCP use; set `auto_approve:false`
    /// in config or `OPENCUA_AUTO_APPROVE=0` to require explicit per-app
    /// approval (production / multi-tenant scenarios).
    func isAutoApprove() -> Bool {
        if ProcessInfo.processInfo.environment["OPENCUA_AUTO_APPROVE"] == "0" { return false }
        lock.lock(); defer { lock.unlock() }
        return (config["auto_approve"] as? Bool) ?? true
    }

    // MARK: - policy decisions

    enum Decision { case allowed, blocked, needsApproval }

    func decide(target: String) -> Decision {
        lock.lock(); defer { lock.unlock() }
        let deny = (config["deny"] as? [String]) ?? PolicyEngine.defaultDeny
        let allow = (config["allow"] as? [String]) ?? []
        if deny.contains(where: { target == $0 }) { return .blocked }
        if allow.contains(where: { target == $0 }) { return .allowed }
        if sessionApprovals.contains(target) { return .allowed }
        // deny-list is the hard guard; unknown apps are allowed by default
        // unless auto_approve is explicitly off.
        if (config["auto_approve"] as? Bool) ?? true,
           ProcessInfo.processInfo.environment["OPENCUA_AUTO_APPROVE"] != "0" {
            return .allowed
        }
        return .needsApproval
    }

    func isBlocked(target: String) -> Bool { decide(target: target) == .blocked }

    /// Approve for this session (and optionally persist).
    func approve(target: String, always: Bool) {
        lock.lock(); defer { lock.unlock() }
        sessionApprovals.insert(target)
        if always {
            var allow = (config["allow"] as? [String]) ?? []
            if !allow.contains(target) { allow.append(target) }
            config["allow"] = allow
            saveConfig()
        }
        pending.removeAll { $0.target == target }
        pending.forEach { $0.waiter() }
        pending.removeAll { $0.target == target }
    }

    func decline(target: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0.target == target }
        pending.forEach { $0.waiter() }
        pending.removeAll { $0.target == target }
    }

    /// Wait (with timeout) for an out-of-band approval response. The RPC layer
    /// publishes `approval.request` to clients and calls approve/decline on reply.
    func waitForApproval(target: String, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        lock.lock()
        pending.append((target, { sem.signal() }))
        lock.unlock()
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock()
        let ok = sessionApprovals.contains(target)
        pending.removeAll { $0.target == target }
        lock.unlock()
        return ok
    }

    func allowList() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "allow": (config["allow"] as? [String]) ?? [],
            "deny": ((config["deny"] as? [String]) ?? []) + PolicyEngine.defaultDeny,
            "session": Array(sessionApprovals),
        ]
    }

    func updateAllow(add: [String], remove: [String]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var allow = (config["allow"] as? [String]) ?? []
        for a in add where !allow.contains(a) { allow.append(a) }
        for r in remove { allow.removeAll { $0 == r } }
        config["allow"] = allow
        saveConfig()
        return ["allow": allow]
    }

    // MARK: - lock screen guardian

    /// Screen locked / no user console session → refuse all actions.
    func isLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return true // no GUI session (fast user switched out)
        }
        if (dict["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if (dict["kCGSessionOnConsoleKey"] as? Bool) == false { return true }
        return false
    }

    // MARK: - permission requests

    func requestPermissions(prompt: Bool) -> [String: Any] {
        let ax = AXEngine.shared.isTrusted(prompt: prompt)
        let srPrompt = ScreenEngine.shared.requestScreenRecording()
        let srNow = ScreenEngine.shared.preflightScreenRecording()
        return [
            "accessibility": ax,
            "screen_recording": srNow,
            "all_granted": ax && srNow,
            "screen_recording_prompted": srPrompt,
        ]
    }

    func permissionStatus() -> [String: Any] {
        let ax = AXEngine.shared.isTrusted(prompt: false)
        let sr = ScreenEngine.shared.preflightScreenRecording()
        return [
            "accessibility": ax,
            "screen_recording": sr,
            "all_granted": ax && sr,
        ]
    }
}
