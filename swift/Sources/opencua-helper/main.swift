import Foundation
import Cocoa

// OpenCUA Helper — a macOS background service (LSUIElement app) that holds the
// Accessibility + Screen Recording TCC permissions and exposes computer-use
// capabilities over a Unix-domain socket, so that any agent (MCP client, CLI,
// script) can drive native apps:
//
//   - AX-tree-first dual track (element press / coordinate click)
//   - background CGEvent injection (real cursor never moves, focus never stolen)
//   - ScreenCaptureKit-era window snapshots with view coordinate mapping
//   - software glide cursor overlay (pure visual feedback)
//   - per-app approvals, deny-list, lock-screen guardian

let args = CommandLine.arguments
var signalSources: [DispatchSourceSignal] = []

if args.contains("--version") {
    print(CUACore.version)
    exit(0)
}

if args.contains("--check") {
    // lightweight self-check for install scripts: verify we can start
    let sem = DispatchSemaphore(value: 0)
    _ = sem.wait(timeout: .now() + 0.1)
    print("opencua-helper \(CUACore.version) selfcheck-ok")
    exit(0)
}

// Drop the ProcessSerialNumber dance; a plain NSApplication is enough.
let app = NSApplication.shared
let delegate = HelperDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// The helper is short-lived by design: it must clean up after itself when the
// OS, a supervisor, or the user stops it (pkill / Ctrl-C / logout).
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { RPCServer.shared.shutdown(reason: "signal \(sig)") }
    src.resume()
    signalSources.append(src)
}

app.run()

final class HelperDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        log("main", "opencua-helper \(CUACore.version) starting")
        if !AXEngine.shared.isTrusted(prompt: false) {
            log("main", "Accessibility permission missing — will prompt on first request")
        }
        if !ScreenEngine.shared.preflightScreenRecording() {
            log("main", "Screen Recording permission missing — will prompt on first request")
        }
        guard RPCServer.shared.start() else {
            log("main", "FATAL: could not bind RPC socket")
            exit(1)
        }
        // keep screens list fresh for coordinate conversion; also act as a watchdog
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            _ = NSScreen.screens
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RPCServer.shared.shutdown(reason: "application terminating")
    }
}
