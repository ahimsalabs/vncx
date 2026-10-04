# Server notes

How vncx behaves with the servers it has been tested against, what each one supports, and recommended setups. To check what any server actually sends, use the probe:

```sh
TRACE=1 build/vncx-probe host:port --move --frames 100 --seconds 6
```

It prints every rectangle, screen layout and cursor shape, plus a stats summary. `--move` sweeps the pointer, so the server sends cursor changes; leave it off for a hands-off look.

## Summary

| | macOS Screen Sharing | WayVNC 0.10 | TigerVNC 1.12+ | ReFrame 1.21 |
|---|---|---|---|---|
| Login | macOS account (or VNC password if enabled) | None or VNC password | VNC password | None or password |
| Encodings used | ZRLE | ZRLE | Tight, ZRLE | ZRLE |
| Cursor shapes | No | Yes, depending on the compositor | Yes, with alpha | Expected, untested |
| Unicode clipboard | No | Yes | Yes | Expected (needs `reframe-session`), untested |
| Continuous updates and fences | No | Yes | Yes | Yes |
| Several monitors in one session | No | With `--desktop` | Multi-head setups | No: one instance per monitor |
| Remote resize | No | Yes | Yes | Yes (`resize=true`) |
| Input path | System | Wayland virtual keyboard and pointer | X server | Kernel uinput |

## macOS Screen Sharing

Turn it on in System Settings › General › Sharing › Screen Sharing.

- **Login:** vncx uses Apple Remote Desktop authentication, so enter a macOS account's name and password. If the remote Mac also allows "VNC viewers may control screen with password", a VNC password works too. Set a user name in the connection to prefer the account login.
- **Version:** the server announces RFB 3.889. vncx answers with standard 3.8, which keeps Apple's private extensions off.
- **Encodings:** only ZRLE was seen, so picture quality is always lossless and automatic quality has nothing to adjust.
- **No cursor shapes.** macOS doesn't send them to standard clients. Apple's own Screen Sharing app gets cursors through private, undocumented extensions. vncx shows a local arrow; if you see the remote's own cursor drawn in the picture, set **Local cursor** to Hidden or Dot.
- **No continuous updates, fences or remote resizing.**
- **Discovery:** Macs with Screen Sharing on show up under **Nearby** in the launcher through Bonjour.

## WayVNC

WayVNC is a VNC server for wlroots-style Wayland compositors: sway, Hyprland, niri and others. It uses the neatvnc library. Version 0.10 or later is recommended.

**Run it with `--desktop` (`-a`)** to capture every output in one framebuffer:

```sh
wayvnc --desktop 0.0.0.0 5901
```

WayVNC then reports each output as a separate screen, and vncx's [Displays menu](user-guide.md#multiple-displays) can show all, show one, or put each in its own window. Without `--desktop`, WayVNC captures a single output and there's no protocol-level way to switch. Its first output isn't necessarily the one you want; the order follows the compositor, not the layout. In a test with two side-by-side outputs, WayVNC listed the right-hand one first. vncx orders displays by position.

**Fences and pending requests.** neatvnc (1.0.1 at least) stops reading a client's messages for good when a fence request arrives while it still holds a FramebufferUpdateRequest: further update requests, keys and pointer events go unread, and the picture freezes except for the one pending update. vncx counts the requests the server holds and only sends its latency fence when there are none. Other clients that send fences freely can hit this.

**Large updates.** neatvnc's Tight encoder sends every changed 64×64 tile as a separate JPEG with its own headers, about 830 bytes per tile even at low quality, so full-screen video on a large desktop can take 70 Mbit/s or more. The [bandwidth limit](user-guide.md#picture-quality-and-connection-stats) keeps it in check.

**Start it on demand:** set up [SSH](user-guide.md#ssh) for the computer and pick the **WayVNC (all displays)** start-command preset. It finds your Wayland session's socket and starts `wayvnc --desktop` on the connection's port if it isn't already running.

**Cursor shapes** depend on the compositor supporting cursor capture. Under sway, WayVNC 0.10 sends them. On the niri machine tested here, a single-output WayVNC sent none. Try `--desktop`, or set **Local cursor**. WayVNC's `-r` / `--render-cursor` draws the cursor into the picture instead.

**niri key bindings don't work over WayVNC.** niri ignores its own bindings (Mod+arrows, Mod+T, …) for keys that arrive from a virtual keyboard, and WayVNC types through one ([niri issue #403](https://github.com/niri-wm/niri/issues/403); a fix is proposed in [PR #4548](https://github.com/niri-wm/niri/pull/4548)). This affects every VNC client. Keys still reach applications. vncx's key handling was verified end to end: the same combinations trigger sway bindings through WayVNC. ReFrame, which injects input through the kernel, is the workaround to evaluate.

## TigerVNC

TigerVNC's `Xvnc` / `vncserver` and `x0vncserver`. TigerVNC supports nearly everything vncx implements:

- Tight with JPEG, so automatic quality is fully effective.
- Antialiased alpha cursors.
- The extended clipboard.
- Continuous updates with fence-based congestion control.
- SetDesktopSize.
- Multi-head screen layouts.

Notes:

- The default TigerVNC setup may offer VeNCrypt and plain VNC authentication. vncx uses the plain one. Restrict with `-SecurityTypes VncAuth`, or tunnel over SSH if you need encryption.
- Xvnc fetches clipboard data lazily, when an X application asks for it. vncx answers clipboard requests any time while connected.
- The **TigerVNC** SSH preset runs `vncserver :N` for the display matching the port (5901 is `:1`).

`task test-server` runs a TigerVNC server in Docker on `localhost:5901` (password `testpass`) for testing.

## ReFrame

[ReFrame](https://github.com/AlynxZhou/reframe) captures the screen through the kernel's DRM/KMS interface, below the compositor, and injects input through `uinput`. So it works with any compositor, and with the login screen. Compositor key bindings (niri's included) see its keyboard as a real device.

Its architecture differs from the others:

- It has a privileged streamer (root, socket-activated) and an unprivileged VNC server, run as systemd services `reframe@NAME.socket` and `reframe-server@NAME.service`, with a config at `/etc/reframe/NAME.conf`.
- **One monitor per instance.** For two monitors, run two instances on two ports. Give each config the whole desktop's logical size (`desktop-width`, `desktop-height`) and the monitor's logical position (`monitor-x`, `monitor-y`), so pointer coordinates land on the right screen. Get these from the compositor; for niri, `niri msg outputs`.
- Clipboard sync needs `reframe-session` running in your graphical session and your user in the `reframe` group (log in again after adding it).
- The `neatvnc` backend gives more encodings. With a password, neatvnc offers RSA-AES security, which vncx doesn't support, so use no password on a private network, or tunnel.

**NVIDIA:** ReFrame converts frames with EGL on the GPU. If the NVIDIA driver was upgraded but the machine hasn't been rebooted, NVIDIA's EGL refuses to run against the old kernel module. EGL then falls back to Mesa, which fails, and ReFrame drops every client right after the handshake. Its log shows:

```
MESA-EGL: warning: failed to open /dev/dri/card1: Permission denied
EGL: Failed to initialize: 12289.
```

`nvidia-smi` reports `Driver/library version mismatch` in the same state. Reboot.

### The vegeta evaluation setup

For the evaluation, `~/reframe-vncx/` on vegeta holds:

| File | Purpose |
|---|---|
| `dp1.conf` | Dell AW3821DW (DP-1): port 5933, logical position (0, 1000) |
| `hdmi.conf` | BOE panel (HDMI-A-1): port 5934, logical position (800, 0) |
| `install.sh` | Installs ReFrame from the AUR, installs the configs, adds you to the `reframe` group, runs `start.sh`. |
| `start.sh` | Starts both instances and the clipboard helper. The services aren't enabled at boot. |
| `uninstall.sh` | Stops ReFrame, removes the configs and the group membership (the package stays). |

Both configs describe the whole desktop as 3072×2280, listen only on the Tailscale address, and use the neatvnc backend with no password. As of writing, ReFrame is installed but blocked by the NVIDIA driver mismatch above until vegeta reboots. After the reboot, run `~/reframe-vncx/start.sh` and connect to `vegeta…:5933` and `:5934`.
