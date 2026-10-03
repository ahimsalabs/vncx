# Copyright 2026 Ahimsa Labs
# SPDX-License-Identifier: Apache-2.0

# Minimal Linux VNC server for exercising VNC password auth and the Tight/ZRLE/Hextile/... decoders.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-common tigervnc-tools x11-xserver-utils x11-apps xterm xclip fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /root/.vnc && printf 'testpass\n' | vncpasswd -f > /root/.vnc/passwd && chmod 600 /root/.vnc/passwd
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 5900
ENTRYPOINT ["/entrypoint.sh"]
