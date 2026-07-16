# Linux build/verify environment for the Shepherd port (see CLAUDE.md "Linux 開発環境").
# - swift:noble        … Swift toolchain on Ubuntu 24.04 (arm64/amd64)
# - sway + grim        … headless wlroots compositor + screenshot for machine-checking
#                        the layer-shell overlay (WLR_BACKENDS=headless)
# - gtk4-layer-shell   … built from source: Ubuntu noble only packages the GTK3
#                        gtk-layer-shell; the GTK4 one enters the archive at 24.10.
FROM swift:noble

ENV DEBIAN_FRONTEND=noninteractive

# ports.ubuntu.com has outages; pass e.g.
#   --build-arg UBUNTU_MIRROR=http://ftp.tsukuba.wide.ad.jp/Linux/ubuntu-ports
# to build through a mirror. Default keeps the canonical host.
ARG UBUNTU_MIRROR=""
RUN if [ -n "$UBUNTU_MIRROR" ]; then \
        sed -i "s|http://ports.ubuntu.com/ubuntu-ports|$UBUNTU_MIRROR|" /etc/apt/sources.list.d/ubuntu.sources; \
    fi
# foot + jq only serve dev/linux/jump-verify.sh (a real terminal window to
# focus, and JSON parsing of `swaymsg -t get_tree`).
RUN apt-get update && apt-get install -y --no-install-recommends \
        sway grim foot jq \
        libgtk-4-dev libwayland-dev wayland-protocols \
        meson ninja-build pkg-config git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# -Dlibdir=lib keeps the .so out of the multiarch dir so one PKG_CONFIG_PATH works
# on both arm64 and amd64.
RUN git clone --depth 1 https://github.com/wmww/gtk4-layer-shell /tmp/g4ls \
    && meson setup /tmp/g4ls/build /tmp/g4ls --prefix=/usr/local -Dlibdir=lib \
         -Dintrospection=false -Dvapi=false -Dexamples=false -Ddocs=false -Dtests=false \
    && ninja -C /tmp/g4ls/build install \
    && rm -rf /tmp/g4ls
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
ENV LD_LIBRARY_PATH=/usr/local/lib

# sway refuses to start as root; everything runs as an unprivileged user.
# swift:noble ships an "ubuntu" user already holding uid 1000 — replace it.
RUN userdel -r ubuntu 2>/dev/null; useradd -m -u 1000 dev
USER dev
ENV XDG_RUNTIME_DIR=/tmp/xdg-dev
RUN mkdir -p /tmp/xdg-dev && chmod 700 /tmp/xdg-dev

WORKDIR /work
