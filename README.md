# vncx

A native, simple VNC viewer for macOS, built with SwiftUI, AppKit, and Metal.

## Features

- **Retina-correct rendering.** The framebuffer lives in GPU-shared memory and is drawn by a Metal shader. At 1:1 and integer zoom it is pixel-exact. When downscaling large remotes (5K/6K), it box-filters instead of aliasing.
- **Three scaling modes.** Scale to Fit locks the window aspect ratio. Actual Size pans by following the mouse. Resize Remote changes the server's resolution to match the window (ExtendedDesktopSize servers such as TigerVNC).
- **macOS Screen Sharing servers.** Supports Apple's account-based authentication (RFB security type 30), as well as standard VNC passwords.
- **Encodings.** Tight (with JPEG), ZRLE, Hextile, Zlib, RRE, CopyRect, Raw, plus local cursor rendering, desktop resize, and desktop name updates.
- **Mac conventions.** Keychain passwords, Bonjour discovery of nearby computers, `vnc://` URLs, native full screen and window tabs, clipboard sync, ⌘-shortcut forwarding, and trackpad scrolling.
- **Launcher.** Recent computers appear with thumbnails of their last screen.

## Build and run

Requires macOS 15+ and the Swift 6 toolchain. Command Line Tools are enough; Xcode is not required.

```sh
task run          # build build/vncx.app and open it
task install      # copy it into ~/Applications
task test         # unit tests (auth crypto, address parsing, decoders)
task test-server  # Docker TigerVNC on localhost:5901, password "testpass"
task probe        # headless decode test of every encoding against that server
```

You can also connect from the command line with `open build/vncx.app --args host:port`.

## Keyboard

Keys are sent as X11 keysyms. Command maps to Super by default; you can change this in Settings. ⌘ shortcuts go to the remote computer, except ⌘Q, ⌘H, and every ⌃⌘ shortcut, which vncx keeps for its own menu:

| Shortcut | Action |
|---|---|
| ⌃⌘1 / ⌃⌘2 / ⌃⌘3 | Scale to Fit / Actual Size / Resize Remote |
| ⌃⌘O | View only |
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
- With `VNCX_DEBUG_DIR=/some/dir`, sending `kill -USR1 <pid>` dumps window and session state plus an offscreen render of each remote view.
- Not supported yet: VeNCrypt/TLS security types, extended (UTF-8) clipboard, and Apple-specific encodings. Tailscale already encrypts traffic for the intended use.
