# Development

## Building

vncx is a Swift package; the Taskfile wraps it. The Xcode Command Line Tools are enough; full Xcode isn't required.

```sh
task build         # release build of all targets
task check         # debug build of all targets
task bundle        # assemble and ad-hoc sign build/vncx.app (also renders the icon)
task run           # bundle and open
task install       # bundle and copy to ~/Applications
task test          # unit tests
task clean
```

The app bundle is put together by hand from the SwiftPM binary, `Resources/Info.plist`, the icon rendered by `Resources/icon.swift`, and `Resources/vncx.entitlements`, and then signed. Local builds are signed ad hoc, so each build gets a new signature: macOS asks again for Keychain access to saved passwords, and resets the Accessibility permission used for keyboard capture. To sign with a stable identity, pass it to the bundle task:

```sh
task bundle SIGN_IDENTITY="<SHA-1 or name of a code-signing identity>"
```

## Build identity

`task bundle` stamps the bundle's `Info.plist` with three values:

| Key | Value |
|---|---|
| `CFBundleVersion` | The build number: the commit count of `HEAD`, so it always increases on `main`. |
| `VNCXGitCommit` | The full commit hash, with `-dirty` when the working copy has uncommitted changes. In a jj repo, git's `HEAD` is the working copy's parent. |
| `VNCXBuildDate` | The UTC build time. |

**About vncx** shows the version and build, the commit linked to GitHub, and the build date. **vncx › Copy Version Info** copies a one-line summary for bug reports, for example `vncx 0.1.0 (21) e98a754, built 2026-10-03T18:47Z`. CI checks out the full history so the build number matches local builds.

## Release builds

The `build` workflow (`.github/workflows/build.yml`) runs on demand from the Actions tab or with `gh workflow run build -R ahimsalabs/vncx`. It builds on a GitHub macOS runner, signs with a self-signed certificate, uploads the zip as a run artifact, and by default replaces the [`nightly`](https://github.com/ahimsalabs/vncx/releases/tag/nightly) prerelease.

The certificate is what keeps permissions across updates: the designated requirement is `certificate leaf = H"e3783d59…"`, so Keychain and Accessibility grants survive new builds. Replacing the certificate resets them for every user. It lives in the `MACOS_CERT_P12` and `MACOS_CERT_PASS` repository secrets, with the original kept offline by the maintainer. Builds are not notarized, so Gatekeeper still asks for **Open Anyway** on first launch; notarization needs an Apple Developer ID.

## Code layout

| Path | Contents |
|---|---|
| `Sources/VNCCore/` | The RFB protocol. No UI. |
| `  Transport.swift` | Blocking, buffered reads over `NWConnection` |
| `  RFBClient.swift` | Handshake, security, message loop, client messages, extensions, stats |
| `  Framebuffer.swift` | Shared-memory Metal buffer holding the remote image |
| `  Decoders/` | Raw, CopyRect, RRE, Hextile, Zlib, ZRLE, Tight |
| `  Auth/` | VNC DES auth, Apple Diffie-Hellman auth, Montgomery bignum |
| `  ZStream.swift`, `Address.swift`, `WakeOnLAN.swift` | zlib wrapper, address parsing, magic packets |
| `Sources/vncx/App/` | App entry, menus, menu bar, session window controller, debug hooks |
| `Sources/vncx/Model/` | Session, saved connections, Keychain, preferences, Bonjour, SSH, Wake-on-LAN relay |
| `Sources/vncx/UI/` | Metal renderer and shader, the remote view (input, layout, zoom, drag and drop), key mapping, keyboard capture, SwiftUI views |
| `Sources/vncx-probe/` | Headless client for testing against real servers |
| `Sources/vncx-tests/` | Unit test runner |
| `Sources/CZlib/` | System zlib module map |
| `test/` | Docker test servers |

**Session data flow:**

1. `RFBClient` runs the protocol on its own thread and decodes straight into the `Framebuffer`.
2. It posts events to `Session` on the main thread. Redraws are coalesced.
3. `Session` owns the connection lifecycle: credentials, reconnects, SSH, Wake-on-LAN and stats. It drives one or more `RemoteView`s, one per window.
4. `RemoteView` (an `MTKView`) handles input and layout. `Renderer` samples the framebuffer through a texture view on the same memory.

Session windows are AppKit `NSWindow`s hosting SwiftUI content, not SwiftUI `WindowGroup`s. A VNC viewer needs precise control over content size, aspect ratio and full screen. The launcher, settings and menu bar are SwiftUI scenes.

Saved connections are JSON in `~/Library/Application Support/vncx/connections.json`, with thumbnails beside it. Decoding is tolerant: missing keys take defaults, so new settings never invalidate existing files.

## Tests

```sh
task test
```

Swift Testing doesn't discover tests under the Command Line Tools toolchain, so the unit tests are a plain executable (`vncx-tests`) with a tiny runner. They cover:

- **Diffie-Hellman bignum:** checked against Python's `pow()`.
- **VNC DES auth:** checked against OpenSSL.
- **Apple auth round trip:** against a simulated server.
- **Address parsing.**
- **Decoders:** ZRLE (solid, packed palette, plain RLE, palette RLE) and Tight (mono palette, gradient, fill), using an in-memory transport.
- **Wake-on-LAN:** MAC parsing and the magic packet.

## Test servers

```sh
task test-server       # TigerVNC in Docker on localhost:5901, password "testpass", 2560x1440
task wayvnc-server     # sway + WayVNC --desktop in Docker on localhost:5902, no auth
task test-server-stop  # stop both
task probe             # decode every encoding against the TigerVNC server
```

The WayVNC container runs headless sway with two outputs of different sizes, side by side, listed by WayVNC right-hand first, to exercise display ordering. It also binds Super+Up, Super+T and Super+Shift+Left to commands that touch files in `/tmp`, so tests can check that key combinations arrive. It's an amd64 image; on Apple silicon it runs under emulation.

## The probe

`vncx-probe` connects headlessly, prints what happens, and can save the framebuffer as a PNG.

```sh
build/vncx-probe host:port [options]
```

| Option | Purpose |
|---|---|
| `--password PW`, `--user NAME` | Credentials. Otherwise the probe asks on the terminal without echo. `VNC_PASSWORD` also works. |
| `--encoding E` | Force one encoding: `raw`, `copyrect`, `rre`, `hextile`, `zlib`, `tight`, `zrle`, `tightjpeg`. |
| `--frames N`, `--seconds S` | Stop after N updates or S seconds. |
| `--out file.png` | Save the final framebuffer. |
| `--move` | Sweep the pointer across the desktop, so the server sends cursor shapes. |
| `--resize WxH` | Request a desktop size after the first update. |
| `--clipboard TEXT` | Send clipboard text after the first update. |
| `--keys ffeb,ff52` | Press hex keysyms in order and release them in reverse, for example Super+Up. |
| `TRACE=1` (environment) | Print every rectangle header, screen layout and cursor. |

It always ends with a stats line: updates, bytes, link rate, round-trip time, whether continuous updates and fences were used, and bytes per encoding.

## Debug hooks

These are for driving and inspecting the real app without touching your setup.

- **`VNCX_DEBUG_DIR=/dir`** makes a run *ephemeral*:
  - The app stays in the background, never takes keyboard focus and has no Dock icon.
  - It never reads or writes saved connections or thumbnails.
  - `kill -USR1 <pid>` writes `state.txt` (windows, layouts, sessions, displays, banner), window-chrome PNGs, an offscreen Metal render of each remote view (and one at 2× zoom), SwiftUI renders of the launcher cards and the stats overlay.
  - `kill -USR2 <pid>` runs the action in `/dir/action`:

    | Action | Effect |
    |---|---|
    | `select:N` | Show display N (0 = all) |
    | `openall` | Open each display in its own window |
    | `onewindow` | Back to a single window |
    | `upload:/a\|/b` | Upload files as if dropped |
    | `type:text\n` | Paste text as if dropped |
    | `keys:cmd+up` | Synthesize AppKit key events through the normal dispatch path |

- **`VNCX_OPEN_JSON=/path/connection.json`** opens a fully specified connection, in the same format as `connections.json`, without saving it. It also makes the run ephemeral.
- **Command line:** `vncx host[:port]` opens a connection at launch.

An example ephemeral run:

```sh
D=$(mktemp -d)
VNCX_DEBUG_DIR=$D build/vncx.app/Contents/MacOS/vncx localhost:5902 &
PID=$!
sleep 4; echo select:2 > $D/action; kill -USR2 $PID
sleep 1; kill -USR1 $PID; sleep 1; cat $D/state.txt
kill $PID
```

## Version control

The repository uses jj. Each feature is its own change; `jj log` shows the history.
