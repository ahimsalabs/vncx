#!/bin/sh
# Two headless outputs of different sizes, side by side, with a terminal on each.
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p -m 700 $XDG_RUNTIME_DIR
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
mkdir -p ~/.config/sway
cat > ~/.config/sway/config <<CFG
output HEADLESS-1 mode 1600x1000 position 0 0 bg #4682b4 solid_color
output HEADLESS-2 mode 1280x800 position 1600 0 bg #b46846 solid_color
exec foot -e sh -c 'while true; do date; sleep 1; done'
CFG
sway &
for i in $(seq 1 50); do [ -n "$(ls $XDG_RUNTIME_DIR | grep wayland)" ] && break; sleep 0.2; done
export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]*$')
swaymsg create_output >/dev/null
sleep 1
swaymsg 'output HEADLESS-2 mode 1280x800 position 1600 0 bg #b46846 solid_color' >/dev/null
swaymsg 'focus output HEADLESS-2; exec foot' >/dev/null
exec wayvnc ${WAYVNC_ARGS:---desktop} 0.0.0.0 5900
