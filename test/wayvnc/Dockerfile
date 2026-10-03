# Headless sway + WayVNC in --desktop mode with two outputs, for testing multi-screen layouts,
# cursor shapes, and clipboard against a modern neatvnc server. Arch ships current wayvnc (0.10+).
# amd64 only (Arch has no arm64 image); runs under emulation on Apple Silicon.
FROM --platform=linux/amd64 archlinux:latest
RUN sed -i "s/^\[options\]/[options]\nDisableSandbox/" /etc/pacman.conf && pacman -Syu --noconfirm sway wayvnc foot wl-clipboard ttf-dejavu libcap && setcap -r /usr/bin/sway && pacman -Scc --noconfirm
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && useradd -m tester
USER tester
EXPOSE 5900
ENTRYPOINT ["/entrypoint.sh"]
