#!/bin/bash
# Build the walking-skeleton Linux HUD (linux/hud/main.swift + the portable core)
# inside the shepherd-linux-dev container:
#
#   docker run --rm -v "$PWD":/work shepherd-linux-dev bash dev/linux/hud-build.sh
#
# Plain swiftc like build.sh / core-test.sh — no SwiftPM. The CGtkLayerShell
# module map from the PoC package is reused via -I.
set -eu
cd "$(dirname "$0")/../.."

# Portable core: same exclusion list as core-test.sh.
SRCS=$(ls Sources/*.swift | grep -v \
  -e '^Sources/main\.swift$' \
  -e '^Sources/AppDelegate+' \
  -e '^Sources/Components\.swift$' \
  -e '^Sources/StreamDeck\.swift$')

# pkg-config flags need routing: header flags to clang (-Xcc), and anything in
# --libs that isn't -l/-L (e.g. -pthread) to the linker — swiftc rejects both raw.
CC_FLAGS=""
for f in $(pkg-config --cflags gtk4-layer-shell-0); do
  CC_FLAGS="$CC_FLAGS -Xcc $f"
done
LD_FLAGS=""
# gtk4 explicitly too: gtk4-layer-shell-0.pc keeps it in Requires.private,
# so its --libs line alone never emits -lgtk-4.
for f in $(pkg-config --libs gtk4-layer-shell-0 gtk4); do
  case "$f" in
    -l*|-L*) LD_FLAGS="$LD_FLAGS $f" ;;
    *)       LD_FLAGS="$LD_FLAGS -Xlinker $f" ;;
  esac
done

OUT=build-linux
mkdir -p "$OUT"
# shellcheck disable=SC2086
swiftc -swift-version 5 $SRCS linux/hud/main.swift \
  -I linux/poc-layershell/Sources/CGtkLayerShell \
  $CC_FLAGS $LD_FLAGS \
  -o "$OUT/shepherd-hud"
echo "built $OUT/shepherd-hud"
