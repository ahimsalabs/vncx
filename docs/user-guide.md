# vncx user guide

- [Installing](#installing)
- [Connecting](#connecting)
- [The launcher](#the-launcher)
- [Passwords and the Keychain](#passwords-and-the-keychain)
- [The session window](#the-session-window)
- [Scaling and zoom](#scaling-and-zoom)
- [Multiple displays](#multiple-displays)
- [Keyboard](#keyboard)
- [Mouse, trackpad and cursor](#mouse-trackpad-and-cursor)
- [Clipboard, drag and drop](#clipboard-drag-and-drop)
- [Picture quality and connection stats](#picture-quality-and-connection-stats)
- [Staying connected](#staying-connected)
- [SSH](#ssh)
- [Wake-on-LAN](#wake-on-lan)
- [Menu bar](#menu-bar)
- [Settings reference](#settings-reference)
- [Connection settings reference](#connection-settings-reference)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)

## Installing

Download the latest build and follow the first-launch steps in the [README](../README.md#install).

Downloaded builds are all signed with the same certificate, so updating keeps vncx's Keychain access and Accessibility permission. If you build vncx yourself, it's signed ad hoc instead: each build has a new signature, so macOS asks again before vncx can read its saved Keychain passwords and resets the Accessibility permission used for keyboard capture.

## Connecting

There are several ways to start a session:

- **Type an address** in the launcher's field and press Return.
- **Double-click a computer** in the launcher, or click the play button that appears when you hover over it.
- **Pick a computer** from the [menu bar](#menu-bar).
- **Open a `vnc://` link,** for example from Safari, Terminal (`open vnc://host`) or a Shortcut.
- **From the command line,** run `open ~/Applications/vncx.app --args host:port`.

Address formats:

| You type | Connects to |
|---|---|
| `host` | port 5900 |
| `host:1` | display 1, which is port 5901 (any number below 100 is a display number) |
| `host:5905` | port 5905 |
| `host::42` | port 42, an explicit port even when it's below 100 |
| `user@host` | port 5900, with `user` as the account name |
| `vnc://user@host:port` | as written |
| `[fd7a::1]:5901` | an IPv6 address with a port |

Host names resolve through the system resolver, so Tailscale MagicDNS names, `.local` Bonjour names and IPv6 all work.

While connecting, the window shows a progress panel. If the server needs credentials and none are saved, a login sheet appears; see [Passwords](#passwords-and-the-keychain). If the connection fails, the panel explains why and offers **Reconnect**.

## The launcher

The launcher window (⌘0) lists:

- **Recent** computers you've connected to, newest first, each with a thumbnail of its screen from the last session.
- **Nearby** computers advertising VNC or Screen Sharing over Bonjour on your local network.

Right-click a computer for **Connect**, **Edit…**, **Duplicate**, **Wake Computer** (if it has a MAC address) and **Delete**. Deleting also removes its saved password from the Keychain. Use the search field to filter, and **+** or ⌘N to add a computer with specific settings.

Every computer you connect to is remembered automatically. Settings you change during a session are saved with it: scaling mode, view only, local cursor, and the display you chose.

## Passwords and the Keychain

vncx supports three kinds of login:

- **macOS account (Apple Remote Desktop authentication).** macOS Screen Sharing asks for the name and password of a user account on the remote Mac.
- **VNC password.** Most Linux and Windows servers ask for a single password.
- **None.** Some servers, for example WayVNC on a private network, don't ask at all.

When a server asks and vncx has no saved password, the login sheet appears. **Remember this password in my keychain** is on by default. Passwords are stored as generic Keychain items under the service `net.ahimsalabs.vncx`, keyed by `user@host:port` or by `host:port` for VNC passwords.

If a login fails, the next attempt asks again, ignoring the saved password, and tells you the previous attempt failed. A successful login with **Remember** on replaces the saved password.

You can also save a password ahead of time in the connection editor (Edit…).

## The session window

Each session is a standard Mac window. It supports full screen (⌃⌘F or the green button; the toolbar becomes a floating bar there, see Settings › Display), tabs (Window › Merge All Windows), Stage Manager, and dark mode. The title shows the remote desktop name. The subtitle shows the resolution, current bandwidth, zoom level, and **View Only** when that's on.

Toolbar items:

| Item | What it does |
|---|---|
| **Displays** | Appears for multi-monitor remotes; see [Multiple displays](#multiple-displays). |
| **Scaling** | Switches between Scale to Fit, Fill Width, Fill Height, Actual Size and Resize Remote. |
| **View Only** | Stops sending keyboard and mouse input, for watching without risk. |
| **Send Keys** | Control–Alt–Delete, Control–Alt–Backspace, Command–Tab, Command–Space, Command–Q, Escape, Print Screen, Type Clipboard Text, and Send Clipboard to Remote. |
| **Connection Stats** | Shows the [stats overlay](#picture-quality-and-connection-stats). |
| **Screenshot** | Saves the remote screen to your Desktop as a full-resolution PNG, or copies it. |

The **Session** menu has the same actions with keyboard shortcuts, plus **Refresh Screen** and **Disconnect / Reconnect**.

Closing the window disconnects. When the window first opens, it sizes itself to show the remote pixel for pixel, or fits it on your screen if it's larger.

## Scaling and zoom

| Mode | Shortcut | Behavior |
|---|---|---|
| **Scale to Fit** | ⌃⌘1 | The whole remote desktop fits the window. The window keeps the remote's aspect ratio as you resize it, so there are no black bars. When the fit is within a pixel or two of an exact 1:1 or 2:1 mapping, vncx snaps to it so text stays sharp. |
| **Fill Width** | ⌃⌘4 | The remote's width fills the window. If the remote is then taller than the window, moving the mouse pans up and down; if it's shorter, it's centered. The window can be any shape. |
| **Fill Height** | ⌃⌘5 | The remote's height fills the window, panning left and right when it's wider. Good for an ultrawide remote in a narrower window: full height, sharp, and you sweep across it with the mouse. |
| **Actual Size** | ⌃⌘2 | One remote pixel per screen pixel. If the remote is larger than the window, moving the mouse pans (see **Panning** below). |
| **Resize Remote** | ⌃⌘3 | The server changes its resolution to match your window, in points or in Retina pixels (a per-computer option). Needs a server that supports remote resizing, such as TigerVNC, WayVNC or ReFrame. It's disabled for multi-monitor remotes, where it would collapse the layout. |

**Zoom:** pinch on the trackpad to zoom from 1× to 8× on top of the current mode. A two-finger double tap toggles between unzoomed and 1:1 device pixels, or 2× if you're already at that. ⌃⌘= and ⌃⌘- zoom in and out, and ⌃⌘0 resets. Pinching keeps the point under the pointer where it is. While zoomed, moving the mouse pans the view the same way as Actual Size and the fill modes.

**Panning:** when the picture is larger than the window, it stays still while you work and only moves when you push the pointer toward an edge. Each edge has a band (a fifth of the window, up to 240 points). Moving toward the edge inside the band scrolls the remote that way, and the remote's edge is fully in view a little before the pointer reaches the window's edge. Moving back out of the band leaves the view where it is, so you can work near the remote's edge without holding the pointer against it.

**Smooth scaling** (Settings › Display, on by default) filters the image when it's scaled. Integer zoom levels always stay pixel-sharp. Downscaling averages each output pixel's whole footprint, so a 5K desktop in a small window stays legible instead of shimmering.

## Multiple displays

When a server reports several screens, a **Displays** toolbar menu appears, also under Session › Displays. Servers that do this include WayVNC with `--desktop` and TigerVNC with multiple heads. The menu offers:

- **All Displays** shows the whole desktop in one window.
- **Display 1, Display 2, …** shows just that monitor. Displays are numbered left to right, then top to bottom, whatever order the server lists them in. Your choice is remembered per computer and restored next time.
- **Open Each Display in Its Own Window** keeps your chosen display in the main window and opens a window for each of the others. Every window is a full view with its own scaling and zoom, and they all share one connection.
- **Full Screen on All My Displays** does the same, then moves each window to a different Mac display, left to right, and makes it full screen.
- **Show All Displays in One Window** closes the extra windows and goes back to the whole desktop.

The pointer can't stray outside the display a window shows. Closing an extra display window leaves the session connected; closing the main window ends it.

Servers that show one monitor at a time can't offer this. This includes WayVNC without `--desktop` and ReFrame, which runs one instance per monitor. See [server notes](servers.md).

## Keyboard

Keys are sent as X11 keysyms, the standard for VNC. Your Mac's modifiers map like this:

| Mac key | Sent as |
|---|---|
| Shift, Control | Shift, Control |
| Option | Alt |
| Command | Super (the Windows key), by default. Change it under Settings › General › **Command key sends**: Super, Meta, Control or Alt. |
| Caps Lock | Caps Lock (toggles stay in sync) |

**Command shortcuts** (⌘C, ⌘W, ⌘Tab with capture, …) go to the remote computer when **Send ⌘ shortcuts to the remote computer** is on, which is the default. These always stay with vncx:

- every ⌃⌘ shortcut (vncx's own Session menu and ⌃⌘F full screen)
- ⌘Q and ⌘H

**Full keyboard capture** (Settings › General › **Capture system shortcuts**) also takes system shortcuts away from macOS and sends them to the remote: ⌘Tab, ⌘Space, ⌃-arrows, Mission Control, and keys like F3. The options are **Never**, **In Full Screen** (the default) and **Always**. It needs the Accessibility permission. macOS asks the first time capture is needed, and Settings has a button that opens the right pane. Some shortcuts can't be captured by any app, such as ⌘⌥Esc.

**Special keys** that a Mac keyboard lacks are in the **Send Keys** toolbar menu, for example Control–Alt–Delete (also ⌃⌘⌫) and Print Screen.

**Type Clipboard Text** (⌃⌘V) types your Mac clipboard on the remote as keystrokes. That's useful for login screens and password fields that don't accept a paste.

Keys are released automatically when the window loses focus, so modifiers never get stuck on the remote.

## Mouse, trackpad and cursor

- Left, right and middle buttons work as expected. Clicking an inactive vncx window also clicks the remote; the first click isn't swallowed.
- Two-finger scrolling and mouse wheels scroll the remote. Trackpad scrolling is accumulated, so slow swipes still scroll, and it follows your natural scrolling setting.
- Pinch zooms the view; see [Scaling and zoom](#scaling-and-zoom).

**Cursor:** when the server sends cursor shapes, vncx draws the remote cursor locally at the right size for the current scale. That includes resize arrows, text beams and the rest, with no network lag. TigerVNC's antialiased cursors keep their smooth edges and shadows. If the server hides its cursor, vncx shows a small dot so you never lose the pointer.

Some servers never send cursor shapes. macOS Screen Sharing doesn't, and neither does WayVNC on some compositors. For those, set **Local cursor** per computer, in the editor or the Session menu:

- **Arrow** (the default): a normal Mac arrow.
- **Dot:** a small dot. Pick this if the server draws its own cursor into the picture.
- **Hidden:** no local cursor. Use this when the server draws its cursor and you only want to see that one.

## Clipboard, drag and drop

**Clipboard sync** (Settings › General, on by default) works both ways:

- When the remote copies something, it lands on your Mac clipboard.
- When you switch to a vncx window, your Mac clipboard is offered to the remote.

With servers that support the extended clipboard, such as TigerVNC, WayVNC and other neatvnc-based servers, text is full Unicode: emoji, CJK, accents. Other servers only carry Latin-1 text, the classic VNC limit.

**Send Clipboard to Remote** (Session menu) pushes the clipboard on demand.

**Drag text** onto a session window to paste it there. vncx puts the text on the remote clipboard, then sends the paste shortcut. Pick the shortcut per computer under **Paste dropped text with**:

- **Automatic:** ⌘V for Mac servers, Ctrl+V elsewhere.
- **Ctrl+V,** **Command+V,** **Ctrl+Shift+V** (most Linux terminals), or **Shift+Insert.**

Hold ⌥ while dropping to type the text key by key instead. Typing only covers characters the remote keyboard layout has.

**Drag files** onto a session window to upload them over SSH, into `~/Downloads` on the remote by default. This needs [SSH](#ssh) configured for that computer, because VNC itself has no standard file transfer. A banner at the bottom of the window shows progress and the result.

## Picture quality and connection stats

**Picture quality** (per computer, and a default in Settings › Display):

| Setting | Behavior |
|---|---|
| **Automatic** (default) | Measures the link while it works. Lossless on fast, low-latency links; switches to JPEG (quality 8, then 4) as the link slows or latency rises, and back again. Changes are smoothed: it downgrades after about 3 seconds of evidence and upgrades after about 6, so it doesn't flap. |
| **Best (lossless)** | Always lossless (ZRLE or Tight without JPEG). |
| **Balanced** | Tight with JPEG quality 8. |
| **Low bandwidth** | Tight with JPEG quality 4 and stronger compression. |

JPEG only applies to servers that support Tight encoding. macOS Screen Sharing doesn't, so it's always lossless there.

**Bandwidth limit** (per computer) caps how fast the server sends. Servers that support continuous updates otherwise send every change as soon as it happens, so a video on the remote can fill your link even at Low bandwidth. Under a limit, vncx asks for each update itself and paces the requests: an allowance refills at the limit, up to one second's worth, and each update spends its size. When the allowance runs out, the next request waits for it to refill, but never more than 1.5 seconds, so a limit can be exceeded when single updates are very large (a full-screen video frame on a 5K remote at a 5 Mbit/s limit). Small updates such as typing and pointer movement go out at once, an occasional big update after a quiet spell doesn't wait at all, and sustained video drops to the frame rate that fits.

Large updates are drawn as they stream in rather than when the last part arrives, so a full refresh fills in progressively on a slow link.

When vncx knows it's waiting, a small indicator appears in the bottom-left corner: **Waiting for *computer*…** when a latency check has gone unanswered for over a second (the server or network has stalled), **Receiving…** with the size so far when one update has been streaming in for over 0.4 seconds, and **Bandwidth limit** when the limit has held the next request back for over 0.4 seconds. A remote screen that simply isn't changing shows nothing.

| Setting | Behavior |
|---|---|
| **Automatic** (default) | No limit until latency shows the connection queueing (more than 40 ms over its baseline), then about 70% of the recent throughput. It rises again by 15% steps while latency stays low and the limit is what holds throughput back, up to the measured link speed. Needs a server with fences (WayVNC, TigerVNC, ReFrame). |
| **Unlimited** | Continuous updates whenever the server supports them. |
| **50, 20, 10 or 5 Mbit/s** | A fixed limit. |

**Connection stats** (⌃⌘I, or the gauge button) shows an overlay in the corner:

| Row | Meaning |
|---|---|
| Screen | The remote resolution. |
| Frames | Updates per second, and whether the server **pushes** updates (continuous updates), vncx **polls** for them, or vncx polls **paced** by a bandwidth limit. |
| Received | Current bandwidth. |
| Limit | The bandwidth limit in force, or none. |
| Link | Estimated link speed, measured while large updates stream in. |
| Latency | Round-trip time measured with protocol fences, on servers that support them. |
| Encoding | Share of data by encoding over the last second. |
| Quality | The current picture-quality level. |

## Staying connected

- **Dropped connections** retry automatically with increasing delays (1, 2, 3, 5, 8, 13, 20 and then 30 seconds) for up to 30 attempts. A **Reconnecting…** panel shows the reason, with **Stop** and **Retry Now**.
- **Credentials** from the last successful login are kept in memory for the session, so reconnects never prompt.
- **After sleep or a network change** (Wi-Fi to Ethernet, VPN on or off), vncx asks each server for a full frame. If nothing arrives within a few seconds, it reconnects.
- **Login failures don't retry.** vncx asks for the password again instead.

## SSH

Each computer can use SSH, set up under Edit… › SSH. vncx runs the system `/usr/bin/ssh`, so your `~/.ssh/config`, host aliases, keys, agents (including 1Password and Secretive), ProxyJump and the rest all apply. Login must work without a prompt, because vncx can't type an SSH password or accept a new host key. Connect once in Terminal first if the host is new.

| Setting | Purpose |
|---|---|
| **Destination** | `host`, `user@host` or an `~/.ssh/config` alias. Empty means the VNC host. |
| **Tunnel the VNC connection through SSH** | Forwards VNC over SSH (`ssh -L`) to **Forward to** (default `localhost`) on the far side. Use it for servers that only listen on localhost, or for encryption without a VPN. The tunnel closes with the session, even if vncx crashes. |
| **Start server if it isn't running** | A shell command run over SSH when the VNC server refuses the connection. vncx runs it once, waits, and retries. `{port}` is replaced by the VNC port. Commands run under POSIX `sh` on the remote, whatever your login shell is (fish, zsh, …). |
| **Presets** | **WayVNC (all displays)** starts `wayvnc --desktop` in your Wayland session if it isn't running. **TigerVNC** runs `vncserver` for the display matching the port. |
| **Upload dropped files to** | Folder, relative to your remote home directory, for [dropped files](#clipboard-drag-and-drop). Default `Downloads`; created if missing. |
| **Test SSH** | Runs `uname -sn` on the destination and shows the result or the error. |

## Wake-on-LAN

Set a **MAC address** in Edit… › Wake-on-LAN. When a connection to that computer fails before the handshake, vncx sends a wake packet and keeps retrying for up to two minutes. The panel shows **Waking…** meanwhile. You can also wake a computer from the launcher's context menu.

Wake packets are broadcasts, so they only reach the sleeping computer's local network. They don't cross routers, Tailscale or VPNs. If you're not on the same network, set **Send from (SSH)** to an always-on machine on that network, such as a Raspberry Pi or a NAS. vncx asks it to send the packet with `python3`, `wakeonlan` or `etherwake`, whichever it has. **Broadcast address** can be a directed broadcast such as `192.168.1.255` when the default doesn't work.

## Menu bar

The menu bar item (a display icon) lists:

- **Open** sessions; click one to bring its window forward.
- Recent **Computers**; click to connect.
- **Nearby** Bonjour computers.
- **Connect to Address…**, **Show Computers**, **Settings…** and **Quit**.

Turn it off under Settings › General › **Show vncx in the menu bar**.

## Settings reference

Open with ⌘,.

**General**

| Setting | Default | Notes |
|---|---|---|
| Command key sends | Super | Super, Meta, Control or Alt. |
| Send ⌘ shortcuts to the remote computer | On | ⌘Q, ⌘H and ⌃⌘ shortcuts always stay local. |
| Capture system shortcuts | In Full Screen | Never, In Full Screen, or Always. Needs Accessibility permission. |
| Share clipboard with the remote computer | On | Both directions. |
| Show vncx in the menu bar | On | |

**Display**

| Setting | Default | Notes |
|---|---|---|
| Smooth scaling | On | Off uses nearest-neighbor everywhere. |
| Default scaling | Scale to Fit | For new computers. |
| Default picture quality | Automatic | For new computers. |
| Toolbar in full screen | Floating Bar | **Floating Bar** keeps the Mac's menu bar and Dock hidden, so the pointer reaches the remote's edges and corners (its menu bar, Dock and hot corners) instead of revealing the Mac's. A small tab at the top center opens into the controls, with an Exit Full Screen button, while the pointer is over it; ⌃⌘ shortcuts keep working. **Hide with Menu Bar** shows the toolbar with the Mac's menu bar when the pointer reaches the top of the screen. **Always Show** keeps the toolbar on screen. |

## Connection settings reference

Edit… on a computer, or **+** in the launcher.

| Section | Setting | Notes |
|---|---|---|
| General | Name | Optional display name. |
| | Address | Any [address format](#connecting). Fixed for Bonjour computers. |
| | User name | For macOS Screen Sharing logins. |
| | Password | Saved to the Keychain. Leave empty to be asked. |
| Wake-on-LAN | MAC address, Broadcast address, Send from (SSH) | See [Wake-on-LAN](#wake-on-lan). |
| SSH | Use SSH, Destination, Tunnel, Forward to, Start server…, Upload dropped files to, Test SSH | See [SSH](#ssh). |
| Display | Scaling | Scale to Fit, Fill Width, Fill Height, Actual Size or Resize Remote. |
| | Use Retina resolution when resizing remote | Resize Remote asks for pixels instead of points. |
| | Picture quality | Automatic, Best, Balanced or Low bandwidth. |
| | Bandwidth limit | Automatic, Unlimited, or 50, 20, 10 or 5 Mbit/s. |
| | View only | Start sessions in view-only mode. |
| | Paste dropped text with | Automatic, Ctrl+V, Command+V, Ctrl+Shift+V or Shift+Insert. |
| | Local cursor | Arrow, Dot or Hidden, for servers without cursor shapes. |

## Keyboard shortcuts

App and launcher:

| Shortcut | Action |
|---|---|
| ⌘N | New connection |
| ⌘K | Connect to address |
| ⌘0 | Show computers (launcher) |
| ⌘, | Settings |

Session. These all use ⌃⌘, so they never collide with shortcuts sent to the remote:

| Shortcut | Action |
|---|---|
| ⌃⌘1 / ⌃⌘2 / ⌃⌘3 | Scale to Fit / Actual Size / Resize Remote |
| ⌃⌘4 / ⌃⌘5 | Fill Width / Fill Height |
| ⌃⌘= / ⌃⌘- / ⌃⌘0 | Zoom in / out / reset |
| ⌃⌘O | View only |
| ⌃⌘⌫ | Send Control–Alt–Delete |
| ⌃⌘V | Type clipboard text |
| ⌃⌘I | Connection stats |
| ⌃⌘S | Save screenshot to Desktop |
| ⌃⌘R | Refresh screen |
| ⌃⌘D | Disconnect / reconnect |
| ⌃⌘F | Full screen |

Trackpad:

| Gesture | Action |
|---|---|
| Pinch | Zoom |
| Two-finger double tap | Toggle zoom |
| Two-finger scroll | Scroll the remote |

## Troubleshooting

**"Connection refused."** Nothing is listening on that port. Check that the VNC server or Screen Sharing is running and the port is right (`host:1` means 5901). To have vncx start the server for you, set up [SSH](#ssh) with a start command.

**macOS asks "vncx wants to use your confidential information stored in…".** That's the Keychain asking whether vncx may read its saved password. Click **Always Allow**. Ad-hoc builds ask again after every rebuild.

**Shortcuts like ⌘Tab go to my Mac, not the remote.** Turn on **Capture system shortcuts**, which applies in full screen by default, and grant Accessibility permission in System Settings › Privacy & Security › Accessibility.

**The cursor doesn't change shape (no resize arrows).** The server doesn't send cursor shapes; see [server notes](servers.md). If it draws the cursor into the picture, set **Local cursor** to Hidden or Dot.

**Window-manager shortcuts (Super+arrows) do nothing on a niri desktop.** That's a niri limitation with WayVNC; see [server notes](servers.md#wayvnc).

**Emoji or accented text arrives as `?` on the remote.** The server doesn't support the extended clipboard, so only Latin-1 text can be sent. Dropping text falls back to typing it, which works for characters on the remote's keyboard layout.

**SSH says "Permission denied" or "Host key verification failed".** vncx can't answer SSH prompts. Load your key into the agent, or connect once with `ssh` in Terminal to accept the host key.
