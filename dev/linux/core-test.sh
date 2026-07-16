#!/bin/bash
# Build and run the test suite on Linux (inside the shepherd-linux-dev container):
#
#   docker run --rm -v "$PWD":/work shepherd-linux-dev bash dev/linux/core-test.sh
#
# Mirrors ./test.sh, minus the pieces that are macOS-only by design:
#   - Components.swift  (AppKit drawing — the Linux UI is a separate, future layer)
#   - StreamDeck.swift  (IOKit HID — hidapi port is a separate, future adapter)
# Everything else — the portable core — must compile and pass here unmodified.
set -eu
cd "$(dirname "$0")/../.."

SRCS=$(ls Sources/*.swift | grep -v \
  -e '^Sources/main\.swift$' \
  -e '^Sources/AppDelegate+' \
  -e '^Sources/Components\.swift$' \
  -e '^Sources/StreamDeck\.swift$')
OUT=build-linux
mkdir -p "$OUT"
# shellcheck disable=SC2086
swiftc -swift-version 5 $SRCS Tests/*.swift -o "$OUT/shepherd-tests"
exec "./$OUT/shepherd-tests"
