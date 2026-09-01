// RemoteIMESync — keep local & remote input sources in sync while using a
// remote desktop app (Jump Desktop etc.).
//
// Principle: one keypress, one event, two effects.
// The user's own input-source toggle shortcut passes through untouched, so the
// remote desktop app forwards it to the host and the host's system shortcut
// toggles the host side. This tool only observes that same event (from an
// event tap inserted ahead of the remote app's) and toggles the LOCAL input
// source via the TIS API. Trigger+Shift is the "realign" key: shift is
// stripped from the event so only the host toggles.

import AppKit
import Carbon
import IOKit.hid

// MARK: - Config

struct Config: Codable {
    var bundlePrefixes: [String]?   // remote desktop apps; default ["com.p5sys.jump"]
    var triggerKeyCode: Int?        // override; default: auto-detect from system shortcut
    var triggerModifiers: [String]? // "command" | "shift" | "control" | "option"
    var anyApp: Bool?               // test mode: ignore frontmost-app check
    var hostKeyCode: Int?           // key to send onward when the host's toggle
    var hostModifiers: [String]?    // shortcut differs from the trigger
    var sendStepMs: Int?            // gap between the synthesized events

    static func load() -> Config {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/remote-ime-sync/config.json")
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            fputs("error: failed to parse \(url.path): \(error)\n", stderr)
            exit(1)
        }
    }
}

func modifierFlags(_ names: [String]) -> CGEventFlags {
    var f = CGEventFlags()
    for n in names {
        switch n {
        case "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "control": f.insert(.maskControl)
        case "option": f.insert(.maskAlternate)
        default:
            fputs("error: unknown modifier '\(n)' in config\n", stderr)
            exit(1)
        }
    }
    return f
}

// MARK: - System input-source-toggle shortcut auto-detection

// Reads symbolic hotkey 60 ("Select the previous input source").
// parameters = [unichar, keyCode, modifierMask(NSEvent-style bits)]
func detectSystemToggleShortcut() -> (keyCode: Int, flags: CGEventFlags)? {
    guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                              "com.apple.symbolichotkeys" as CFString)
            as? [String: Any],
          let hk = all["60"] as? [String: Any],
          (hk["enabled"] as? Bool ?? false),
          let value = hk["value"] as? [String: Any],
          let params = value["parameters"] as? [Int], params.count >= 3
    else { return nil }
    var flags = CGEventFlags()
    let mask = params[2]
    if mask & 0x20000 != 0 { flags.insert(.maskShift) }
    if mask & 0x40000 != 0 { flags.insert(.maskControl) }
    if mask & 0x80000 != 0 { flags.insert(.maskAlternate) }
    if mask & 0x100000 != 0 { flags.insert(.maskCommand) }
    return (params[1], flags)
}

// MARK: - Local input source toggling (TIS)

func tisProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
}

func sourceID(_ source: TISInputSource) -> String {
    tisProperty(source, kTISPropertyInputSourceID) as? String ?? ""
}

// Enabled, user-selectable keyboard sources, split into the latin keyboard
// layout (ABC etc.) and the first IME input mode (Korean 2-Set, Hiragana, ...).
func toggleTargets() -> (latin: TISInputSource, ime: TISInputSource)? {
    guard let list = TISCreateInputSourceList(nil, false).takeRetainedValue()
            as? [TISInputSource] else { return nil }
    let selectable = list.filter {
        (tisProperty($0, kTISPropertyInputSourceCategory) as? String)
            == (kTISCategoryKeyboardInputSource as String)
        && (tisProperty($0, kTISPropertyInputSourceIsSelectCapable) as? Bool ?? false)
        && (tisProperty($0, kTISPropertyInputSourceIsEnabled) as? Bool ?? false)
    }
    let latin = selectable.first {
        (tisProperty($0, kTISPropertyInputSourceType) as? String)
            == (kTISTypeKeyboardLayout as String)
    }
    let ime = selectable.first {
        (tisProperty($0, kTISPropertyInputSourceType) as? String)
            == (kTISTypeKeyboardInputMode as String)
    }
    guard let l = latin, let i = ime else { return nil }
    return (l, i)
}

func isCJKV(_ source: TISInputSource) -> Bool {
    guard let lang = (tisProperty(source, kTISPropertyInputSourceLanguages)
                        as? [String])?.first else { return false }
    return lang == "ko" || lang == "ja" || lang == "vi" || lang.hasPrefix("zh")
}

// macOS bug: selecting a CJK input *mode* while an app holds key focus only
// half-applies — the menu bar changes but the focused app keeps the old
// source until key focus moves. Same workaround as macism: steal key focus
// with a tiny window for ~150ms, then hand it back to the previous app.
func focusBlip() {
    let previous = NSWorkspace.shared.frontmostApplication
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 3, height: 3),
                     styleMask: [.titled], // plain windows can't become key
                     backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = .screenSaver
    w.collectionBehavior = [.canJoinAllSpaces, .stationary]
    if let screen = NSScreen.main {
        w.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 11,
                                 y: screen.visibleFrame.minY + 8))
    }
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // 150ms (macism default) proved too short for Jump Desktop's viewer; 500ms works.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        w.close()
        previous?.activate(options: [])
    }
}

func toggleLocalInputSource() {
    guard let targets = toggleTargets() else {
        NSLog("no latin+IME source pair found; nothing to toggle")
        return
    }
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let target = sourceID(current) == sourceID(targets.latin) ? targets.ime : targets.latin
    TISSelectInputSource(target)
    NSLog("local -> %@", sourceID(target))
    if isCJKV(target) {
        // Delay so the trigger's key-up still reaches the remote app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusBlip() }
    }
}

// MARK: - Event tap

final class Tap {
    let trigger: (keyCode: Int, flags: CGEventFlags)
    // What the host actually listens for. nil = same as the trigger, i.e. the
    // event passes through untouched (original single-shortcut design).
    let hostKey: (keyCode: Int, flags: CGEventFlags)?
    // The remote side needs the modifier presses to land before the key, and a
    // burst posted back-to-back loses roughly one in four (measured over Jump,
    // 2026-09-01). Stagger them; tune if a slower link still drops one.
    let sendStepMs: Int
    let bundlePrefixes: [String]
    let anyApp: Bool
    var machPort: CFMachPort?

    let sendQueue = DispatchQueue(label: "remote-ime-sync.send")

    init(trigger: (Int, CGEventFlags), hostKey: (Int, CGEventFlags)?,
         sendStepMs: Int, bundlePrefixes: [String], anyApp: Bool) {
        self.trigger = trigger
        self.hostKey = hostKey
        self.sendStepMs = sendStepMs
        self.bundlePrefixes = bundlePrefixes
        self.anyApp = anyApp
    }

    // Marks the events we post ourselves so the tap ignores them.
    static let ownTag: Int64 = 0x1_4E45_5359   // "IMESY"
    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskShift, 56), (.maskControl, 59), (.maskAlternate, 58), (.maskCommand, 55),
    ]

    func post(_ event: CGEvent?) {
        guard let e = event else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Tap.ownTag)
        e.post(tap: .cgSessionEventTap)
    }

    func postFlagsChanged(_ flags: CGEventFlags, _ key: CGKeyCode) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .flagsChanged
        e.setIntegerValueField(.keyboardEventKeycode, value: Int64(key))
        e.flags = flags
        post(e)
    }

    // Send the host's own toggle shortcut in place of the trigger.
    //
    // Rewriting the key event's flags is not enough: the remote desktop app
    // forwards modifier state as separate flagsChanged events, so a host that
    // never saw Control and Option go down won't match the shortcut (verified
    // 2026-09-01 — the rewritten keyDown arrived at the host intact and the
    // hotkey still didn't fire). So we synthesize the whole sequence: press the
    // modifiers the host key adds, tap the key, then put the modifiers back the
    // way the user is actually holding them.
    func sendHostKey(replacing event: CGEvent) {
        guard let h = hostKey else { return }
        let held = event.flags.intersection(Tap.relevant)
        let add = h.flags.subtracting(held)
        let drop = held.subtracting(h.flags)
        let original = event.flags
        let step = UInt32(sendStepMs * 1000)

        // Off the tap callback: sleeping in it would stall every other key.
        sendQueue.async {
            var flags = original
            func settle() { if step > 0 { usleep(step) } }

            for (mask, key) in Tap.modifierKeyCodes where add.contains(mask) {
                flags.insert(mask); self.postFlagsChanged(flags, key); settle()
            }
            for (mask, key) in Tap.modifierKeyCodes where drop.contains(mask) {
                flags.remove(mask); self.postFlagsChanged(flags, key); settle()
            }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(h.keyCode), keyDown: down)
                else { continue }
                e.flags = flags
                self.post(e); settle()
            }
            // Restore what the user is physically holding, or the host is left
            // with phantom modifiers down.
            for (mask, key) in Tap.modifierKeyCodes.reversed() where drop.contains(mask) {
                flags.insert(mask); self.postFlagsChanged(flags, key); settle()
            }
            for (mask, key) in Tap.modifierKeyCodes.reversed() where add.contains(mask) {
                flags.remove(mask); self.postFlagsChanged(flags, key); settle()
            }
        }
    }

    func remoteAppFrontmost() -> Bool {
        if anyApp { return true }
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return bundlePrefixes.contains { id.hasPrefix($0) }
    }

    // Only these bits participate in shortcut matching.
    static let relevant: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.eventSourceUserData) != Tap.ownTag,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode,
              remoteAppFrontmost()
        else { return Unmanaged.passUnretained(event) }

        let flags = event.flags.intersection(Tap.relevant)
        let isRealign = !trigger.flags.contains(.maskShift)
            && flags == trigger.flags.union(.maskShift)
        guard flags == trigger.flags || isRealign else {
            return Unmanaged.passUnretained(event)
        }

        // We send our own key sequence, so swallow both halves of the original.
        if hostKey != nil, type == .keyUp { return nil }

        if isRealign {
            NSLog("realign: host-only toggle")
            if hostKey == nil { event.flags = event.flags.subtracting(.maskShift) }
        } else {
            toggleLocalInputSource()
        }
        if hostKey != nil {
            sendHostKey(replacing: event)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    func start() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            Unmanaged<Tap>.fromOpaque(userInfo!).takeUnretainedValue()
                .handle(type: type, event: event)
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap, // ahead of the remote app's own tap
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        return true
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var tap: Tap!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.load()
        let trigger: (Int, CGEventFlags)
        if let code = config.triggerKeyCode {
            trigger = (code, modifierFlags(config.triggerModifiers ?? []))
        } else if let detected = detectSystemToggleShortcut() {
            trigger = detected
        } else {
            fputs("""
            error: could not auto-detect the input source shortcut \
            (symbolic hotkey 60 disabled?). Set triggerKeyCode/triggerModifiers \
            in ~/.config/remote-ime-sync/config.json
            """, stderr)
            exit(1)
        }
        let hostKey: (Int, CGEventFlags)? = config.hostKeyCode.map {
            ($0, modifierFlags(config.hostModifiers ?? []))
        }
        NSLog("trigger: keyCode=%d flags=%@ / host: %@",
              trigger.0, String(describing: trigger.1),
              hostKey.map { "keyCode=\($0.0) flags=\($0.1)" } ?? "same (pass-through)")

        tap = Tap(trigger: trigger, hostKey: hostKey,
                  sendStepMs: config.sendStepMs ?? 25,
                  bundlePrefixes: config.bundlePrefixes ?? ["com.p5sys.jump"],
                  anyApp: config.anyApp ?? false)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇄한"
        let menu = NSMenu()
        menu.addItem(withTitle: "RemoteIMESync — trigger + Shift = host-only realign",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu

        // Input Monitoring has to be asked for explicitly. A failing
        // CGEvent.tapCreate alone does not put us in the System Settings list —
        // only IOHIDRequestAccess registers the app there (verified 2026-09-01).
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            NSLog("requesting Input Monitoring access")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // Exiting when denied would make a KeepAlive launchd job respawn us in a
        // loop, reopening System Settings every few seconds — so wait instead.
        if !waitForTap() {
            statusItem.button?.title = "⇄한⚠️"
            NSLog("no event tap yet — grant Input Monitoring to \(Bundle.main.executablePath ?? "this binary")")
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
                if self.waitForTap() {
                    timer.invalidate()
                    self.statusItem.button?.title = "⇄한"
                }
            }
        }
    }

    func waitForTap() -> Bool {
        guard tap.start() else { return false }
        NSLog("running")
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
