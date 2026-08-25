// JumpModifierFix — HOST-side workaround for a Jump Desktop Connect 7.x bug:
// when the host input source is Korean (CJK), injected Cmd+Shift+<key> events
// arrive with a bogus Option modifier added, so host shortcuts don't match.
// (Fixed upstream in the 10.x beta; run this until stable ships, then delete.)
//
// A session-level event tap sees injected CGEvents (unlike Karabiner's HID
// grab), so we can strip the bogus Option flag before apps see the event.
//
// Modes:
//   JumpModifierFix --observe   log keyDown flags + source PID, modify nothing
//   JumpModifierFix             strip Option from injected Cmd+Shift+Opt keys
//                               while the current input source is CJK

import AppKit
import Carbon

let observe = CommandLine.arguments.contains("--observe")

func currentSourceIsCJKV() -> Bool {
    let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
          let lang = (Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
                        as? [String])?.first
    else { return false }
    return lang == "ko" || lang == "ja" || lang == "vi" || lang.hasPrefix("zh")
}

var machPort: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let srcPID = event.getIntegerValueField(.eventSourceUnixProcessID)
    let flags = event.flags

    if observe {
        if type == .keyDown {
            NSLog("keyDown code=%d flags=0x%llx srcPID=%d cmd=%d shift=%d opt=%d ctrl=%d",
                  keyCode, flags.rawValue, srcPID,
                  flags.contains(.maskCommand) ? 1 : 0,
                  flags.contains(.maskShift) ? 1 : 0,
                  flags.contains(.maskAlternate) ? 1 : 0,
                  flags.contains(.maskControl) ? 1 : 0)
        }
        return Unmanaged.passUnretained(event)
    }

    // Fix mode: injected (srcPID != 0) Cmd+Shift+Opt while CJK -> drop Opt.
    // ponytail: rare legit Cmd+Shift+Opt combos sent while Korean also get
    // stripped; acceptable until the upstream fix lands.
    if flags.contains(.maskCommand), flags.contains(.maskShift),
       flags.contains(.maskAlternate), srcPID != 0, currentSourceIsCJKV() {
        event.flags = flags.subtracting(.maskAlternate)
        NSLog("stripped bogus Option: keyCode=%d srcPID=%d", keyCode, srcPID)
    }
    return Unmanaged.passUnretained(event)
}

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
guard let port = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: observe ? .listenOnly : .defaultTap,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: nil)
else {
    fputs("error: could not create event tap — grant Input Monitoring and retry\n", stderr)
    exit(1)
}
machPort = port
CFRunLoopAddSource(CFRunLoopGetCurrent(),
                   CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
NSLog("JumpModifierFix running (%@)", observe ? "observe" : "fix")
CFRunLoopRun()
