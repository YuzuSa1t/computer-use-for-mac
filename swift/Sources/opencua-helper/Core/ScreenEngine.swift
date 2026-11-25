import Foundation
import Cocoa
import CoreGraphics
import ImageIO

/// Screenshots + the "view" coordinate system. `captureView` binds a window
/// snapshot to an id; agents pass coordinates in that snapshot's pixel space,
/// and the helper maps them back to global screen coordinates (handling
/// Retina scale and window movement).
final class ScreenEngine {
    static let shared = ScreenEngine()

    struct View {
        let id: String
        let pid: pid_t
        let windowID: CGWindowID
        let frame: CGRect      // global top-left space, points
        let scale: CGFloat     // image pixels per point
        let width: Int
        let height: Int
        let createdAt: Date
    }

    private var views: [String: View] = [:]
    private let lock = NSLock()

    func preflightScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Window info (bounds in global top-left space) from CGWindowList.
    static func windowInfo(windowID: CGWindowID) -> (pid: pid_t, frame: CGRect, title: String)? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        guard let info = list?.first,
              let pidNum = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat else { return nil }
        let title = (info[kCGWindowName as String] as? String) ?? ""
        return (pidNum, CGRect(x: x, y: y, width: w, height: h), title)
    }

    /// Capture a window, store it as a "view", return the view descriptor.
    func captureView(pid: pid_t, windowID: CGWindowID, maxEdge: Int = 1600) -> [String: Any]? {
        guard let img = CGWindowListCreateImage(CGRectNull, [.optionIncludingWindow], windowID,
                                               [.bestResolution]) else { return nil }
        guard let info = ScreenEngine.windowInfo(windowID: windowID) else { return nil }
        let w = img.width
        let h = img.height
        let scale = CGFloat(w) / max(1, info.frame.width)
        let id = UUID().uuidString
        let view = View(id: id, pid: pid, windowID: windowID, frame: info.frame,
                        scale: scale, width: w, height: h, createdAt: Date())
        store(view: view, image: img)
        // Only the fields the caller actually uses: view_id to address the view,
        // width/height as the pixel bounds for coordinates, scale for Retina
        // mapping. window_id/pid/frame stay inside the helper.
        var out: [String: Any] = [
            "view_id": id, "width": w, "height": h, "scale": Double(scale),
        ]
        out["png_base64"] = Self.pngBase64(img, maxEdge: maxEdge)
        return out
    }

    private var images: [String: CGImage] = [:]

    private func store(view: View, image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        images[view.id] = image
        views[view.id] = view
        if views.count > 12, let oldest = views.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            views[oldest] = nil
            images[oldest] = nil
        }
    }

    func lookupView(_ id: String) -> View? {
        lock.lock(); defer { lock.unlock() }
        return views[id]
    }

    func imagePNG(viewID: String, maxEdge: Int = 1600) -> Data? {
        lock.lock()
        let img = images[viewID]
        lock.unlock()
        guard let img else { return nil }
        return Self.pngData(img, maxEdge: maxEdge)
    }

    /// Map a point in view (screenshot-pixel) space to global top-left point space.
    func globalPoint(view: View, x: Double, y: Double) -> CGPoint {
        CGPoint(x: view.frame.minX + CGFloat(x) / view.scale,
                y: view.frame.minY + CGFloat(y) / view.scale)
    }

    /// If the window moved since capture, the view is stale.
    func isStale(_ view: View) -> Bool {
        guard let info = ScreenEngine.windowInfo(windowID: view.windowID) else { return true }
        return abs(info.frame.origin.x - view.frame.minX) > 1 || abs(info.frame.origin.y - view.frame.minY) > 1
    }

    /// True when nothing other than `pid` covers the middle of this window.
    ///
    /// The overlay draws above every other window, so outlining a window that
    /// sits behind someone else's app would draw a rectangle on top of the
    /// wrong thing and claim it is being controlled. When the window is buried,
    /// the announcement is skipped and only the in-window effects run — those
    /// are clipped to the window anyway.
    static func isWindowVisible(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let ours = windowInfo(windowID: windowID)?.frame else { return false }
        // Only the middle matters: a window may legitimately be partly covered
        // by the Dock or a floating palette and still be the thing being driven.
        let core = ours.insetBy(dx: ours.width * 0.2, dy: ours.height * 0.2)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        for info in list {   // front-to-back order
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let num = info[kCGWindowNumber as String] as? Int ?? 0
            if num == Int(windowID) { return true }
            let owner = info[kCGWindowOwnerPID as String] as? Int32
            guard owner != pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
                  w > 40, h > 40 else { continue }
            // Another app's window in front of ours, overlapping the core.
            if CGRect(x: x, y: y, width: w, height: h).intersects(core) { return false }
        }
        return false   // never reached our own window: not on screen
    }

    // MARK: - coordinate conversion (AX top-left space → AppKit space)

    /// AX/CGWindow frames use top-left origin; AppKit window frames use
    /// bottom-left origin. Convert for the overlay panel.
    static func appKitFrame(fromTopLeft f: CGRect) -> NSRect {
        let tl = EventEngine.cgPoint(fromTopLeft: CGPoint(x: f.minX, y: f.minY))
        return NSRect(x: f.minX, y: tl.y - f.height, width: f.width, height: f.height)
    }

    static func appKitLocalPoint(fromTopLeft p: CGPoint, inAppKitFrame frame: NSRect) -> NSPoint {
        let c = EventEngine.cgPoint(fromTopLeft: p)
        return NSPoint(x: c.x - frame.minX, y: c.y - frame.minY)
    }

    // MARK: - PNG

    static func pngData(_ image: CGImage, maxEdge: Int) -> Data? {
        var img: CGImage = image
        let longEdge = max(img.width, img.height)
        if longEdge > maxEdge {
            let factor = CGFloat(maxEdge) / CGFloat(longEdge)
            let w = Int(CGFloat(img.width) * factor)
            let h = Int(CGFloat(img.height) * factor)
            if let scaled = Self.resize(img, w, h) { img = scaled }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func pngBase64(_ image: CGImage, maxEdge: Int) -> String {
        pngData(image, maxEdge: maxEdge).map { $0.base64EncodedString() } ?? ""
    }

    private static func resize(_ image: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
