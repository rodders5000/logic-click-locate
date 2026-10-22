// Logic Click Locate — a quick plain tap in Logic Pro's Tracks area moves the playhead there.
//
// Logic 12.4 broke Shift-click-to-locate in the Tracks area; clicking the ruler still works. This helper
// polls the left mouse button; after a quick, still, unmodified single tap inside the Tracks area it clicks the
// ruler at the same x and puts the cursor back.
//
// It NEVER talks to Logic through accessibility: any accessibility query to Logic 12.4 breaks drag-select and
// region dragging until Logic restarts (proven 2026-10-21). So it cannot tell empty lanes from regions — a quick
// tap on a region also locates — and it finds the ruler and Tracks area from Logic's window frame
// (CGWindowList, no accessibility) plus offsets in layout.json.

import Cocoa

let logicBundleID = "com.apple.logic10"
let dragSlop: CGFloat = 4

// Diagnostic log (~/Library/Logs/LogicClickLocate.log): every click the helper sees and every action it takes.
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LogicClickLocate.log")
let logFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func dlog(_ msg: String) {
    let line = "\(logFormatter.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
func pt(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }

// MARK: - Layout (window-relative offsets, editable in layout.json)

struct Layout: Codable {
    /// y of the ruler's lower (locate) half, from the top of Logic's main window
    var rulerYFromWindowTop: CGFloat = 154
    /// the Tracks area (where taps count): left edge from window left, top from window top,
    /// and margins kept clear at the right (scroll bar) and bottom
    var tracksLeftFromWindowLeft: CGFloat = 566
    var tracksTopFromWindowTop: CGFloat = 166
    var tracksRightMargin: CGFloat = 20
    var tracksBottomMargin: CGFloat = 20
    /// how long to wait for a possible second click before locating (a second click cancels). Shorter feels
    /// snappier; a double-click on a region slower than this won't reach Logic as a double-click.
    var locateDelay: Double = 0.25
}

let layoutURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LogicClickLocate/layout.json")

/// Logic's main window frame, but only if it is the frontmost window under the point — a plugin window (Logic's
/// own, floating at layer 3), a separate editor/mixer window or another app's panel on top means no locate.
/// CGWindowList lists windows front to back; system layers (Dock 20, menu bar 24+, overlays) and invisible
/// windows are skipped because the Dock's window covers the whole screen.
func logicMainWindowFrame(topmostAt p: CGPoint, pid: pid_t) -> CGRect? {
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    func frame(_ i: [String: Any]) -> CGRect? {
        guard let b = i[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }
    func layer(_ i: [String: Any]) -> Int { (i[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 }
    let main = infos.filter { (i: [String: Any]) in (i[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && layer(i) == 0 }
        .compactMap(frame).filter { $0.contains(p) }.max { $0.width * $0.height < $1.width * $1.height }
    let top = infos.first { i in
        layer(i) < Int(CGWindowLevelForKey(.dockWindow)) && ((i[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
            && frame(i)?.contains(p) == true
    }
    guard let main, let top, frame(top) == main, (top[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
    return main
}

// MARK: - Click handling

final class ClickLocator {
    var enabled = true
    var layout = Layout()
    private let maxClickDuration: TimeInterval = 0.2 // anything held longer than a quick tap never locates
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    func loadLayout() {
        if let d = try? Data(contentsOf: layoutURL), let l = try? JSONDecoder().decode(Layout.self, from: d) { layout = l; return }
        try? FileManager.default.createDirectory(at: layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(layout).write(to: layoutURL)
    }

    private func logicPID() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == logicBundleID else { return nil }
        return front.processIdentifier
    }

    // MARK: Button polling (no event tap)
    private var wasDown = false
    private var downAt = CGPoint.zero
    private var downTime = Date.distantPast
    private var maxMove: CGFloat = 0
    private var trackingClick = false
    private var pressWindow: CGRect?    // Logic's main window frame if it was topmost under the press
    private var pressCount = 0          // bumps on every real press; a pending locate is cancelled if it changes
    private var ignoreUntil = Date.distantPast // our own ruler click shows up in the button state too

    func poll() {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        guard let loc = CGEvent(source: nil)?.location else { return }
        if Date() < ignoreUntil { wasDown = down; return }
        if down && !wasDown {
            pressCount += 1
            let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            // Which window is on top is checked at the press: clicking a plugin window's close button would
            // otherwise leave the main window on top by the time the locate runs.
            pressWindow = nil
            if enabled, let pid = logicPID(), CGEventSource.flagsState(.combinedSessionState).intersection(mods).isEmpty {
                pressWindow = logicMainWindowFrame(topmostAt: loc, pid: pid)
                if pressWindow == nil { dlog("press \(pt(loc)) -> ignored (not on Logic's main window: plugin/other window on top)") }
            }
            trackingClick = pressWindow != nil
            downAt = loc; maxMove = 0; downTime = Date()
        } else if down && trackingClick {
            maxMove = max(maxMove, hypot(loc.x - downAt.x, loc.y - downAt.y))
        } else if !down && wasDown {
            let held = Date().timeIntervalSince(downTime)
            if trackingClick {
                maxMove = max(maxMove, hypot(loc.x - downAt.x, loc.y - downAt.y))
                if held < maxClickDuration && maxMove <= dragSlop {
                    scheduleLocate(at: downAt, back: loc, window: pressWindow!)
                } else {
                    dlog("press \(pt(downAt)) \(Int(held * 1000)) ms, moved \(Int(maxMove)) px -> ignored (hold/drag)")
                }
            }
            trackingClick = false
        }
        wasDown = down
    }

    /// Wait out the double-click interval first: locating between the two clicks of a double-click would
    /// put our ruler click in the middle and Logic would never see the double-click (e.g. opening a region).
    private func scheduleLocate(at d: CGPoint, back: CGPoint, window w: CGRect) {
        let presses = pressCount
        let wait = max(0.05, min(layout.locateDelay, NSEvent.doubleClickInterval))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard self.pressCount == presses else { dlog("tap \(pt(d)) -> cancelled (another click followed)"); return }
            // Moving the mouse during the wait is normal; only a button that is down again stops us.
            guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  let now = CGEvent(source: nil)?.location else {
                dlog("tap \(pt(d)) -> skipped (button pressed again)"); return }
            guard self.logicPID() != nil else { dlog("tap \(pt(d)) -> skipped (Logic not frontmost)"); return }
            let l = self.layout
            let area = CGRect(x: w.minX + l.tracksLeftFromWindowLeft, y: w.minY + l.tracksTopFromWindowTop,
                              width: w.width - l.tracksLeftFromWindowLeft - l.tracksRightMargin,
                              height: w.height - l.tracksTopFromWindowTop - l.tracksBottomMargin)
            guard area.contains(d) else { dlog("tap \(pt(d)) -> skipped (outside Tracks area \(Int(area.minX)),\(Int(area.minY)) \(Int(area.width))x\(Int(area.height)))"); return }
            self.clickRuler(x: d.x, y: w.minY + l.rulerYFromWindowTop, back: now) // cursor goes back to where it is now
        }
    }

    private var restorePoint: CGPoint?

    private func clickRuler(x: CGFloat, y: CGFloat, back: CGPoint) {
        let target = CGPoint(x: x, y: y)
        dlog("tap -> ruler click at \(pt(target))")
        restorePoint = back
        ignoreUntil = Date().addingTimeInterval(0.3)
        post(.leftMouseDown, at: target)
        post(.leftMouseUp, at: target)
        waitForCursor(at: target, deadline: Date().addingTimeInterval(0.1))
    }

    /// Warp back once the posted click has actually moved the cursor to the ruler.
    private func waitForCursor(at target: CGPoint, deadline: Date) {
        let now = CGEvent(source: nil)?.location ?? target
        if hypot(now.x - target.x, now.y - target.y) < 2 || Date() > deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                guard let back = self.restorePoint else { return }
                self.restorePoint = nil
                CGWarpMouseCursorPosition(back)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { self.waitForCursor(at: target, deadline: deadline) }
        }
    }

    private func post(_ type: CGEventType, at p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.flags = []
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let locator = ClickLocator()
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Click to Locate: On", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Logic Click Locate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refreshIcon()

        // Posting the ruler click needs this app's own Accessibility permission (macOS's rule for sending
        // events). That is a local check only: nothing here ever queries Logic through accessibility.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        locator.loadLayout()
        startPolling()
    }

    /// Polls the left button 100 times a second (see ClickLocator.poll for why there is no event tap).
    func startPolling() {
        let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.locator.poll() }
        RunLoop.main.add(t, forMode: .common)
        dlog("started (polling, no event tap)")
    }

    @objc func toggle() {
        locator.enabled.toggle()
        refreshIcon()
    }

    func refreshIcon() {
        toggleItem.title = "Click to Locate: \(locator.enabled ? "On" : "Off")"
        let name = locator.enabled ? "playhead.fill" : "playhead"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Logic Click Locate")
            ?? NSImage(systemSymbolName: "arrowtriangle.down.fill", accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !locator.enabled
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
