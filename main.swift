import Cocoa
import ApplicationServices
import IOKit.hid
import Carbon.HIToolbox

// MARK: - Key name helpers

let specialKeys: [UInt16: String] = [
    36: "↩",    // return
    48: "⇥",    // tab
    49: "␣",    // space
    51: "⌫",    // delete
    53: "⎋",    // escape
    76: "⌤",    // keypad enter
    115: "↖",   // home
    116: "⇞",   // page up
    117: "⌦",   // forward delete
    119: "↘",   // end
    121: "⇟",   // page down
    123: "←",
    124: "→",
    125: "↓",
    126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
]

func displayString(for event: NSEvent) -> String {
    let flags = event.modifierFlags
    var mods = ""
    if flags.contains(.control) { mods += "⌃" }
    if flags.contains(.option)  { mods += "⌥" }
    if flags.contains(.shift)   { mods += "⇧" }
    if flags.contains(.command) { mods += "⌘" }

    if let special = specialKeys[event.keyCode] {
        return mods + special
    }

    let hasCombo = flags.contains(.control) || flags.contains(.option) || flags.contains(.command)
    if hasCombo {
        let base = (event.charactersIgnoringModifiers ?? "?").uppercased()
        return mods + base
    }
    // Plain typing (shift included): show the character as it was typed.
    return event.characters ?? ""
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var background: NSView!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var trustPollTimer: Timer?
    var sweepTimer: Timer?
    var eventTap: CFMachPort?
    var paused = false
    var secureWarned = false

    // Each line is one burst of typing; a pause in typing starts a new line.
    struct Line {
        let field: NSTextField
        var entries: [(text: String, count: Int)]
        var lastUpdate: Date
        var sticky: Bool   // status messages that should not fade (e.g. waiting for permission)
    }
    var lines: [Line] = []

    let lineBreakAfter: TimeInterval = 1.0   // typing pause that starts a new line
    let lineFadeAfter: TimeInterval = 4.0    // line age before it starts fading
    let lineFadeDuration: TimeInterval = 1.5 // how long the fade-out takes
    let maxLines = 5

    var corner: Int {
        get { UserDefaults.standard.integer(forKey: "corner") } // 0 BR, 1 BL, 2 TR, 3 TL
        set { UserDefaults.standard.set(newValue, forKey: "corner"); positionWindow() }
    }
    var fontSize: CGFloat {
        get { let s = UserDefaults.standard.double(forKey: "fontSize"); return s > 0 ? s : 30 }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize"); applyFont(); layout() }
    }
    // -1 = follow the screen with the mouse pointer; >= 0 = pinned display index
    var displayMode: Int {
        get {
            UserDefaults.standard.object(forKey: "displayMode") == nil
                ? -1 : UserDefaults.standard.integer(forKey: "displayMode")
        }
        set { UserDefaults.standard.set(newValue, forKey: "displayMode"); positionWindow() }
    }

    var font: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold) }

    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if displayMode >= 0 && displayMode < screens.count {
            return screens[displayMode]
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens[0]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkSecureInput()
        }
        ensurePermissionsThenMonitor()
    }

    // MARK: Window

    func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 12

        window.contentView = background
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    func applyFont() {
        for line in lines { line.field.font = font }
    }

    // MARK: Lines

    @discardableResult
    func addLine(text: String, sticky: Bool = false) -> Int {
        let field = NSTextField(labelWithString: text)
        field.textColor = .white
        field.font = font
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        background.addSubview(field)
        lines.append(Line(field: field, entries: [(text, 1)], lastUpdate: Date(), sticky: sticky))
        while lines.count > maxLines {
            lines.removeFirst().field.removeFromSuperview()
        }
        return lines.count - 1
    }

    func clearLines() {
        for line in lines { line.field.removeFromSuperview() }
        lines.removeAll()
        window.alphaValue = 0
    }

    // Status chip (permission messages etc.) — replaces everything on screen.
    func show(text: String, fade: Bool = true) {
        clearLines()
        addLine(text: text, sticky: !fade)
        layout()
    }

    func handle(_ event: NSEvent) {
        // Global pause/resume hotkey ⌃⌥⌘P — the tap stays enabled while paused
        // so this works from anywhere, in either state.
        if event.keyCode == 35,
           event.modifierFlags.contains(.control),
           event.modifierFlags.contains(.option),
           event.modifierFlags.contains(.command) {
            togglePause()
            return
        }
        guard !paused else { return }
        let text = displayString(for: event)
        guard !text.isEmpty else { return }
        let now = Date()

        let continueCurrent = !lines.isEmpty && !lines[lines.count - 1].sticky
            && now.timeIntervalSince(lines[lines.count - 1].lastUpdate) <= lineBreakAfter
        if !continueCurrent {
            // Drop any sticky status chip, then start a fresh line.
            if let last = lines.last, last.sticky {
                lines.removeLast().field.removeFromSuperview()
            }
            addLine(text: "")
            lines[lines.count - 1].entries = []
        }

        let i = lines.count - 1
        if event.isARepeat || lines[i].entries.last?.text == text {
            // Collapse held/auto-repeated keys and repeated combos into "×n"
            if lines[i].entries.last?.text == text {
                lines[i].entries[lines[i].entries.count - 1].count += 1
            } else {
                lines[i].entries.append((text, 1))
            }
        } else {
            lines[i].entries.append((text, 1))
        }
        lines[i].lastUpdate = now
        lines[i].field.alphaValue = 1

        renderLine(i)
        layout()
    }

    func renderLine(_ i: Int) {
        // Long bursts wrap onto extra rows (see layout); just cap runaway bursts.
        while lines[i].entries.count > 120 { lines[i].entries.removeFirst() }
        let parts = lines[i].entries.map { $0.count > 1 ? "\($0.text)×\($0.count)" : $0.text }
        lines[i].field.stringValue = parts.joined(separator: "\u{2009}")
    }

    // Called 10×/second: fades out lines that have gone quiet, oldest first.
    func sweep() {
        let now = Date()
        var changed = false
        for i in lines.indices.reversed() {
            if lines[i].sticky { continue }
            let age = now.timeIntervalSince(lines[i].lastUpdate)
            guard age > lineFadeAfter else { continue }
            let t = (age - lineFadeAfter) / lineFadeDuration
            if t >= 1 {
                lines[i].field.removeFromSuperview()
                lines.remove(at: i)
                changed = true
            } else {
                lines[i].field.alphaValue = 1 - t
            }
        }
        if changed { layout() }
    }

    func layout() {
        guard !lines.isEmpty else { window.alphaValue = 0; return }
        let padH: CGFloat = 18, padV: CGFloat = 10, spacing: CGFloat = 6
        let maxWidth = (targetScreen()?.visibleFrame.width ?? 1440) * 0.45
        var maxW: CGFloat = 0, totalH: CGFloat = 0
        for line in lines {
            let size = line.field.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
            line.field.frame.size = NSSize(width: min(size.width, maxWidth), height: size.height)
            maxW = max(maxW, line.field.frame.width)
            totalH += line.field.frame.height
        }
        totalH += spacing * CGFloat(lines.count - 1)
        let w = maxW + padH * 2
        let h = totalH + padV * 2

        // Oldest line at the top, newest at the bottom.
        var y = h - padV
        for line in lines {
            y -= line.field.frame.height
            line.field.frame.origin = NSPoint(x: padH, y: y)
            y -= spacing
        }
        window.setContentSize(NSSize(width: w, height: h))
        positionWindow()
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    func positionWindow() {
        guard let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 24
        var origin = NSPoint.zero
        switch corner {
        case 1: origin = NSPoint(x: vf.minX + margin, y: vf.minY + margin)                       // bottom-left
        case 2: origin = NSPoint(x: vf.maxX - size.width - margin, y: vf.maxY - size.height - margin) // top-right
        case 3: origin = NSPoint(x: vf.minX + margin, y: vf.maxY - size.height - margin)         // top-left
        default: origin = NSPoint(x: vf.maxX - size.width - margin, y: vf.minY + margin)         // bottom-right
        }
        window.setFrameOrigin(origin)
    }

    // MARK: Status bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"

        let menu = NSMenu()

        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.control, .option, .command]
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let cornerMenu = NSMenu()
        let names = ["Bottom Right", "Bottom Left", "Top Right", "Top Left"]
        for (i, name) in names.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(setCorner(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            cornerMenu.addItem(item)
        }
        let cornerItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        menu.setSubmenu(cornerMenu, for: cornerItem)
        menu.addItem(cornerItem)

        let displayMenu = NSMenu()
        let followItem = NSMenuItem(title: "Follow Mouse", action: #selector(setDisplay(_:)), keyEquivalent: "")
        followItem.tag = -1
        followItem.target = self
        displayMenu.addItem(followItem)
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: "Pin to \(name)", action: #selector(setDisplay(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        menu.setSubmenu(displayMenu, for: displayItem)
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem(title: "Bigger Text", action: #selector(biggerText), keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "Smaller Text", action: #selector(smallerText), keyEquivalent: "-"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit KeyDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = item.target ?? self }
        menu.items.last?.target = NSApp
        statusItem.menu = menu
    }

    @objc func setCorner(_ sender: NSMenuItem) { corner = sender.tag }
    @objc func setDisplay(_ sender: NSMenuItem) { displayMode = sender.tag }
    @objc func biggerText() { fontSize = min(fontSize + 4, 72) }
    @objc func smallerText() { fontSize = max(fontSize - 4, 14) }

    @objc func togglePause() {
        paused.toggle()
        pauseItem.state = paused ? .on : .off
        pauseItem.title = paused ? "Resume" : "Pause"
        statusItem.button?.appearsDisabled = paused
        show(text: paused ? "⏸ paused — ⌃⌥⌘P to resume" : "▶ resumed")
        secureWarned = false  // re-check (and re-show the warning if needed) on resume
    }

    // Secure Keyboard Entry (e.g. Terminal's) blocks key capture system-wide and
    // silently — surface it on the overlay instead of just going dark.
    func checkSecureInput() {
        guard eventTap != nil, !paused else { return }
        let blocked = IsSecureEventInputEnabled()
        if blocked && !secureWarned {
            secureWarned = true
            show(text: "⚠︎ Key capture blocked by Secure Keyboard Entry — quit Terminal", fade: false)
        } else if !blocked && secureWarned {
            secureWarned = false
            show(text: "KeyDisplay ✓")
        }
    }

    // MARK: Accessibility / Input Monitoring permission + event tap

    func ensurePermissionsThenMonitor() {
        // Global key capture on modern macOS needs Input Monitoring (and/or Accessibility).
        // Request both up front, then keep retrying the event tap until it succeeds.
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOpts)
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        if startTap() {
            show(text: "KeyDisplay ✓")
            return
        }
        show(text: "⌨ waiting for Input Monitoring permission…", fade: false)
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.startTap() {
                t.invalidate()
                self.show(text: "KeyDisplay ✓ — start typing")
            }
        }
    }

    @discardableResult
    func startTap() -> Bool {
        if eventTap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .keyDown, let ev = NSEvent(cgEvent: cgEvent) {
                DispatchQueue.main.async { me.handle(ev) }
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // macOS disables slow taps; ours is listen-only, just re-enable.
                // (Stays enabled while paused too, so the ⌃⌥⌘P hotkey can resume.)
                if let tap = me.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
