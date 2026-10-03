#!/bin/sh
# Copyright 2026 Ahimsa Labs
# SPDX-License-Identifier: Apache-2.0
# Starts Xtigervnc and a few X clients so there's something to look at.
GEOMETRY="${GEOMETRY:-2560x1440}"
Xtigervnc :0 -rfbport 5900 -geometry "$GEOMETRY" -depth 24 -rfbauth /root/.vnc/passwd \
  -AlwaysShared -localhost=0 -SecurityTypes VncAuth -AcceptSetDesktopSize=1 &
export DISPLAY=:0
for i in $(seq 1 50); do xsetroot -solid steelblue 2>/dev/null && break; sleep 0.1; done
xclock -update 1 -geometry 300x300+40+40 &
xlogo -geometry 300x300+40+400 &
xterm -geometry 100x30+400+100 -fa DejaVu -fs 14 -e sh -c 'while true; do date; ls -la /usr/bin | head -20; sleep 1; done' &
wait
