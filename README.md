# vncx

A native, simple VNC viewer for macOS. It's built with SwiftUI, AppKit and Metal, and it's designed for Retina displays and large remote desktops.

vncx connects to macOS Screen Sharing, WayVNC, TigerVNC, ReFrame and other RFB (VNC) servers. It renders the remote desktop pixel-exact on Retina screens, scales large desktops down cleanly, and follows Mac conventions: Keychain, full screen, tabs, the menu bar, Bonjour and drag and drop. It also handles things a VNC client usually leaves to you: SSH tunnels, starting the server on demand, Wake-on-LAN, multi-monitor remotes, and reconnecting after sleep.

## Highlights

- **Sharp on Retina.** The remote framebuffer lives in GPU-shared memory and is drawn by a Metal shader, with no per-frame copies. At 1:1 and integer zoom levels every remote pixel maps to whole device pixels. Large remotes (4K, 5K, 6K) are downscaled with a box filter instead of being aliased.
- **Scaling that fits how you work.** Scale to Fit locks the window to the remote's aspect ratio. Fill Width and Fill Height fill one dimension and pan along the other as you move the mouse, which is handy for ultrawide or tall remotes. Actual Size shows pixels 1:1. Resize Remote makes the server match your window. Pinch to zoom works on top of any of them.
- **Multi-monitor remotes.** Show all displays, pick one (remembered per computer), or open each display in its own window and put them full screen on different Mac displays.
- **macOS Screen Sharing.** Log in with a macOS account (Apple Remote Desktop authentication) as well as with a standard VNC password.
- **Built for real networks.** Automatic quality picks lossless or JPEG from the measured link speed and latency. Dropped connections, sleep and network changes reconnect automatically. A stats overlay shows frame rate, bandwidth, latency and encodings.
- **SSH built in.** Tunnel VNC through SSH, start the VNC server on demand when it isn't running, and drop files on the window to upload them. It uses your `~/.ssh/config`, keys and agent.
- **Wake-on-LAN,** directly or through a relay machine on the sleeping computer's network.
- **Unicode clipboard** in both directions with servers that support the extended clipboard, plus drag-and-drop pasting of text.
- **Keyboard that behaves.** ⌘ shortcuts go to the remote. Full keyboard capture in full screen sends ⌘Tab, ⌘Space and Mission Control keys too. vncx keeps ⌃⌘ shortcuts, ⌘Q and ⌘H for itself.

## Quick start

Requirements: macOS 15 or later, and a Swift 6 toolchain. The Xcode Command Line Tools are enough.

```sh
task run        # build build/vncx.app and open it
task install    # copy it into ~/Applications
```

Type a host name in the launcher and press Return. These address forms work:

```
durandal.local
vegeta.example.ts.net:5901
mac.local:1                  # display 1 = port 5901
host::5999                   # explicit port
vnc://alice@mac.local:5900
```

You can also open `vnc://` links from anywhere, or run `open build/vncx.app --args host:port`.

## Documentation

- [User guide](docs/user-guide.md): connecting, windows, scaling and zoom, displays, keyboard, clipboard, SSH, Wake-on-LAN, settings, and every shortcut.
- [Features and protocol support](docs/protocol.md): RFB versions, security types, encodings, pseudo-encodings and extensions.
- [Server notes](docs/servers.md): macOS Screen Sharing, WayVNC, TigerVNC and ReFrame, with their quirks and recommended setups.
- [How vncx compares](docs/comparison.md): differences from TigerVNC, RealVNC Viewer, Screen Sharing.app and others.
- [Development](docs/development.md): building, code layout, tests, the probe tool, Docker test servers and debug hooks.

## Status and limitations

vncx is young. It has been exercised against TigerVNC, WayVNC 0.10, macOS Screen Sharing and ReFrame. Known gaps:

- **No TLS security types.** VeNCrypt and the RSA-AES types aren't supported. Use Tailscale, a VPN, or the built-in SSH tunnel.
- **No remote cursor on macOS servers.** macOS Screen Sharing doesn't send cursor shapes to standard VNC clients, so vncx shows a local cursor.
- **niri shortcuts don't work over WayVNC.** niri ignores its own key bindings for keys from virtual keyboards, which is how WayVNC types. See [server notes](docs/servers.md#wayvnc).
- **No file transfer over VNC.** VNC has no standard file transfer. vncx uploads dropped files over SSH instead.

## License

vncx is licensed under the [Apache License, Version 2.0](LICENSE). Copyright 2026 Ahimsa Labs.
