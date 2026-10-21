// Logic Click Locate — a plain left-click on an empty track lane in Logic Pro moves the playhead there.
//
// Logic 12.4 broke Shift-click-to-locate in the Tracks area; clicking the ruler still works. This helper
// watches left-clicks while Logic is frontmost. If a click (no modifiers, no drag) lands on an empty
// track lane — Logic's accessibility tree reports an AXLayoutArea whose help text starts with
// "Workspace" (regions are AXLayoutItem children, so they never match) — it posts a click on the lower
// half of the Tracks ruler at the same x, then puts the cursor back.

import Cocoa
import ApplicationServices

let logicBundleID = "com.apple.logic10"
let syntheticTag: Int64 = 0x4C434C4F // "LCLO": marks our own events so the tap ignores them
let dragSlop: CGFloat = 4

// MARK: - Accessibility helpers

func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func axString(_ e: AXUIElement, _ a: String) -> String { axAttr(e, a) as? String ?? "" }

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func axParent(_ e: AXUIElement) -> AXUIElement? {
    guard let p = axAttr(e, kAXParentAttribute) else { return nil }
    return (p as! AXUIElement)
}

/// The element of Logic under a screen point (top-left origin coordinates).
func logicElement(at p: CGPoint, pid: pid_t) -> AXUIElement? {
    var el: AXUIElement?
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success else { return nil }
    return el
}

/// Empty track lane = the lane itself (or the empty area below the last track), not a region inside it.
func isEmptyLane(_ e: AXUIElement) -> Bool {
    axString(e, kAXRoleAttribute) == "AXLayoutArea" && axString(e, kAXHelpAttribute).hasPrefix("Workspace")
}

func window(of e: AXUIElement) -> AXUIElement? {
    var cur: AXUIElement? = e
    while let c = cur {
        if axString(c, kAXRoleAttribute) == kAXWindowRole { return c }
        cur = axParent(c)
    }
    return nil
}

/// Breadth-first search for the Tracks time ruler inside a window.
func findRuler(in win: AXUIElement) -> AXUIElement? {
    var queue: [AXUIElement] = [win]
    var visited = 0
    while !queue.isEmpty && visited < 4000 {
        let e = queue.removeFirst()
        visited += 1
        if axString(e, kAXRoleAttribute) == "AXLayoutArea" && axString(e, kAXDescriptionAttribute) == "Tracks time ruler" {
            return e
        }
        // Don't descend into lanes, regions or the mixer: the ruler sits beside them, not inside.
        if axString(e, kAXDescriptionAttribute) == "Mixer" || isEmptyLane(e) { continue }
        if let kids = axAttr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
    }
    return nil
}

// MARK: - Click handling

final class ClickLocator {
    var enabled = true
    private var pendingDown: CGPoint?
    private var pendingWindow: AXUIElement?
    private var rulerCache: [CFHashCode: AXUIElement] = [:]
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0 // don't swallow the user's real mouse movement after our events
        return s
    }()

    private func logicPID() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == logicBundleID else { return nil }
        return front.processIdentifier
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == syntheticTag {
            if type == .leftMouseUp { DispatchQueue.main.async { self.restoreCursor() } }
            return
        }
        guard enabled else { return }
        switch type {
        case .leftMouseDown:
            pendingDown = nil
            let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            guard event.flags.intersection(mods).isEmpty,
                  event.getIntegerValueField(.mouseEventClickState) == 1,
                  let pid = logicPID(),
                  let el = logicElement(at: event.location, pid: pid),
                  isEmptyLane(el) else { return }
            pendingDown = event.location
            pendingWindow = window(of: el)
        case .leftMouseDragged:
            if let d = pendingDown, hypot(event.location.x - d.x, event.location.y - d.y) > dragSlop { pendingDown = nil }
        case .leftMouseUp:
            guard let d = pendingDown, let win = pendingWindow else { return }
            pendingDown = nil
            let back = event.location
            // Let Logic finish handling the real click first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.locate(x: d.x, window: win, restoreTo: back) }
        default:
            break
        }
    }

    private func ruler(for win: AXUIElement) -> AXUIElement? {
        let key = CFHash(win)
        if let r = rulerCache[key], axFrame(r) != nil { return r }
        let r = findRuler(in: win)
        rulerCache[key] = r
        return r
    }

    private func locate(x: CGFloat, window win: AXUIElement, restoreTo back: CGPoint) {
        guard let r = ruler(for: win), let f = axFrame(r), x >= f.minX, x <= f.maxX else { return }
        // Lower part of the ruler = locate; the top strip is the cycle area.
        let target = CGPoint(x: x, y: f.minY + f.height * 0.78)
        // Logic ignores clicks posted straight to its pid, so this goes through the HID stream, which moves the
        // cursor. Warp it back; re-associating mouse and cursor straight after cancels the ~0.25 s freeze a warp causes.
        // The warp waits until our mouse-up has come back through the tap: warping straight after posting
        // sometimes ran before the posted click moved the cursor, leaving it on the ruler.
        restorePoint = back
        post(.leftMouseDown, at: target)
        post(.leftMouseUp, at: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.restoreCursor() } // fallback
    }

    private var restorePoint: CGPoint?

    func restoreCursor() {
        guard let back = restorePoint else { return }
        restorePoint = nil
        CGWarpMouseCursorPosition(back)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func post(_ type: CGEventType, at p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let locator = ClickLocator()
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
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

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            // macOS shows its own prompt; keep retrying until Accessibility is granted.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                if AXIsProcessTrusted() { t.invalidate(); self.startTap() }
            }
        } else {
            startTap()
        }
    }

    func startTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                me.locator.handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { NSLog("LogicClickLocate: could not create event tap"); return }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
