#!/bin/bash
# Build Shepherd.app and install it to /Applications.
# Requires: Xcode Command Line Tools (swiftc). No other dependencies.
set -eu
cd "$(dirname "$0")"

swiftc -O -swift-version 5 -framework AppKit -framework IOKit -framework ApplicationServices -framework UserNotifications Sources/*.swift -o Shepherd

APP="build/Shepherd.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
mv Shepherd "$APP/Contents/MacOS/Shepherd"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Background-less brand mark (transparent PNG) used for the in-UI logo (toolbar + empty state).
# The .icns squircle has a dark ground + margins that read as a white/haze halo at 20px, so the
# HUD uses this flat mark instead — see 修正1 / markIcon.
if [ -f assets/mark.png ]; then
  cp assets/mark.png "$APP/Contents/Resources/mark.png"
fi
# Sign with a stable self-signed "shepherd-dev" identity when one exists in the keychain, so the
# binary's code signature (and thus its TCC identity) stays constant across rebuilds — otherwise
# ad-hoc (`-s -`) re-signs with a fresh identity every build and macOS re-prompts for Automation /
# Accessibility permission each time.
#
# We try to sign with "shepherd-dev" directly and only fall back to ad-hoc if that fails, rather
# than gating on `security find-identity -p codesigning -v`: the `-v` flag lists only *valid*
# identities, which excludes an untrusted self-signed cert — but codesign can (and should) still
# sign with it. Trust is about whether *others* accept the signature; it is irrelevant to local
# signing and to TCC's identity match, both of which key on the (stable) leaf-cert identity.
if codesign --force --deep --sign "shepherd-dev" "$APP" 2>/dev/null; then
  echo "signed: shepherd-dev"
else
  codesign --force --deep -s - "$APP" 2>/dev/null || true
  echo "signed: ad-hoc (create a 'shepherd-dev' codesigning cert to keep TCC grants across builds)"
fi

if [ "${1:-install}" != "--no-install" ]; then
  DEST="/Applications/Shepherd.app"
  rm -rf "$DEST"
  cp -R "$APP" /Applications/
  echo "installed: $DEST"
  # Shepherd needs no hook: it reads Claude Code's own files. hooks/uninstall.sh removes the one
  # older versions installed — run it once if you are upgrading.
else
  echo "built: $(pwd)/$APP"
fi
