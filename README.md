# vncx

A native, simple VNC viewer for macOS, built with SwiftUI, AppKit, and Metal.

## Features

- **Retina-correct rendering.** The framebuffer lives in GPU-shared memory and is drawn by a Metal shader. At 1:1 and integer zoom it is pixel-exact. When downscaling large remotes (5K/6K), it box-filters instead of aliasing.
- **Scaling and zoom.** Scale to Fit locks the window aspect ratio. Actual Size pans by following the mouse. Resize Remote changes the server's resolution to match the window. Pinch to zoom on top of any mode; a two-finger double tap toggles it.
- **Multiple displays.** Servers that report several screens (WayVNC `--desktop`, TigerVNC multi-head) get a Displays menu. Show all of them, pick one (remembered per connection), or open each in its own window and put them full screen on different Mac displays.
- **macOS Screen Sharing servers.** Supports Apple's account-based authentication (RFB security type 30), as well as standard VNC passwords.
- **Encodings.** Tight (with JPEG), ZRLE, Hextile, Zlib, RRE, CopyRect and Raw. Pseudo-encodings: cursor and alpha cursor, desktop resize and multi-screen layout, desktop name, continuous updates, fences, and the extended (UTF-8) clipboard.
- **Automatic quality.** Lossless on fast links; Tight JPEG as the measured link rate or latency degrades. A stats overlay (⌃⌘I) shows frame rate, bandwidth, link estimate, latency and encodings.
- **Survives sleep and network changes.** Dropped connections reconnect with backoff, reusing the session's credentials.
- **SSH.** Tunnel VNC through SSH, start the VNC server on demand if it isn't running (WayVNC and TigerVNC presets), and drop files on the window to upload them. Uses the system `ssh`, so `~/.ssh/config`, keys and agents apply.
- **Wake-on-LAN.** Wakes a sleeping computer before connecting, optionally through a relay machine on its LAN.
- **Mac conventions.** Keychain passwords, Bonjour discovery, `vnc://` URLs, native full screen and window tabs, Unicode clipboard sync, ⌘-shortcut forwarding, full keyboard capture (⌘Tab, ⌘Space, Mission Control) in full screen, a menu bar item, and drag and drop: dropped text is pasted (hold ⌥ to type it instead).
- **Launcher.** Recent computers appear with thumbnails of their last screen.

## Build and run

Requires macOS 15+ and the Swift 6 toolchain. Command Line Tools are enough; Xcode is not required.

```sh
task run          # build build/vncx.app and open it
task install      # copy it into ~/Applications
task test         # unit tests (auth crypto, address parsing, decoders)
task test-server  # Docker TigerVNC on localhost:5901, password "testpass"
task wayvnc-server # Docker sway + WayVNC --desktop with two outputs on localhost:5902, no auth
task probe        # headless decode test of every encoding against the TigerVNC server
```

You can also connect from the command line with `open build/vncx.app --args host:port`.

## Keyboard

Keys are sent as X11 keysyms. Command maps to Super by default; you can change this in Settings. ⌘ shortcuts go to the remote computer, except ⌘Q, ⌘H, and every ⌃⌘ shortcut, which vncx keeps for its own menu:

| Shortcut | Action |
|---|---|
| ⌃⌘1 / ⌃⌘2 / ⌃⌘3 | Scale to Fit / Actual Size / Resize Remote |
| ⌃⌘= / ⌃⌘- / ⌃⌘0 | Zoom in / out / reset |
| ⌃⌘O | View only |
| ⌃⌘I | Connection stats |
| ⌃⌘⌫ | Send Control-Alt-Delete |
| ⌃⌘V | Type clipboard text as keystrokes |
| ⌃⌘S | Save screenshot to Desktop |
| ⌃⌘D | Disconnect / reconnect |

## Layout

- `Sources/VNCCore` contains the RFB protocol: transport, auth, and decoders. It has no UI dependencies.
- `Sources/vncx` contains the SwiftUI app, the Metal renderer, and input handling.
- `Sources/vncx-probe` is a headless client for integration testing.
- `Sources/vncx-tests` is the unit test runner. Swift Testing does not discover tests under the Command Line Tools toolchain, so the tests run as a plain executable.

## Development notes

- The bundle is ad-hoc signed. Each rebuild changes the signature, so macOS asks again before vncx can read its saved keychain passwords. Signing with a stable identity avoids this.
- Full keyboard capture needs the Accessibility permission. Ad-hoc builds lose it on every rebuild, like the keychain access above.
- `VNCX_DEBUG_DIR=/some/dir` makes a run ephemeral: it stays in the background, never takes focus, and doesn't touch saved connections. `kill -USR1 <pid>` dumps window and session state, offscreen renders, and SwiftUI captures into the directory. `kill -USR2 <pid>` runs the action in `<dir>/action`: `select:N`, `openall`, `onewindow`, `upload:/a|/b`, or `type:text\n`.
- `VNCX_OPEN_JSON=/path/connection.json` opens a fully specified connection, using the same format as `connections.json`.
- `TRACE=1 vncx-probe host` prints every rectangle, screen layout and cursor the server sends, plus a stats summary.
- niri (through 26.04) ignores its own key bindings for keys from virtual keyboards, which is how WayVNC types (niri issue #403, PR #4548). Super+arrow and other niri shortcuts therefore don't work over WayVNC, from any VNC client. Keys still reach applications.
- Not supported yet: VeNCrypt/TLS security types, and Apple's private Screen Sharing extensions (macOS servers send no cursor shapes to standard clients). Tailscale already encrypts traffic for the intended use.
