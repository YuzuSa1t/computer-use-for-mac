import Foundation
import Cocoa
import QuartzCore

/// Everything the person at the keyboard sees while the automation works.
///
/// The helper never changes what the target app draws, so without this layer an
/// agent is invisible — windows would simply mutate on their own. Three signals,
/// in increasing order of intrusiveness:
///
///  1. **Engagement** — the first touch of an app traces its window outline and
///     shows a small pill above it. Unlike the two below it, this one is *state*,
///     not an event: it holds for as long as the app keeps being operated and
///     only leaves when the run of actions does. This is the answer to "is
///     something driving my Mac right now?", and that question does not stop
///     being asked between two keystrokes.
///  2. **Presence** — a cursor glides to each target along a short arc with a
///     brief streak behind it, so every action has a visible author and a
///     visible direction.
///  3. **Impact** — a contact dot plus one thin ring expanding from the point.
///     Stroke only: a filled disc reads as a blue blob that appeared out of
///     nowhere, not as a click.
///
/// Everything here is decoration. Nothing in this file may block, delay or
/// alter the action itself.
final class CursorOverlay {
    static let shared = CursorOverlay()

    // One accent hue plus white. Restraint is the point — a second colour
    // starts to look like a notification, not like a pointer.
    fileprivate static let accent     = NSColor(srgbRed: 0.16, green: 0.56, blue: 1.00, alpha: 1.0)
    fileprivate static let accentSoft = NSColor(srgbRed: 0.58, green: 0.82, blue: 1.00, alpha: 1.0)

    private static let glideDuration: CFTimeInterval = 0.26
    private static let appearDuration: CFTimeInterval = 0.11
    private static let arrowSize = CGSize(width: 12, height: 22)

    /// How long the cursor takes to arrive. Nothing travels when there is no
    /// origin to travel from — it only fades in — so the press has to wait for
    /// the fade instead of the full glide, or the dip lands after the pulse.
    private static func arrival(withTrail: Bool) -> CFTimeInterval {
        withTrail ? glideDuration : appearDuration
    }

    /// A re-announcement after this much quiet means a genuinely new engagement.
    /// Long enough that a run of forty clicks is one announcement, short enough
    /// that coming back to the app ten minutes later is announced again.
    private static let announceGap: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["OPENCUA_ANNOUNCE_GAP"],
           let v = Double(raw), v >= 0 { return v }
        return 60
    }()

    /// How long the outline and the badge outlive the last action.
    ///
    /// They stay up while actions keep arriving, so this only has to cover the
    /// gap between two steps of one run — an agent waiting on a model, a caller
    /// pausing between fields. It cannot be "until the process exits": a client
    /// that stays connected while the person reads the screen would leave a pill
    /// claiming an app is being operated when nothing is, and a badge that lies
    /// is worse than no badge.
    private static let engagementIdle: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["OPENCUA_ENGAGEMENT_IDLE"],
           let v = Double(raw), v >= 0 { return v }
        return 30
    }()

    private var panel: NSPanel?
    private var cursorLayer: CAShapeLayer?
    private var trailLayer: CAShapeLayer?
    private var outlineLayer: CAShapeLayer?
    private var effectLayers: [CAShapeLayer] = []
    /// Panel-local, and only meaningful together with `lastPointFrame`: the
    /// panel is scoped to a single window, so a point from another window is
    /// not an origin, it is a different coordinate space.
    private var lastPoint: NSPoint?
    private var lastPointFrame: CGRect?

    /// Token that invalidates a pending hide when new activity arrives; without
    /// it a click's timer would tear down an announcement still fading out.
    private var hideToken = 0

    private var badgePanel: NSPanel?
    private var lastTouch: [String: Date] = [:]

    // Engagement state. Main-thread only — every path that reads or writes it
    // goes through `runOnMain`, and the badge and outline it describes are only
    // ever touched there.
    /// Which app the standing announcement is about, if one is up at all.
    private var engagedApp: String?
    /// Supersedes a pending expiry; bumped by every action that keeps the run
    /// alive and by every teardown.
    private var engagementToken = 0
    /// Kept so a window that moves can be re-announced without the caller
    /// repeating itself.
    private var engagedLabel = ""
    /// The window the standing announcement describes, for the occlusion watch.
    private var engagedPid: pid_t?
    private var engagedWindowID: CGWindowID?
    private var watchToken = 0
    private var watching = false

    // MARK: - Engagement

    /// Called on every action against `targetID`. Two jobs, in this order:
    /// hold the engagement open (cheap, always), and — only when this really is
    /// a new engagement — raise the badge and trace the outline.
    ///
    /// The distinction matters: this used to be a notification that rebuilt
    /// itself and expired 2.2 s later, so the pill appeared for a beat at the
    /// start of a run and then described nothing for the rest of it. It is a
    /// standing statement about the window, so it now lives exactly as long as
    /// the actions do.
    ///
    /// Cheap to call from every action: a repeat is one dictionary write and a
    /// timer bump, no matter how many actions arrive.
    func announceControl(appName: String, targetID: String, windowFrameTopLeft frameTL: CGRect,
                         pid: pid_t? = nil, windowID: CGWindowID? = nil) {
        guard PolicyEngine.shared.isAnnounceEnabled() else { return }

        let now = Date()
        let quietFor = now.timeIntervalSince(lastTouch[targetID] ?? .distantPast)
        lastTouch[targetID] = now
        if lastTouch.count > 64 {
            lastTouch = lastTouch.filter { now.timeIntervalSince($0.value) < Self.announceGap * 4 }
        }

        let label = Self.controlLabel(for: appName)
        let fresh = quietFor > Self.announceGap

        runOnMain { [self] in
            let frame = ScreenEngine.appKitFrame(fromTopLeft: frameTL)
            let isNew = fresh || engagedApp != targetID

            if isNew {
                engagedApp = targetID
                engagedLabel = label
                engagedPid = pid
                engagedWindowID = windowID
                showPanel(over: frame)
                if let view = panel?.contentView { traceOutline(in: view) }
                showBadge(label, above: frame)
                watchOcclusion()
            } else {
                // Same run, still going. Hold what is already drawn: rebuilding
                // it per action is what made the badge blink out of existence.
                reframe(over: frame)
            }
            holdEngagement()
        }
    }

    /// Follow the window if it moved or resized under a live engagement.
    ///
    /// Only when the frame actually changed: re-framing an unchanged window
    /// would restart the outline animation on every keystroke, which reads as
    /// the overlay glitching rather than as the window moving.
    private func reframe(over frame: NSRect) {
        guard let p = panel, p.frame != frame else { return }
        p.setFrame(frame, display: false)
        if let view = p.contentView { traceOutline(in: view) }
        showBadge(engagedLabel, above: frame)
    }

    /// Watch for the announced window disappearing behind something else.
    ///
    /// A standing border that lives for as long as a run does would otherwise
    /// paint itself over whatever the person put in front of the target window —
    /// an outline around somebody else's app is worse than no outline, because
    /// it names the wrong thing. The check is the same one used before the first
    /// announcement, so the two agree on what "visible" means.
    ///
    /// Cheap at rest: one window-list walk (`isWindowVisible`, a millisecond or
    /// two) every 1.5 s, and only while something is actually being operated. It
    /// runs inline rather than on a background queue on purpose — hopping
    /// threads only to inspect an array costs more in queue latency than the
    /// walk itself, and this way the border is gone within one interval of the
    /// window being covered.
    private func watchOcclusion() {
        guard !watching else { return }
        watching = true
        tickOcclusion()
    }

    private func tickOcclusion() {
        watchToken += 1
        let token = watchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard token == watchToken else { return }
            guard let pid = engagedPid, let wid = engagedWindowID else {
                watching = false
                return
            }
            if ScreenEngine.isWindowVisible(pid: pid, windowID: wid) {
                tickOcclusion()
            } else {
                watching = false
                endEngagement()
            }
        }
    }

    /// Which app the standing announcement currently belongs to, or `nil`.
    ///
    /// Exposed for `health` so a caller can tell "the badge is up" from "the
    /// badge is up but behind something" without taking a screenshot and
    /// guessing at pixels. Reads main-thread state, so it hops there.
    func engagedTargetID() -> String? {
        var out: String?
        runOnMain { [self] in out = engagedApp }
        return out
    }

    /// Push the expiry of the standing announcement out from now. Every action
    /// does this, so a run of any length is one unbroken statement.
    private func holdEngagement() {
        engagementToken += 1
        let token = engagementToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.engagementIdle) { [self] in
            guard token == engagementToken else { return }
            endEngagement()
        }
    }

    /// The run is over: retire the outline and the pill together.
    ///
    /// Called when the actions stop, and directly when the last client
    /// disconnects — that is the one moment we *know* the automation ended
    /// rather than merely went quiet.
    func endEngagement() {
        runOnMain { [self] in
            guard engagedApp != nil else { return }
            engagedApp = nil
            engagedPid = nil
            engagedWindowID = nil
            // Retire both timers: the expiry and the occlusion watch. Without
            // the token bumps a later tick would either resurrect nothing (it
            // bails on the nil window) or keep a token alive for the next run.
            engagementToken += 1
            watchToken += 1
            watching = false
            hideBadge()
            scheduleHide(after: 0)
        }
    }

    /// Fade the pill out and release it. Split from `endEngagement` because the
    /// panel fade and the badge fade run on their own clocks but must start
    /// together — a pill that outlives its window outline by half a second
    /// looks like two separate things happening.
    private func hideBadge() {
        guard let panel = badgePanel else { return }
        badgePanel = nil
        // Captured strongly on purpose: this method drops the only other
        // reference, so a weak capture would let the window deallocate before
        // its own exit animation ran, and the pill would vanish instead of
        // fading. The retain lasts 0.4 s and the completion is one-shot, so
        // there is no cycle to leak.
        (panel.contentView as? ControlBadgeView)?.playExit {
            panel.orderOut(nil)
            panel.close()
        }
    }

    /// Names the tool, not just the app: "something is controlling Calculator"
    /// is only useful if the person knows *what* something is. This is the one
    /// string they actually read, so it says it plainly.
    ///
    /// Spacing follows each language's own convention — a space between Latin
    /// and CJK, none inside a CJK phrase.
    private static func controlLabel(for appName: String) -> String {
        PolicyEngine.shared.announcementLanguage() == "zh"
            ? "OpenCUA 正在操作\(appName)"
            : "OpenCUA is operating \(appName)"
    }

    // MARK: - Click

    /// Glide to `targetTL` and pulse once on arrival. `windowFrameTopLeft` is
    /// the window the point belongs to — the panel is scoped to it so the
    /// overlay can never paint over unrelated windows.
    func glideClick(windowFrameTopLeft frameTL: CGRect, targetTopLeft targetTL: CGPoint) {
        guard PolicyEngine.shared.isCursorEnabled() else { return }
        runOnMain { [self] in
            let frame = ScreenEngine.appKitFrame(fromTopLeft: frameTL)
            let target = ScreenEngine.appKitLocalPoint(fromTopLeft: targetTL, inAppKitFrame: frame)
            showPanel(over: frame)
            // Everything below is panel-local: `target`, `from`, the path and
            // the layer positions all live in the content view's own space.
            let bounds = panel?.contentView?.bounds ?? CGRect(origin: .zero, size: frame.size)

            // A trail is only honest when the cursor genuinely came from
            // somewhere visible. The previous point is in the *old* panel's
            // space, so it counts only if the panel is still framed on the same
            // window; otherwise travelling from it would draw a line in from a
            // different app. In that case the cursor just fades in at the target.
            let previous: NSPoint? = {
                guard let p = lastPoint, lastPointFrame == frame else { return nil }
                return pointInside(bounds, p)
            }()
            var from = previous ?? NSPoint(x: target.x - 74, y: target.y - 44)
            // A repeat click on the same element would otherwise be a zero-length
            // glide, which reads as the cursor teleporting.
            if hypot(from.x - target.x, from.y - target.y) < 14 {
                from = NSPoint(x: target.x - 26, y: target.y - 18)
            }
            from = clampInside(from, bounds.insetBy(dx: 10, dy: 10), towards: target)
            lastPoint = target
            lastPointFrame = frame

            let path = Self.glidePath(from: from, to: target)
            // `previous` is the flag for "there is a real origin to follow".
            drawTrail(along: path, from: from, to: target, bounds: bounds,
                      visible: previous != nil)
            animateCursor(along: path, to: target, withTrail: previous != nil)
            let arrival = Self.arrival(withTrail: previous != nil)
            pulseClick(at: target, delay: arrival)
            dismissCursor(after: arrival + 1.5)
        }
    }

    private func pointInside(_ frame: CGRect, _ p: NSPoint) -> NSPoint? {
        frame.contains(p) ? p : nil
    }

    /// Slide `p` into `bounds` along the line to `target`, so the shortened path
    /// still aims at the same place.
    private func clampInside(_ p: NSPoint, _ bounds: CGRect, towards target: NSPoint) -> NSPoint {
        guard bounds.width > 2, bounds.height > 2 else { return p }
        if bounds.contains(p) { return p }
        guard let t = Self.exitParameter(from: p, towards: target, in: bounds) else { return p }
        let dx = target.x - p.x, dy = target.y - p.y
        let q = NSPoint(x: p.x + dx * t, y: p.y + dy * t)
        return NSPoint(x: min(max(q.x, bounds.minX), bounds.maxX),
                       y: min(max(q.y, bounds.minY), bounds.maxY))
    }

    /// Where the ray `from → towards` crosses out of `bounds`, as a fraction of
    /// the segment, or `nil` when it never does.
    ///
    /// The slab test picks, per axis, the *exit* plane — the maximum when
    /// travelling forward, the minimum when travelling back. Taking the minimum
    /// of both planes regardless of direction silently returns a negative
    /// parameter for any leftward or downward ray, which collapses the segment
    /// to zero length.
    private static func exitParameter(from p: NSPoint, towards target: NSPoint,
                                      in bounds: CGRect) -> CGFloat? {
        let dx = target.x - p.x, dy = target.y - p.y
        var t = CGFloat.infinity
        if dx > 0 { t = min(t, (bounds.maxX - p.x) / dx) }
        else if dx < 0 { t = min(t, (bounds.minX - p.x) / dx) }
        if dy > 0 { t = min(t, (bounds.maxY - p.y) / dy) }
        else if dy < 0 { t = min(t, (bounds.minY - p.y) / dy) }
        guard t.isFinite else { return nil }
        return max(0, min(1, t))
    }

    // MARK: - Panel

    private func showPanel(over frame: CGRect) {
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = NSView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = .clear
            p.contentView = view
            panel = p
        }
        panel?.setFrame(frame, display: false)
        // A previous fade-out left the model at 0; without this reset the panel
        // would come back invisible.
        panel?.contentView?.layer?.opacity = 1
        panel?.orderFrontRegardless()
    }

    /// Tear the overlay down completely — called when the helper exits, so no
    /// invisible panel or animation is left owning a screen surface.
    func shutdown() {
        runOnMain { [self] in
            hidePanel()
            panel?.orderOut(nil)
            panel?.close()
            panel = nil
            badgePanel?.orderOut(nil)
            badgePanel?.close()
            badgePanel = nil
            lastPoint = nil
            lastPointFrame = nil
            lastTouch.removeAll()
            // Nothing may outlive the process: a pending expiry timer holding
            // an engagement open would keep a badge alive over an app nobody is
            // driving any more.
            engagedApp = nil
            engagedPid = nil
            engagedWindowID = nil
            engagementToken += 1
            watchToken += 1
            watching = false
            hideToken += 1
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        cursorLayer?.removeFromSuperlayer()
        trailLayer?.removeFromSuperlayer()
        outlineLayer?.removeFromSuperlayer()
        for l in effectLayers { l.removeFromSuperlayer() }
        effectLayers.removeAll()
        cursorLayer = nil; trailLayer = nil; outlineLayer = nil
    }

    /// Dissolve the cursor once an action is over, and nothing else.
    ///
    /// The outline deliberately survives this: it is the standing half of the
    /// announcement, and tearing the whole panel down after every click made a
    /// run of keystrokes flash the window border on and off. Only when nothing
    /// is being operated any more does the panel itself go.
    ///
    /// Each call supersedes the previous timer, so a fast run of actions never
    /// leaves an older timer to clear a newer cursor.
    private func dismissCursor(after delay: TimeInterval) {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard token == hideToken else { return }
            fadeOutCursor()
            if engagedApp == nil { scheduleHide(after: 0) }
        }
    }

    /// Take the per-action layers off screen without disturbing the panel.
    /// Model opacity goes to 0 and the layers are then removed, so an
    /// interrupted fade leaves an invisible layer rather than a stuck arrow.
    private func fadeOutCursor() {
        var layers: [CAShapeLayer] = []
        if let c = cursorLayer { layers.append(c) }
        if let t = trailLayer { layers.append(t) }
        layers.append(contentsOf: effectLayers)
        cursorLayer = nil
        trailLayer = nil
        effectLayers.removeAll()
        guard !layers.isEmpty else { return }

        for l in layers {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = l.opacity
            fade.toValue = 0.0
            fade.duration = 0.20
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.opacity = 0
            l.add(fade, forKey: "cursorOut")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            for l in layers { l.removeFromSuperlayer() }
        }
    }

    /// Dissolve rather than cut — a panel that vanishes mid-gesture looks like a
    /// glitch. Each call supersedes the previous timer.
    ///
    /// This retires the engagement as well: the badge goes with the panel, and
    /// `engagedApp` is cleared, so the next action is a genuinely new
    /// announcement rather than a continuation of one that is already fading.
    private func scheduleHide(after delay: TimeInterval) {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard token == hideToken else { return }
            engagedApp = nil
            hideBadge()
            guard let layer = panel?.contentView?.layer else { return hidePanel() }
            layer.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(fade, forKey: "panelOut")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.29) { [self] in
                guard token == hideToken else { return }
                hidePanel()
            }
        }
    }

    // MARK: - Outline (window is under control)

    /// Trace the window border once and then hold it.
    ///
    /// It used to dissolve after 1.9 s, which made the outline read as a passing
    /// notice — and left the rest of a long run with no standing indication of
    /// which window was being driven. Now the trace is the entrance and the
    /// resting state is "drawn, slightly translucent", held until the
    /// engagement ends.
    private func traceOutline(in view: NSView) {
        outlineLayer?.removeFromSuperlayer()
        let rect = view.bounds.insetBy(dx: 2, dy: 2)
        guard rect.width > 8, rect.height > 8 else { return }

        let outline = CAShapeLayer()
        outline.path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        outline.fillColor = .clear
        outline.strokeColor = Self.accent.cgColor
        outline.lineWidth = 1.6
        outline.lineJoin = .round
        outline.shadowColor = Self.accent.cgColor
        outline.shadowOpacity = 0.7
        outline.shadowRadius = 6
        outline.shadowOffset = .zero
        // Model values hold the *resting* state — fully drawn at the opacity it
        // will sit at. A removed animation therefore leaves the correct picture
        // instead of a rectangle frozen mid-draw, which is what
        // `fillMode = .forwards` does to an interrupted stroke.
        outline.strokeEnd = 1.0
        outline.opacity = 0.85
        view.layer?.addSublayer(outline)
        outlineLayer = outline

        // Draw the perimeter so the eye can follow it…
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0.0
        draw.toValue = 1.0
        draw.duration = 0.5
        draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outline.add(draw, forKey: "trace")

        // …then fade up to the resting opacity and stay there. Settling just
        // below full is what keeps a standing border from competing with the
        // window's own chrome for attention.
        let settle = CABasicAnimation(keyPath: "opacity")
        settle.fromValue = 0.0
        settle.toValue = 0.85
        settle.duration = 0.55
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
        outline.add(settle, forKey: "settle")
    }

    // MARK: - Cursor

    private static func glidePath(from: NSPoint, to: NSPoint) -> CGPath {
        let dx = to.x - from.x, dy = to.y - from.y
        let c1 = NSPoint(x: from.x + dx * 0.28 - 14, y: from.y + dy * 0.12 + 10)
        let c2 = NSPoint(x: from.x + dx * 0.72 + 8, y: from.y + dy * 0.80 - 6)
        let p = CGMutablePath()
        p.move(to: from)
        p.addCurve(to: to, control1: c1, control2: c2)
        return p
    }

    /// A comet tail: a short streak trailing the cursor, absorbed as it lands.
    /// That is what makes a background click feel directed rather than
    /// spontaneous.
    ///
    /// Not a stroke along the whole path. A full-length line reads as an
    /// annotation somebody drew on the screen; a short streak reads as motion.
    ///
    /// The streak is its own small path, drawn once and then carried along the
    /// *same* curve as the cursor. Stroking the shared path with
    /// `strokeStart`/`strokeEnd` instead would drift: `position` advances by
    /// curve parameter while stroke fractions advance by arc length, so on a
    /// curved path the head falls behind the pointer and the tail stretches
    /// into a long line.
    private func drawTrail(along path: CGPath, from: NSPoint, to: NSPoint,
                           bounds: CGRect, visible: Bool) {
        guard let host = panel?.contentView?.layer else { return }
        trailLayer?.removeFromSuperlayer()
        guard visible else { return }

        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > 2 else { return }

        // Backwards along the chord, not along the curve: over a streak this
        // short the difference is invisible, and the chord costs nothing.
        let ux = (from.x - to.x) / distance
        let uy = (from.y - to.y) / distance
        // A third of the hop, capped so a long jump does not drag a rope and
        // floored so a short one still shows something. The cap is deliberately
        // small: past ~30 pt the streak stops reading as a wake and starts
        // reading as a line drawn on the screen.
        var length = min(max(distance * 0.30, 10), 28)
        // Never let the tail poke out of the window: the panel clips it, and a
        // streak cut off by the window edge looks like a rendering fault.
        let inner = bounds.insetBy(dx: 3, dy: 3)
        if inner.contains(to),
           let t = Self.exitParameter(from: to, towards: NSPoint(x: to.x + ux * length,
                                                                y: to.y + uy * length),
                                      in: inner) {
            length *= t
        }
        guard length > 6 else { return }

        let stub = CGMutablePath()
        let end = CGPoint(x: ux * length, y: uy * length)
        // A slight bow off the chord — a perfectly straight streak looks
        // mechanical, and the cursor's own path is curved. Kept shallow: over a
        // streak this short a strong bow reads as a hook rather than a wake.
        let bow = min(length * 0.12, 3)
        let control = CGPoint(x: ux * length * 0.5 - uy * bow,
                              y: uy * length * 0.5 + ux * bow)
        stub.move(to: .zero)
        stub.addQuadCurve(to: end, control: control)

        // A layer with zero bounds is culled by Core Animation and draws
        // nothing at all, so the geometry has to be real. Build it around the
        // stroke instead of trusting the path to overflow a point-sized layer.
        let pad = 6.0 // lineWidth + shadow radius, rounded up
        let box = stub.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)
        let shifted = CGMutablePath()
        shifted.move(to: CGPoint(x: -box.minX, y: -box.minY))
        shifted.addQuadCurve(to: CGPoint(x: end.x - box.minX, y: end.y - box.minY),
                             control: CGPoint(x: control.x - box.minX, y: control.y - box.minY))

        let trail = CAShapeLayer()
        trail.path = shifted
        trail.fillColor = .clear
        trail.strokeColor = Self.accentSoft.cgColor
        trail.lineWidth = 2.0
        trail.lineCap = .round
        trail.shadowColor = Self.accent.cgColor
        trail.shadowOpacity = 0.5
        trail.shadowRadius = 3
        trail.shadowOffset = .zero
        trail.bounds = CGRect(origin: .zero, size: box.size)
        // Bottom-left anchor, so `position` is the layer's own origin and the
        // tip lands exactly on the pointer.
        trail.anchorPoint = .zero
        trail.position = CGPoint(x: to.x + box.minX, y: to.y + box.minY)
        // Model values hold the finished state — invisible — so an interrupted
        // animation can only ever leave a clean panel behind.
        trail.opacity = 0
        host.addSublayer(trail)
        trailLayer = trail

        // Travel: the identical curve and timing as the cursor, so the streak's
        // tip stays exactly on the pointer for the whole trip.
        //
        // `position` is now the layer origin, not the tip — the tip sits at
        // `box.min` inside the layer. So a curve point C maps to origin
        // C - box.min, and the animated path is the cursor's path translated by
        // `+box.min`. Using the drawing offset here instead would push the
        // streak away from the cursor by twice that offset, which on a
        // bottom-left anchor is visibly up and to the right.
        var offset = CGAffineTransform(translationX: box.minX, y: box.minY)
        let glide = CAKeyframeAnimation(keyPath: "position")
        glide.path = path.copy(using: &offset)
        glide.duration = Self.glideDuration
        glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trail.add(glide, forKey: "glide")

        // Fades in behind the pointer, holds, then dissolves as it lands — a
        // streak that vanished abruptly would read as a dropped frame.
        trail.add(keyframes("opacity", [0, 0.8, 0.55, 0], [0, 0.18, 0.62, 1.0],
                            duration: Self.glideDuration * 1.25,
                            easing: [.easeOut, .linear, .easeIn]),
                  forKey: "fade")
    }

    /// A single shape layer, fill + white edge + blue glow.
    ///
    /// The anchor is the arrow tip, so `position` is exactly the point being
    /// acted on — with the default centre anchor the glyph sits half a body
    /// off-target and the pointer appears to miss every button.
    private func animateCursor(along path: CGPath, to target: NSPoint, withTrail: Bool) {
        guard let host = panel?.contentView?.layer else { return }
        cursorLayer?.removeFromSuperlayer()

        let cursor = CAShapeLayer()
        cursor.bounds = CGRect(origin: .zero, size: Self.arrowSize)
        cursor.anchorPoint = CGPoint(x: 0, y: 1)
        cursor.path = Self.arrowPath()
        cursor.fillColor = Self.accent.cgColor
        cursor.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        cursor.lineWidth = 0.9
        cursor.lineJoin = .round
        cursor.shadowColor = Self.accent.cgColor
        cursor.shadowOpacity = 0.55
        cursor.shadowRadius = 3
        cursor.shadowOffset = .zero
        cursor.position = target
        cursor.opacity = 1
        host.addSublayer(cursor)
        cursorLayer = cursor

        let glide = CAKeyframeAnimation(keyPath: "position")
        glide.path = path
        glide.duration = Self.glideDuration
        glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // `position` already holds the destination, so an interrupted glide
        // simply lands the cursor where it was going.
        if withTrail {
            cursor.add(glide, forKey: "glide")
        } else {
            // No origin to travel from: a glide would look like the cursor
            // slid in from a random direction, so it just appears. The model
            // opacity stays at 1, so removing this animation leaves the cursor
            // visible rather than blinking it back out.
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0.0
            appear.toValue = 1.0
            appear.duration = Self.appearDuration
            cursor.add(appear, forKey: "appear")
        }

        // The press dip. A cursor that merely arrives and stops reads as a
        // blink; one that sinks a little on contact reads as a click. This is
        // the whole difference between "something changed" and "I pressed that".
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1.0, 0.84, 1.0]
        dip.keyTimes = [0, 0.45, 1.0]
        dip.timingFunctions = [CAMediaTimingFunction(name: .easeIn),
                               CAMediaTimingFunction(name: .easeOut)]
        dip.duration = 0.17
        dip.beginTime = CACurrentMediaTime() + Self.arrival(withTrail: withTrail)
        cursor.add(dip, forKey: "press")
    }

    /// The classic pointer silhouette, tip at (0, 22) with the body extending
    /// down-right. Traced from the macOS cursor rather than invented: an arrow
    /// people already recognise needs no learning, which is the whole point of
    /// showing it. `bounds` matches the glyph exactly so the anchor can sit on
    /// the tip.
    private static func arrowPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 22))
        p.addLine(to: CGPoint(x: 0, y: 5.2))
        p.addLine(to: CGPoint(x: 4.2, y: 9.1))
        p.addLine(to: CGPoint(x: 6.6, y: 3.4))
        p.addLine(to: CGPoint(x: 9.0, y: 4.5))
        p.addLine(to: CGPoint(x: 6.7, y: 10.0))
        p.addLine(to: CGPoint(x: 11.6, y: 10.5))
        p.closeSubpath()
        return p
    }

    // MARK: - Impact

    /// One contact dot plus one expanding ring.
    ///
    /// Deliberately a single ring. Two concentric rings at similar radii read
    /// as a rendering artefact rather than as an effect — the eye sees a
    /// mis-drawn circle, not two beats. The dot carries the precision, the ring
    /// carries the motion, and that is enough.
    private func pulseClick(at point: NSPoint, delay: CFTimeInterval) {
        guard let host = panel?.contentView?.layer else { return }
        for l in effectLayers { l.removeFromSuperlayer() }
        effectLayers.removeAll()

        let t = CACurrentMediaTime() + delay

        // Contact dot: appears the instant the cursor lands, gone quickly.
        // Small and filled — at 5 pt it reads as a point, not as a blob.
        let dot = CAShapeLayer()
        let r: CGFloat = 2.4
        dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        dot.fillColor = Self.accentSoft.cgColor
        dot.strokeColor = .clear
        dot.position = point
        dot.opacity = 0
        dot.shadowColor = Self.accentSoft.cgColor
        dot.shadowOpacity = 1.0
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        host.addSublayer(dot)
        effectLayers.append(dot)

        dot.add(keyframes("opacity", [0, 0.95, 0.95, 0], [0, 0.10, 0.30, 1.0],
                          duration: 0.42, begin: t, easing: [.easeOut, .linear, .easeOut]),
                forKey: "dotFade")
        dot.add(keyframes("transform.scale", [1.0, 1.0, 0.6], [0, 0.30, 1.0],
                          duration: 0.42, begin: t, easing: [.linear, .easeIn]),
                forKey: "dotScale")

        // The ring: starts tight around the contact, expands well past the
        // target, fades on the way out. Short enough to stay a beat.
        let ring = self.ring(radius: 10, lineWidth: 1.4, color: Self.accent, at: point)
        ring.opacity = 0
        ring.shadowColor = Self.accent.cgColor
        ring.shadowOpacity = 0.7
        ring.shadowRadius = 5
        ring.shadowOffset = .zero
        host.addSublayer(ring)
        effectLayers.append(ring)

        ring.add(keyframes("transform.scale", [0.5, 2.6], [0, 1.0],
                           duration: 0.55, begin: t + 0.03, easing: [.easeOut]),
                  forKey: "grow")
        ring.add(keyframes("opacity", [0.85, 0], [0, 1.0],
                           duration: 0.55, begin: t + 0.03, easing: [.easeOut]),
                  forKey: "fade")
    }

    private func ring(radius: CGFloat, lineWidth: CGFloat, color: NSColor, at point: NSPoint) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                        transform: nil)
        l.fillColor = .clear
        l.strokeColor = color.cgColor
        l.lineWidth = lineWidth
        l.position = point
        l.opacity = 1
        return l
    }

    // MARK: - Badge (which app, and that it is live)

    /// Raise the pill above `windowFrame` and leave it up.
    ///
    /// It has no expiry of its own on purpose: this is the standing answer to
    /// "what is driving my Mac?", so its lifetime belongs to the engagement
    /// (`holdEngagement` / `endEngagement`), not to the moment it appeared. The
    /// previous version dropped it after 2.2 s, which meant the sentence was
    /// gone before anyone could read it twice.
    private func showBadge(_ text: String, above windowFrame: NSRect) {
        badgePanel?.orderOut(nil)
        badgePanel?.close()
        badgePanel = nil

        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let metrics = ControlBadgeView.measure(text: text, font: font)

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var x = windowFrame.midX - metrics.size.width / 2
        var y = windowFrame.maxY + 7
        // No room above (window against the menu bar) → sit inside the top edge,
        // which is the title-bar strip and therefore the least intrusive spot.
        if y + metrics.size.height > visible.maxY {
            y = windowFrame.maxY - metrics.size.height - 9
        }
        x = min(max(x, visible.minX + 8), visible.maxX - metrics.size.width - 8)

        let rect = NSRect(x: x, y: y, width: metrics.size.width, height: metrics.size.height)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = ControlBadgeView(frame: NSRect(origin: .zero, size: rect.size),
                                    text: text, font: font, metrics: metrics)
        p.contentView = view
        p.orderFrontRegardless()
        badgePanel = p
        view.playEntrance()
    }

    // MARK: - Animation helpers

    private func keyframes(_ path: String, _ values: [Double], _ times: [Double],
                           duration: CFTimeInterval, begin: CFTimeInterval = 0,
                           easing: [CAMediaTimingFunction]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.timingFunctions = easing
        a.duration = duration
        a.beginTime = begin == 0 ? CACurrentMediaTime() : begin
        // Deliberately NOT `fillMode = .forwards` with `isRemovedOnCompletion =
        // false`. Every layer here is initialised with its final value in the
        // model, so letting the animation be removed on completion is what keeps
        // a cancelled or pre-empted animation from freezing a half-drawn shape
        // on screen.
        return a
    }
}

// MARK: - Badge view

/// A small pill: a softly pulsing dot, then the app name. Drawn as a view
/// rather than text layers so the label is crisp at any backing scale.
private final class ControlBadgeView: NSView {
    struct Metrics {
        let size: NSSize
        let padLeft: CGFloat
        let dot: CGFloat
        let textOffsetX: CGFloat
    }

    private static let padLeft: CGFloat = 9
    private static let padRight: CGFloat = 10
    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 6
    private static let height: CGFloat = 25

    let metrics: Metrics
    private let text: String
    private let font: NSFont
    private let dotLayer = CALayer()

    static func measure(text: String, font: NSFont) -> Metrics {
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        let width = ceil(padLeft + dotSize + dotGap + w + padRight)
        return Metrics(size: NSSize(width: width, height: height),
                       padLeft: padLeft, dot: dotSize,
                       textOffsetX: padLeft + dotSize + dotGap)
    }

    init(frame: NSRect, text: String, font: NSFont, metrics: Metrics) {
        self.text = text
        self.font = font
        self.metrics = metrics
        super.init(frame: frame)
        wantsLayer = true
        // Nearly opaque. This pill exists to be *read*, and the one string it
        // carries is the whole point of the announcement — at 0.80 the window
        // text behind it shows through and the sentence becomes work to parse
        // over a light background.
        layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = frame.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        dotLayer.frame = CGRect(x: metrics.padLeft,
                                y: (frame.height - metrics.dot) / 2,
                                width: metrics.dot, height: metrics.dot)
        dotLayer.cornerRadius = metrics.dot / 2
        dotLayer.backgroundColor = CursorOverlay.accentSoft.cgColor
        dotLayer.shadowColor = CursorOverlay.accentSoft.cgColor
        dotLayer.shadowOpacity = 0.9
        dotLayer.shadowRadius = 4
        dotLayer.shadowOffset = .zero
        layer?.addSublayer(dotLayer)

        // A breathing dot says "live" without needing a word for it.
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.55
        pulse.duration = 0.95
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(pulse, forKey: "pulse")

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.45
        breathe.duration = 0.95
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        dotLayer.add(breathe, forKey: "breathe")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: metrics.textOffsetX,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }

    func playEntrance() {
        guard let layer else { return }
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.20
        layer.add(fade, forKey: "badgeIn")

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.92
        pop.toValue = 1.0
        pop.damping = 14
        pop.stiffness = 240
        pop.mass = 1
        pop.duration = 0.42
        layer.add(pop, forKey: "badgePop")
    }

    func playExit(completion: @escaping () -> Void) {
        guard let layer else { return completion() }
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.40
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "badgeOut")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { completion() }
    }
}

// MARK: - Timing function shorthands

private extension CAMediaTimingFunction {
    static let easeIn = CAMediaTimingFunction(name: .easeIn)
    static let easeOut = CAMediaTimingFunction(name: .easeOut)
    static let easeInEaseOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let linear = CAMediaTimingFunction(name: .linear)
}
