# Features and protocol support

vncx implements the client side of the Remote Framebuffer protocol (RFB, "VNC"), as specified in the [community RFB specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst). The protocol code is in `Sources/VNCCore`. It has no UI dependencies and is shared by the app, the `vncx-probe` tool and the unit tests.

## Protocol versions

| Version | Support |
|---|---|
| RFB 3.3 | Supported |
| RFB 3.7 | Supported |
| RFB 3.8 | Supported (preferred) |
| RFB 3.889 (Apple) | Recognized. vncx answers with 3.8, so Apple's private extensions stay off. |

## Security types

| Type | Name | Support |
|---|---|---|
| 1 | None | Supported |
| 2 | VNC authentication | Supported (DES challenge-response) |
| 30 | Apple Remote Desktop (Diffie-Hellman) | Supported: macOS account name and password, AES-128 encrypted with an MD5-derived key from a Diffie-Hellman exchange |
| 5, 6, 13 | RSA-AES (RealVNC "RA2" family) | Not supported |
| 16 | Tight | Not supported |
| 19 | VeNCrypt (TLS, X.509) | Not supported |
| 33, 35, 36 | Apple's newer types | Not supported |
| 129, 130, 133 | RSA-AES-256 (neatvnc, TigerVNC) | Not supported |

When several types are offered, vncx picks None first. Otherwise it picks Apple authentication if a user name is set or VNC authentication isn't offered, then VNC authentication. The Diffie-Hellman arithmetic uses a small Montgomery-multiplication bignum implementation. It's checked against Python's `pow()` and against a simulated server in the unit tests.

## Pixel format

vncx always asks for 32 bits per pixel, depth 24, little-endian true color with red, green and blue at shifts 16, 8 and 0 (BGRX in memory). That's the same layout as the Metal texture, so decoded pixels are drawn without conversion.

## Encodings

| # | Encoding | Support | Notes |
|---|---|---|---|
| 0 | Raw | Yes | |
| 1 | CopyRect | Yes | Handles overlapping copies in either direction. |
| 2 | RRE | Yes | |
| 5 | Hextile | Yes | |
| 6 | Zlib | Yes | One persistent zlib stream. |
| 7 | Tight | Yes | Fill, JPEG (decoded with ImageIO), and basic compression with copy, palette (1-bit and 8-bit) and gradient filters across four zlib streams. Tight PNG isn't requested. |
| 16 | ZRLE | Yes | Raw, solid, packed palette, plain RLE and palette RLE tiles. |

Preference order depends on the picture-quality level. Lossless puts ZRLE before Tight; the JPEG levels put Tight first. CopyRect always comes first.

## Pseudo-encodings

| # | Name | Support | Used for |
|---|---|---|---|
| -239 | Cursor | Yes | Local cursor rendering. An empty cursor shows a dot. |
| -314 | Cursor With Alpha | Yes (Raw sub-encoding) | Antialiased cursors from TigerVNC. Preferred over -239. |
| -223 | DesktopSize | Yes | Remote resolution changes. |
| -308 | ExtendedDesktopSize | Yes | Screen layouts (multiple displays) and client-requested resizing (SetDesktopSize). |
| -224 | LastRect | Yes | |
| -307 | DesktopName | Yes | Window title updates. |
| -312 | Fence | Yes | Server fences are answered; client fences measure round-trip time. |
| -313 | ContinuousUpdates | Yes | Server-pushed updates without a request per frame. |
| 0xC0A1E5CE | Extended Clipboard | Yes (text) | UTF-8 clipboard with caps, notify, request, peek and provide. |
| -23 … -32 | JPEG quality level | Yes | Sent for the Balanced (8) and Low bandwidth (4) levels. |
| -247 … -256 | Compression level | Yes | 1 for lossless, 2 for Balanced, 6 for Low bandwidth. |
| -258 | QEMU Extended Key Event | No | |
| -316 | ExtendedMouseButtons | No | |
| -412 … -512, -763 … -768 | Fine-grained JPEG quality, JPEG subsampling | No | |

## Client-to-server messages

| # | Message | Support |
|---|---|---|
| 0 | SetPixelFormat | Yes |
| 2 | SetEncodings | Yes, re-sent when automatic quality changes level. |
| 3 | FramebufferUpdateRequest | Yes. Incremental after each update, or none at all once continuous updates are on. |
| 4 | KeyEvent | Yes (X11 keysyms) |
| 5 | PointerEvent | Yes: buttons 1 to 3, and wheel buttons 4 to 7 for vertical and horizontal scrolling. |
| 6 | ClientCutText | Yes, Latin-1 or extended. |
| 150 | EnableContinuousUpdates | Yes, sent when the server shows support, and again after a resize. |
| 248 | ClientFence | Yes |
| 251 | SetDesktopSize | Yes (Resize Remote mode) |

## Server-to-client messages

| # | Message | Support |
|---|---|---|
| 0 | FramebufferUpdate | Yes |
| 1 | SetColourMapEntries | Read and ignored (true color only) |
| 2 | Bell | Plays the system alert sound. |
| 3 | ServerCutText | Yes, Latin-1 or extended. |
| 150 | EndOfContinuousUpdates | Yes. The first one means "supported"; later ones mean the server stopped pushing. |
| 248 | ServerFence | Yes |

## Measurements

The client records, per update:

- bytes received
- time taken
- rectangles and bytes per encoding

The link rate is estimated from large updates, over 48 KB, as bytes divided by elapsed time, smoothed. Round-trip time comes from a fence with a timestamp payload, sent every 2 seconds when the server supports fences. When polling, the fence goes out just before the next update request instead, because WayVNC holds a fence reply behind an outstanding request until the screen changes. Automatic quality, the automatic bandwidth limit and the stats overlay use these numbers.

A bandwidth limit turns continuous updates off (EnableContinuousUpdates with enable 0, then polling once the server's EndOfContinuousUpdates arrives) and paces FramebufferUpdateRequests: after an update of B bytes, the next request goes out no sooner than B / limit (at most 1.5 s) after the previous one.

## Rendering

- The framebuffer is a shared-memory Metal buffer, with rows padded for linear-texture alignment. Decoders write straight into it, and a texture view on the same memory is drawn each frame, so nothing is copied or uploaded.
- One full-screen-triangle fragment shader handles all scaling:
  - **1:1 and integer upscales:** nearest-neighbor, pixel-exact.
  - **Other upscales:** bilinear.
  - **Downscales:** an n×n grid of bilinear taps (n up to 8) averaged over each output pixel's footprint, effectively a box filter.
- The drawable is sRGB-tagged and draws on demand. Updates from the network thread are coalesced to at most one redraw per display refresh.

## Threading

- **Protocol I/O** runs on a dedicated thread with blocking reads over a buffered `NWConnection`. Network.framework provides DNS (including MagicDNS), Bonjour endpoint resolution, IPv6 and keepalives.
- **Input from the main thread** (keys, pointer, clipboard) is sent directly. `NWConnection` keeps send order.
- **Events from the network thread** (connected, resized, cursor, clipboard, screens, disconnected) are delivered to the main thread.

## Beyond RFB

These features live in the app, not the protocol:

- **SSH:** tunnels (`ssh -L` under a wrapper that kills ssh when vncx exits), remote start commands run under `sh -s`, and `scp` uploads.
- **Wake-on-LAN:** UDP broadcast of the magic packet to ports 9 and 7, or the same through an SSH relay.
- **Bonjour:** discovery of `_rfb._tcp` services.
- **Keyboard capture:** a session CGEventTap.
