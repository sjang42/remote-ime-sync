# RemoteIMESync

Keep local and remote input sources (한/영, かな/英数, …) in sync while using a
Mac-to-Mac remote desktop app such as Jump Desktop.

## Why

Remote desktop apps forward your keystrokes to the host, but each Mac keeps its
own input source state. When they disagree, typing breaks (jamo decomposition,
keys misread as Cmd shortcuts). This tool makes one keypress flip both sides.

## How it works — one keypress, one event, two effects

- An event tap is inserted *ahead of* the remote desktop app's own tap.
- When your input-source shortcut (auto-detected from System Settings) is
  pressed while the remote app is frontmost, RemoteIMESync switches the
  **local** input source via the TIS API and lets the event pass through
  untouched — the remote app forwards it, and the **host's** own system
  shortcut toggles the host side. No agent, no network, nothing installed on
  the host.
- **Trigger + Shift** = realign key: shift is stripped from the event so only
  the host toggles. Use it once if the two sides ever get crossed (e.g. you
  changed language outside the remote session).

## Install

```sh
swift build -c release
.build/release/RemoteIMESync   # menu bar item "⇄한" appears
```

Grant Input Monitoring when prompted (System Settings > Privacy & Security).
On the host: nothing to install — just make sure the remote desktop app is set
to forward all shortcuts to the remote machine, and the host has an
input-source shortcut enabled (e.g. Cmd+Space).

## Config (optional)

Everything is auto-detected. To override, create
`~/.config/remote-ime-sync/config.json`:

```json
{
  "bundlePrefixes": ["com.p5sys.jump"],
  "triggerKeyCode": 49,
  "triggerModifiers": ["command"],
  "anyApp": false
}
```

- `bundlePrefixes` — remote desktop apps to activate in (bundle id prefixes)
- `triggerKeyCode` / `triggerModifiers` — override the auto-detected shortcut
- `anyApp` — ignore the frontmost-app check (for testing)

## Limitations

- The host shortcut must match what the client sends (same shortcut on both
  Macs — the usual case). A `sendAs` remap is a planned option.
- Realign is manual (one keypress). Automatic realign would require knowing
  the host's state, i.e. installing something on the host — deliberately out
  of scope.
