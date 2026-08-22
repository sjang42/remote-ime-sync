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

// MARK: - Config

struct Config: Codable {
    var bundlePrefixes: [String]?   // remote desktop apps; default ["com.p5sys.jump"]
    var triggerKeyCode: Int?        // override; default: auto-detect from system shortcut
    var triggerModifiers: [String]? // "command" | "shift" | "control" | "option"
    var anyApp: Bool?               // test mode: ignore frontmost-app check

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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
    let bundlePrefixes: [String]
    let anyApp: Bool
    var machPort: CFMachPort?

    init(trigger: (Int, CGEventFlags), bundlePrefixes: [String], anyApp: Bool) {
        self.trigger = trigger
        self.bundlePrefixes = bundlePrefixes
        self.anyApp = anyApp
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
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode,
              remoteAppFrontmost()
        else { return Unmanaged.passUnretained(event) }

        let flags = event.flags.intersection(Tap.relevant)
        if flags == trigger.flags {
            toggleLocalInputSource() // event passes through -> host toggles too
        } else if !trigger.flags.contains(.maskShift),
                  flags == trigger.flags.union(.maskShift) {
            // Realign: strip shift so only the host sees the toggle shortcut.
            event.flags = event.flags.subtracting(.maskShift)
            NSLog("realign: host-only toggle")
        }
        return Unmanaged.passUnretained(event)
    }

    func start() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            Unmanaged<Tap>.fromOpaque(userInfo!).takeUnretainedValue()
                .handle(type: type, event: event)
        }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
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
        NSLog("trigger: keyCode=%d flags=%@", trigger.0, String(describing: trigger.1))

        tap = Tap(trigger: trigger,
                  bundlePrefixes: config.bundlePrefixes ?? ["com.p5sys.jump"],
                  anyApp: config.anyApp ?? false)
        if !tap.start() {
            fputs("""
            error: could not create event tap. Grant Input Monitoring \
            (System Settings > Privacy & Security) and relaunch.
            """, stderr)
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            exit(1)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇄한"
        let menu = NSMenu()
        menu.addItem(withTitle: "RemoteIMESync — trigger + Shift = host-only realign",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
        NSLog("running")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
