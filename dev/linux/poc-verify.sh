#!/usr/bin/env bash
# Machine-verifies the layer-shell PoC (linux/poc-layershell) inside the
# shepherd-linux-dev container: start a headless sway, run the PoC overlay,
# screenshot with grim, and check the image for the PoC's solid #FF00FF fill.
#
#   docker run --rm -v "$PWD":/work shepherd-linux-dev bash dev/linux/poc-verify.sh
set -euo pipefail

cd "$(cd "$(dirname "$0")/../.." && pwd)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-dev}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== swift build =="
swift build --package-path linux/poc-layershell --scratch-path .build-linux

echo "== start headless sway =="
# pixman: software renderer — the container has no GPU/EGL.
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  sway -c /dev/null >/tmp/sway.log 2>&1 &
SWAY_PID=$!

POC_PID=""
cleanup() {
  [ -n "$POC_PID" ] && kill "$POC_PID" 2>/dev/null || true
  kill "$SWAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

WAYLAND_DISPLAY=""
for _ in $(seq 1 50); do
  for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [ -S "$sock" ]; then
      WAYLAND_DISPLAY="$(basename "$sock")"
      break
    fi
  done
  if [ -n "$WAYLAND_DISPLAY" ]; then
    break
  fi
  sleep 0.2
done
if [ -z "$WAYLAND_DISPLAY" ]; then
  echo "FAIL: sway did not create a wayland socket"
  tail -40 /tmp/sway.log || true
  exit 1
fi
export WAYLAND_DISPLAY
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

echo "== run PoC overlay =="
# cairo: keep GTK off the GL path for the same no-GPU reason.
GDK_BACKEND=wayland GSK_RENDERER=cairo \
  .build-linux/debug/poc >/tmp/poc.log 2>&1 &
POC_PID=$!

sleep 5

echo "== capture =="
grim -t ppm /tmp/poc.ppm

# PPM(P6) is header + raw RGB bytes. No Python/ImageMagick in the image, so
# hex-dump and look for a run of >=3 consecutive #FF00FF pixels — a run can
# only come from a solid magenta region, whatever the byte alignment.
if od -An -v -tx1 /tmp/poc.ppm | tr -d ' \n' | grep -q 'ff00ffff00ffff00ff'; then
  echo "PASS: overlay rendered"
else
  echo "FAIL: no #FF00FF run found in the grim capture"
  echo "-- poc.log --"
  cat /tmp/poc.log || true
  echo "-- sway.log --"
  tail -20 /tmp/sway.log || true
  exit 1
fi
