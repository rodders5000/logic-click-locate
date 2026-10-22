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
import ScreenCaptureKit

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
/// own, floating at layer 3), an open menu (layer 101), a separate editor/mixer window or another app's panel on
/// top means no locate. CGWindowList lists windows front to back; the Dock's and Window Server's windows (the Dock
/// one covers the whole screen) and invisible windows are skipped.
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
        !["Dock", "Window Server"].contains(i[kCGWindowOwnerName as String] as? String ?? "")
            && ((i[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
            && frame(i)?.contains(p) == true
    }
    guard let main, let top, frame(top) == main, (top[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return nil }
    return main
}

/// Where did a tap land: track lanes, track headers/side panels, or a docked editor/mixer?
///
/// Docked editor or mixer between the top of the Tracks area and the tap: Logic draws an unbroken black line
/// above a docked editor/mixer from the left of the track headers to the window's right edge. Region borders are
/// also black but are broken by the bar grid and stop at the scroll bar, so they never reach the window edge
/// (checked 2026-10-22 with and without Library/Inspector open). Reads screen pixels (ScreenCaptureKit, needs
/// Screen Recording) — never accessibility. Thin columns are captured at full resolution (the line is 1 pt): one
/// at the window's right edge plus six across the right half of the window (the left side may be Library/Inspector);
/// a row black in all of them is the divider.
///
/// Track headers: at the ruler's height the track-header column is one flat mid-grey block (about 63; reads ~10
/// brighter through ScreenCaptureKit) ending exactly where the lanes and ruler (45 or darker) start. The Library and
/// Inspector, when open, sit further left. So the lanes start where the rightmost flat-grey run left of the tap ends;
/// no such run, or the tap on/inside it, means the tap is on a track header or a side panel (checked 2026-10-22 on
/// both layouts: runs end at 564 and 1139, the real lane edges).
enum TapPlace { case lanes, headers, editor }

/// done(place), or nil if the screen capture failed (e.g. no Screen Recording permission).
func classifyTap(_ d: CGPoint, in area: CGRect, window w: CGRect, rulerY: CGFloat, done: @escaping (TapPlace?) -> Void) {
    Task {
        do {
            let place = try await tapPlace(d, in: area, window: w, rulerY: rulerY)
            DispatchQueue.main.async { done(place) }
        } catch {
            dlog("tap \(pt(d)) screen check: capture error \(error)")
            DispatchQueue.main.async { done(nil) }
        }
    }
}

func tapPlace(_ d: CGPoint, in area: CGRect, window w: CGRect, rulerY: CGFloat) async throws -> TapPlace {
    // Track headers / side panels: find the lanes' left edge on the ruler row.
    let row = try await SCScreenshotManager.captureImage(in: CGRect(x: w.minX, y: rulerY, width: d.x - w.minX, height: 2))
    let scale = CGFloat(row.width) / (d.x - w.minX)
    let (px, rw, rh) = rgbaPixels(row)
    var lanesLeft: CGFloat? = nil
    var runStart: Int? = nil
    let y = rh / 2
    for x in 0...rw {
        var g = false
        if x < rw {
            let o = (y * rw + x) * 4
            let r = px[o], gg = px[o + 1], b = px[o + 2]
            g = max(r, gg, b) - min(r, gg, b) <= 4 && (60...85).contains(r)
        }
        if g, runStart == nil { runStart = x }
        if !g, let s = runStart {
            // the ruler's own greys stay under ~13 pt per stretch; the header column is ~330 pt wide
            if CGFloat(x - s) >= 40 * scale { lanesLeft = w.minX + CGFloat(x) / scale }
            runStart = nil
        }
    }
    // tap straight below the header grey (however short the stretch so far) = on a header
    let last = (y * rw + rw - 1) * 4
    let tapOnGrey = max(px[last], px[last + 1], px[last + 2]) - min(px[last], px[last + 1], px[last + 2]) <= 4
        && (60...85).contains(px[last])
    guard !tapOnGrey, let left = lanesLeft, d.x >= left + 3 else {
        dlog("tap \(pt(d)) -> on track headers/side panel (lanes start at \(lanesLeft.map { "\(Int($0))" } ?? "?"))")
        return .headers
    }

    // Docked editor/mixer: a black row in every column between the Tracks-area top and the tap.
    let height = d.y - area.minY
    guard height >= 2 else { return .lanes }
    let edge = CGRect(x: w.maxX - 3, y: area.minY, width: 2, height: height)
    let columns = [edge] + (0..<6).map { i in CGRect(x: w.midX + (w.width / 2 - 40) * CGFloat(i) / 5, y: area.minY, width: 2, height: height) }
    var blackRows: Set<Int>? = nil
    for rect in columns {
        let rows = blackRowIndices(try await SCScreenshotManager.captureImage(in: rect))
        blackRows = blackRows.map { $0.intersection(rows) } ?? rows
        if blackRows!.isEmpty { break }
    }
    return (blackRows ?? []).isEmpty ? .lanes : .editor
}

/// The image's pixels as RGBA bytes, with its width and height.
func rgbaPixels(_ img: CGImage) -> ([UInt8], Int, Int) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    if let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (buf, w, h)
}

/// Rows of the image whose middle pixel is black (or nearly).
func blackRowIndices(_ img: CGImage) -> Set<Int> {
    let (buf, w, h) = rgbaPixels(img)
    var rows = Set<Int>()
    for r in 0..<h {
        let o = (r * w + w / 2) * 4
        if max(buf[o], buf[o + 1], buf[o + 2]) <= 12 { rows.insert(r) }
    }
    return rows
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

    private var warnedNoCapture = false

    /// Wait out the double-click interval first: locating between the two clicks of a double-click would
    /// put our ruler click in the middle and Logic would never see the double-click (e.g. opening a region).
    private func scheduleLocate(at d: CGPoint, back: CGPoint, window w: CGRect) {
        let presses = pressCount
        let wait = max(0.05, min(layout.locateDelay, NSEvent.doubleClickInterval))
        let l = layout
        let area = CGRect(x: w.minX + l.tracksLeftFromWindowLeft, y: w.minY + l.tracksTopFromWindowTop,
                          width: w.width - l.tracksLeftFromWindowLeft - l.tracksRightMargin,
                          height: w.height - l.tracksTopFromWindowTop - l.tracksBottomMargin)
        guard area.contains(d) else { dlog("tap \(pt(d)) -> skipped (outside Tracks area \(Int(area.minX)),\(Int(area.minY)) \(Int(area.width))x\(Int(area.height)))"); return }

        // The screen check (track headers, docked editor) runs during the double-click wait; locate once both are done.
        var waited = false
        var checked: TapPlace?? = .none // .none = capture still running
        func finish() {
            guard waited, let place = checked else { return }
            guard self.pressCount == presses else { dlog("tap \(pt(d)) -> cancelled (another click followed)"); return }
            // Moving the mouse during the wait is normal; only a button that is down again stops us.
            guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
                  let now = CGEvent(source: nil)?.location else {
                dlog("tap \(pt(d)) -> skipped (button pressed again)"); return }
            guard self.logicPID() != nil else { dlog("tap \(pt(d)) -> skipped (Logic not frontmost)"); return }
            if place == .editor { dlog("tap \(pt(d)) -> skipped (in the docked editor/mixer)"); return }
            if place == .headers { dlog("tap \(pt(d)) -> skipped (track headers/side panel)"); return }
            if place == nil, !warnedNoCapture {
                warnedNoCapture = true
                dlog("screen capture failed (Screen Recording not allowed?) -> taps on track headers and in a docked editor will locate too")
            }
            self.clickRuler(x: d.x, y: w.minY + l.rulerYFromWindowTop, back: now) // cursor goes back to where it is now
        }
        classifyTap(d, in: area, window: w, rulerY: w.minY + l.rulerYFromWindowTop) { checked = .some($0); finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { waited = true; finish() }
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
        // Screen Recording: to see where a docked editor/mixer starts (screen pixels, not Logic's interface).
        // Without it everything still works, but taps in a docked editor also locate.
        let canCapture = CGPreflightScreenCaptureAccess()
        dlog("Screen Recording \(canCapture ? "allowed" : "NOT allowed (asking)")")
        if !canCapture { CGRequestScreenCaptureAccess() }
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
