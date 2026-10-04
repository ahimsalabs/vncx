# How vncx compares

vncx was started because the usual options didn't fit a Mac user on a Tailscale network:

- RealVNC's viewer went commercial-only.
- TigerVNC's viewer isn't Mac-native: it doesn't look right on Retina displays and handles very large remote desktops poorly.
- macOS Screen Sharing is excellent with Macs but basic with everything else.

This page describes what vncx does differently, and where the alternatives are still stronger. Statements about other products are general and may lag their latest releases.

## What vncx does differently

### Native Mac app, Retina-first rendering

vncx is an AppKit and SwiftUI app with a Metal renderer, not a cross-platform toolkit port.

- The remote framebuffer sits in GPU-shared memory and is sampled directly, so nothing is copied per frame, even for 6K remotes.
- 1:1 and integer zoom levels are pixel-exact on Retina, and near-integer window sizes snap to exact mappings.
- Downscaling box-filters each pixel's footprint, so a 5K desktop in a small window stays readable instead of aliasing.
- Native full screen, tabs, Stage Manager, dark mode, Keychain, Bonjour, `vnc://` links, the menu bar and SF Symbols.

### Large and multi-monitor remotes

- **Five scaling modes:** fit with an aspect-locked window, Fill Width and Fill Height, Actual Size, and Resize Remote. Whenever the image overflows the window, it pans by following the mouse. Pinch to zoom works on top of all of them.
- **A display picker** for servers that report several screens. Show one display (remembered), or open each display in its own window and spread them across your Mac's monitors in full screen. Most clients show only the whole desktop.
- Displays are ordered by position, not by the server's list order.

### Network resilience

- **Automatic quality** from the remote's size and the measured delivery rate, so a full-screen repaint stays under half a second, switching between lossless and JPEG with hysteresis.
- **Continuous updates and fences** with servers that support them, for lower latency than request-per-frame polling.
- **Automatic reconnect** after drops, sleep and network changes, with in-memory credentials so you aren't prompted again.
- **Live stats:** frame rate, bandwidth, link estimate, latency and encoding mix.

### Built-in SSH and Wake-on-LAN

- **SSH tunnels** through the system `ssh`, so your config, agent, ProxyJump and keys work unchanged.
- **Start the server on demand:** if the VNC server isn't running, vncx starts it over SSH and retries. Presets cover WayVNC and TigerVNC.
- **Drag-and-drop file upload** over SSH, sidestepping VNC's lack of standard file transfer.
- **Wake-on-LAN** that also works off-LAN, through an SSH relay on the sleeping machine's network.

### Keyboard and clipboard details

- ⌘ shortcuts go to the remote. vncx's own commands all use ⌃⌘, so they never collide.
- Full keyboard capture (⌘Tab, ⌘Space, Mission Control) in full screen.
- The Command key can send Super, Meta, Control or Alt.
- Unicode clipboard in both directions through the extended clipboard extension.
- Dropped text is pasted, with a per-computer paste shortcut (terminals want Ctrl+Shift+V).

### Tooling

`vncx-probe` traces exactly what a server sends: rectangles, screen layouts, cursors, encodings, latency. That makes it quick to tell server problems from client problems; [server notes](servers.md) were built with it.

## Compared with specific clients

### TigerVNC viewer (`vncviewer`)

TigerVNC's viewer is a solid, open-source, cross-platform client built on the FLTK toolkit.

**Where it's stronger:**

- **More security types,** including VeNCrypt/TLS with X.509 and RSA-AES.
- **Reverse ("listen") connections.**
- **The QEMU extended key event,** for layout-independent keys.
- **Mature support** for every TigerVNC server feature.

**Where vncx differs:**

- **Native AppKit UI** with proper Retina rendering and high-quality downscaling of large remotes.
- **Mac conventions:** Keychain, Bonjour, full screen, tabs and the menu bar.
- **Per-display windows** for multi-monitor remotes.
- **SSH start-on-demand,** file upload and Wake-on-LAN.
- **Automatic reconnect** after sleep.

TigerVNC's `-via` option offers an SSH tunnel, but not starting the server or uploading files.

### RealVNC Viewer

RealVNC Viewer is proprietary. Its strongest features (cloud brokering, RealVNC's own encryption, and extras like file transfer and printing) are designed around RealVNC Server and accounts.

vncx is open source and has no accounts or cloud service. It's aimed at standard RFB servers on a network you already control, such as Tailscale, a LAN or a VPN. It doesn't support RealVNC's RA2/RSA-AES security types, so a RealVNC Server must allow standard VNC authentication, or be reached through SSH.

### macOS Screen Sharing (Screen Sharing.app)

Screen Sharing.app is the best client for Macs. Through Apple's private protocol extensions it gets remote cursors, a shared clipboard, high-performance modes on Apple silicon, curtain mode and file copying.

vncx speaks standard RFB to Macs, so it lacks those extensions. In particular, macOS doesn't send it cursor shapes. Its advantages are elsewhere:

- **Better with non-Mac servers:** Tight and JPEG, extended clipboard, continuous updates, multi-display selection, remote resize.
- **SSH, Wake-on-LAN and automatic quality.**
- **One client for every machine.**

For a Mac-to-Mac session where Screen Sharing works, it remains a great choice.

### Commercial Mac clients (Screens, Jump Desktop and others)

Polished commercial clients cover much of the same ground: native UI, trackpad gestures, and in some cases SSH tunnels. Some offer iOS apps, cloud discovery and sync.

vncx differs in being free and open, in starting VNC servers over SSH on demand, in its multi-monitor display windows, and in its server-diagnostics tooling. It doesn't sync settings through iCloud, and it has no iOS app.

## What vncx doesn't do (yet)

- TLS security types (VeNCrypt, RSA-AES). Use Tailscale, a VPN or the SSH tunnel.
- Apple's private Screen Sharing extensions (remote cursor on Macs, curtain mode).
- Reverse connections, audio, chat, printing.
- QEMU extended key events and extended mouse buttons.
- Spotlight and Shortcuts actions (App Intents) and iCloud sync of saved computers.
