import Foundation
import Cocoa

/// Unix-domain-socket JSON-RPC server (newline-delimited JSON, one object per
/// line). Multiple clients can stay connected; approval requests are broadcast
/// to every client, the first `approval.respond` wins.
final class RPCServer {
    static let shared = RPCServer()

    private var serverFD: Int32 = -1
    private var clients: [Int32] = []
    private let clientsLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "opencua.rpc.accept")
    private let workQueue = DispatchQueue(label: "opencua.rpc.work", attributes: .concurrent)

    // MARK: - lifetime / idle watchdog
    //
    // The helper is a *tool*, not a daemon: it must not outlive the work it does.
    // It exits by itself when
    //   - no client is connected any more (grace period, default 20s), or
    //   - a client stays connected but sends nothing (hard idle, default 900s),
    //   - a client asks explicitly (`shutdown` / `opencua stop`).
    // It is respawned lazily by the next request, so exiting is always safe.
    private let stateLock = NSLock()
    private var activeOps = 0
    private var lastActivityAt = Date()
    private var lastClientChangeAt = Date()
    private var startedAt = Date()
    private var shuttingDown = false

    /// Seconds to stay alive after the last client disconnects.
    /// `< 0` never exits on disconnect, `0` exits immediately.
    /// A connected client may override this at runtime (`lifecycle.set`) so the
    /// env of the client that is actually using the helper wins, not the env of
    /// whichever process happened to spawn it first.
    private var exitGraceOverride: TimeInterval?
    private var exitGrace: TimeInterval {
        if let o = exitGraceOverride { return o }
        guard let raw = ProcessInfo.processInfo.environment["OPENCUA_EXIT_GRACE"],
              let v = Double(raw) else { return 20 }
        return v
    }

    /// Hard ceiling on inactivity while clients are still attached. `0` disables.
    private var idleTimeoutOverride: TimeInterval?
    private var idleTimeout: TimeInterval {
        if let o = idleTimeoutOverride { return o }
        guard let raw = ProcessInfo.processInfo.environment["OPENCUA_IDLE_TIMEOUT"],
              let v = Double(raw) else { return 900 }
        return v
    }

    private var keepAliveForever: Bool {
        ProcessInfo.processInfo.environment["OPENCUA_KEEP_ALIVE"] == "1"
    }

    /// True when another helper already owns the socket — the freshly spawned
    /// process must stand down instead of stealing (and orphaning) the live one.
    static func isAnotherInstanceLive() -> Bool {
        let path = CUACore.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) - 1 else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    /// Exclusive lock held for as long as this process lives; the kernel drops
    /// it on exit (even SIGKILL), so a stale file never blocks a restart.
    private var lockFD: Int32 = -1
    private func acquireSingleInstanceLock() -> Bool {
        let fd = open(CUACore.lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // best effort: never block startup
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    func start() -> Bool {
        let path = CUACore.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // A helper is a single shared resource. Two clients may race to spawn
        // one at the same moment; the loser must exit instead of orphaning the
        // winner's socket.
        guard acquireSingleInstanceLock() else {
            log("rpc", "another helper holds the single-instance lock — standing down")
            exit(0)
        }
        if RPCServer.isAnotherInstanceLive() {
            log("rpc", "another helper already owns \(path) — standing down")
            exit(0)
        }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("rpc", "socket() failed"); return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) - 1 else {
            log("rpc", "socket path too long"); return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { log("rpc", "bind failed: \(String(cString: strerror(errno)))"); return false }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { log("rpc", "listen failed"); return false }
        serverFD = fd
        startedAt = Date()
        acceptQueue.async { [self] in acceptLoop() }
        log("rpc", "listening at \(path)")
        startWatchdog()
        return true
    }

    // MARK: - idle watchdog

    private func startWatchdog() {
        guard !keepAliveForever else {
            log("rpc", "keep-alive forced by OPENCUA_KEEP_ALIVE=1 — no auto exit")
            return
        }
        let grace = exitGrace
        let idle = idleTimeout
        log("rpc", String(format: "auto-exit: %.0fs after last client leaves, %.0fs hard idle",
                          grace, idle))
        runOnMain { [self] in
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard !keepAliveForever else { return }

        stateLock.lock()
        let ops = activeOps
        let idle = Date().timeIntervalSince(lastActivityAt)
        let sinceClient = Date().timeIntervalSince(lastClientChangeAt)
        stateLock.unlock()
        guard ops == 0 else { return }   // never interrupt work in flight

        clientsLock.lock()
        let connected = !clients.isEmpty
        clientsLock.unlock()

        if !connected {
            let grace = exitGrace
            if grace >= 0 && sinceClient >= grace {
                shutdown(reason: String(format: "no client for %.0fs", sinceClient))
            }
            return
        }
        let idleLimit = idleTimeout
        if idleLimit > 0 && idle >= idleLimit {
            shutdown(reason: String(format: "idle %.0fs with no requests", idle))
        }
    }

    private func noteClientChange() {
        stateLock.lock(); lastClientChangeAt = Date(); stateLock.unlock()
    }

    private func beginOp() {
        stateLock.lock()
        activeOps += 1
        lastActivityAt = Date()
        stateLock.unlock()
    }

    private func endOp() {
        stateLock.lock(); activeOps = max(0, activeOps - 1); stateLock.unlock()
    }

    /// Graceful teardown: hide the overlay cursor, close sockets, unlink the
    /// socket file, then exit. Safe to call from any thread, idempotent.
    func shutdown(reason: String) {
        stateLock.lock()
        if shuttingDown { stateLock.unlock(); return }
        shuttingDown = true
        stateLock.unlock()

        log("rpc", "shutting down — \(reason)")
        CursorOverlay.shared.shutdown()

        clientsLock.lock()
        let fds = clients
        clients.removeAll()
        clientsLock.unlock()
        for fd in fds { close(fd) }

        if serverFD >= 0 {
            closeListener()
        }
        try? FileManager.default.removeItem(atPath: CUACore.socketPath)
        // `_exit` instead of `exit`: nothing left to flush (logs are written
        // synchronously) and it guarantees an immediate death, so a client
        // cannot observe a "zombie half-alive" helper after stop.
        _exit(0)
    }

    private func acceptLoop() {
        while true {
            var client = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(serverFD, &client, &len)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                log("rpc", "accept failed"); return
            }
            clientsLock.lock()
            clients.append(fd)
            clientsLock.unlock()
            noteClientChange()
            workQueue.async { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &tmp, tmp.count)
            guard n > 0 else { break }
            buf.append(contentsOf: tmp[0..<n])
            while let idx = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<idx)
                buf.removeSubrange(buf.startIndex...idx)
                guard !line.isEmpty,
                      let msg = JSON.parse(line) else { continue }
                workQueue.async { [self] in handleMessage(fd, msg) }
            }
            if n < tmp.count && buf.isEmpty { continue }
        }
        clientsLock.lock()
        clients.removeAll { $0 == fd }
        let remaining = clients.count
        clientsLock.unlock()
        noteClientChange()
        // The last client hanging up is the one unambiguous end of a run: no
        // more actions can arrive, so the standing announcement has to go now
        // rather than wait out its idle window. A badge saying "being operated"
        // next to an app nobody is touching is worse than no badge at all.
        if remaining == 0 { CursorOverlay.shared.endEngagement() }
        close(fd)
    }

    private func send(_ fd: Int32, _ obj: [String: Any]) {
        let data = JSON.encodeLine(obj)
        _ = data.withUnsafeBytes { ptr in write(fd, ptr.baseAddress, data.count) }
    }

    private func broadcast(_ obj: [String: Any]) {
        clientsLock.lock()
        let fds = clients
        clientsLock.unlock()
        for fd in fds { send(fd, obj) }
    }

    // MARK: - dispatch

    private func handleMessage(_ fd: Int32, _ msg: [String: Any]) {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        beginOp()
        defer { endOp() }

        // client-side reply to a helper-initiated request
        if method == "approval.respond" {
            let target = params["target"] as? String ?? ""
            if let allow = params["allow"] as? Bool {
                if allow { PolicyEngine.shared.approve(target: target, always: params["always"] as? Bool ?? false) }
                else { PolicyEngine.shared.decline(target: target) }
            }
            if id != nil { send(fd, ["id": id as Any, "ok": true, "result": ["handled": true] as [String: Any]]) }
            return
        }

        let result = dispatch(method: method, params: params)
        var resp: [String: Any] = ["id": id as Any]
        if let err = result as? [String: String], err["code"] != nil {
            resp["ok"] = false
            resp["error"] = err
        } else {
            resp["ok"] = true
            resp["result"] = result
        }
        send(fd, resp)

        // explicit stop: reply first, then tear down so the caller sees `ok`.
        // Close the listening socket *before* exiting so that a client which
        // connects during the short drain window cannot attach to a dying
        // helper — it will get ECONNREFUSED and spawn a fresh one instead.
        if method == "shutdown" || method == "stop" {
            closeListener()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                shutdown(reason: "requested by client")
            }
        }
    }

    private func closeListener() {
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
    }

    /// Gate every action: permissions, lock screen, per-app approval.
    /// Returns an error object when the action must be refused.
    private func guardAction(targetID: String?) -> [String: Any]? {
        if PolicyEngine.shared.isLocked() {
            return ["code": "LOCKED", "message": "screen is locked — refusing to act"]
        }
        guard let targetID else { return nil }
        switch PolicyEngine.shared.decide(target: targetID) {
        case .blocked:
            return ["code": "APP_BLOCKED", "message": "target \(targetID) is not allowed for AI automation"]
        case .needsApproval:
            broadcast(["method": "approval.request", "params": ["target": targetID]])
            let granted = PolicyEngine.shared.waitForApproval(target: targetID, timeout: 90)
            if !granted {
                return ["code": "NOT_APPROVED", "message": "user did not approve \(targetID)"]
            }
        case .allowed:
            break
        }
        return nil
    }

    private func dispatch(method: String, params: [String: Any]) -> Any {
        switch method {
        case "health":
            stateLock.lock()
            let uptime = Date().timeIntervalSince(startedAt)
            let idle = Date().timeIntervalSince(lastActivityAt)
            let ops = activeOps
            stateLock.unlock()
            clientsLock.lock()
            let clientCount = clients.count
            clientsLock.unlock()
            let autoExit: Any = keepAliveForever
                ? "disabled"
                : (["grace_seconds": Int(exitGrace), "idle_seconds": Int(idleTimeout)] as [String: Any])
            return [
                "ok": true, "version": CUACore.version, "protocol": CUACore.protocolVersion,
                "permissions": PolicyEngine.shared.permissionStatus(),
                "locked": PolicyEngine.shared.isLocked(),
                "cursor": PolicyEngine.shared.isCursorEnabled(),
                "announce": PolicyEngine.shared.isAnnounceEnabled(),
                "announcing": CursorOverlay.shared.engagedTargetID() as Any,
                "auto_approve": PolicyEngine.shared.isAutoApprove(),
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "uptime_seconds": Int(uptime),
                "idle_seconds": Int(idle),
                "clients": clientCount,
                "in_flight": ops,
                "auto_exit": autoExit,
            ] as [String: Any]

        case "shutdown", "stop":
            return ["stopping": true] as [String: Any]

        case "lifecycle.set":
            if let g = params["exit_grace"] as? Double { exitGraceOverride = g }
            if let i = params["idle_seconds"] as? Double { idleTimeoutOverride = i }
            PolicyEngine.shared.setVisualOverrides(cursor: params["cursor"] as? Bool,
                                                   announce: params["announce"] as? Bool)
            if let lang = params["lang"] as? String { PolicyEngine.shared.setLanguage(lang) }
            log("rpc", String(format: "auto-exit updated by client: %.0fs grace, %.0fs idle",
                              exitGrace, idleTimeout))
            return ["exit_grace": exitGrace, "idle_seconds": idleTimeout] as [String: Any]

        case "permissions.request":
            return PolicyEngine.shared.requestPermissions(prompt: true)
        case "permissions.status":
            return PolicyEngine.shared.permissionStatus()
        case "policy.list":
            return PolicyEngine.shared.allowList()
        case "policy.set":
            let add = params["allow_add"] as? [String] ?? []
            let remove = params["allow_remove"] as? [String] ?? []
            return PolicyEngine.shared.updateAllow(add: add, remove: remove)

        case "apps":
            let apps = AppInventory.list()
            return ["apps": apps.map { a in
                var o: [String: Any] = ["target_id": a.id, "name": a.name, "pid": Int(a.pid),
                                        "focused": a.focused, "window_count": a.windows.count,
                                        "operable": !a.blocked && !a.windows.isEmpty]
                if !a.windows.isEmpty { o["windows"] = a.windows }
                if a.blocked { o["compliance"] = ["blocked": true] }
                return o
            }] as [String: Any]

        case "app.open":
            if let err = guardAction(targetID: nil) { return err }
            let name = params["app"] as? String ?? params["name"] as? String ?? ""
            let hidden = params["hidden"] as? Bool ?? true
            if let err = AppInventory.open(app: name, hidden: hidden) {
                return ["code": "OPEN_FAILED", "message": err]
            }
            return ["opened": name] as [String: Any]

        case "app.open_url":
            if let err = guardAction(targetID: nil) { return err }
            let url = params["url"] as? String ?? ""
            let app = params["app"] as? String
            if let err = AppInventory.open(url: url, app: app) {
                return ["code": "OPEN_FAILED", "message": err]
            }
            return ["opened": url] as [String: Any]

        case "app.state", "app.element", "screen.shot",
             "input.click", "input.drag", "input.scroll", "input.key", "input.type":
            // policy gate BEFORE anything runs
            let raw = params["target_id"] as? String ?? params["target"] as? String
                ?? params["app"] as? String ?? ""
            if let t = AppInventory.resolve(raw) {
                if let err = guardAction(targetID: t.id) { return err }
            }
            switch method {
            case "app.state": return AppState.build(params: params)
            case "app.element": return AppState.elementAction(params: params)
            case "screen.shot": return AppState.shot(params: params)
            case "input.click": return InputOps.click(params: params)
            case "input.drag": return InputOps.drag(params: params)
            case "input.scroll": return InputOps.scroll(params: params)
            case "input.key": return InputOps.key(params: params)
            case "input.type": return InputOps.type(params: params)
            default: break
            }
            return ["code": "UNKNOWN_METHOD", "message": "unreachable"]

        default:
            return ["code": "UNKNOWN_METHOD", "message": "unknown method \(method)"]
        }
    }
}
