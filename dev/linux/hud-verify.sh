#!/usr/bin/env bash
# Machine-verifies the walking-skeleton Linux HUD (linux/hud) inside the
# shepherd-linux-dev container: stage a fake sessions-registry + transcript
# fixture, start a headless sway, run the HUD, screenshot with grim, and check
# that BOTH the working-green (#A6E3A1) and blocked-peach (#FAB387) status
# swatches rendered — i.e. the core's status→colour mapping reached the overlay
# through real data, not hardcoded pixels.
#
#   docker run --rm -v "$PWD":/work shepherd-linux-dev bash dev/linux/hud-verify.sh
set -euo pipefail

cd "$(cd "$(dirname "$0")/../.." && pwd)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-dev}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== build =="
bash dev/linux/hud-build.sh

echo "== stage fixture =="
FIX=/tmp/fixture
rm -rf "$FIX"
# cwd /tmp/fixture/proj sanitizes (Transcript.sanitizeCwd) to -tmp-fixture-proj.
PROJ_DIR="$FIX/projects/-tmp-fixture-proj"
mkdir -p "$FIX/sessions" "$PROJ_DIR"

# readSessionsRegistry drops entries whose pid is dead (kill(pid,0)), so back
# each fake session with a live throwaway process.
sleep 9999 & PID_WORKING=$!
sleep 9999 & PID_BLOCKED=$!
sleep 9999 & PID_IDLE=$!

HUD_PID=""
SWAY_PID=""
cleanup() {
  [ -n "$HUD_PID" ] && kill "$HUD_PID" 2>/dev/null || true
  [ -n "$SWAY_PID" ] && kill "$SWAY_PID" 2>/dev/null || true
  kill "$PID_WORKING" "$PID_BLOCKED" "$PID_IDLE" 2>/dev/null || true
}
trap cleanup EXIT

session_json() { # pid sessionId status [waitingFor]
  printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp/fixture/proj","kind":"interactive","name":"fx-%s","status":"%s"%s}\n' \
    "$1" "$2" "$3" "$3" "${4:+,\"waitingFor\":\"$4\"}"
}
session_json "$PID_WORKING" s-working busy              > "$FIX/sessions/$PID_WORKING.json"
session_json "$PID_BLOCKED" s-blocked waiting "permission prompt" > "$FIX/sessions/$PID_BLOCKED.json"
session_json "$PID_IDLE"    s-idle    idle              > "$FIX/sessions/$PID_IDLE.json"

# Transcripts: an ai-title line (card title) and a main-chain assistant usage
# line (model chip + context %), the same shapes Tests/TranscriptTests.swift uses.
cat > "$PROJ_DIR/s-working.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Fixture working session","sessionId":"s-working"}
{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":50000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}
EOF
cat > "$PROJ_DIR/s-blocked.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Fixture blocked session","sessionId":"s-blocked"}
{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":20000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":0}}}
EOF
cat > "$PROJ_DIR/s-idle.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Fixture idle session","sessionId":"s-idle"}
{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF

echo "== start headless sway =="
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  sway -c /dev/null >/tmp/sway.log 2>&1 &
SWAY_PID=$!

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

echo "== run HUD =="
SHEPHERD_SESSIONS_DIR="$FIX/sessions" SHEPHERD_PROJECTS_DIR="$FIX/projects" \
  GDK_BACKEND=wayland GSK_RENDERER=cairo \
  build-linux/shepherd-hud >/tmp/hud.log 2>&1 &
HUD_PID=$!

sleep 5

echo "== capture =="
grim -t ppm /tmp/hud.ppm

# Same PPM byte-run trick as poc-verify.sh: >=3 consecutive pixels of a colour
# can only come from a solid swatch, whatever the byte alignment.
HEX=$(od -An -v -tx1 /tmp/hud.ppm | tr -d ' \n')
PASS=1
if echo "$HEX" | grep -q 'a6e3a1a6e3a1a6e3a1'; then
  echo "  working green #A6E3A1: found"
else
  echo "  working green #A6E3A1: MISSING"
  PASS=0
fi
if echo "$HEX" | grep -q 'fab387fab387fab387'; then
  echo "  blocked peach #FAB387: found"
else
  echo "  blocked peach #FAB387: MISSING"
  PASS=0
fi

if [ "$PASS" = 1 ]; then
  echo "PASS: core data rendered on the overlay"
else
  echo "FAIL"
  echo "-- hud.log --"
  cat /tmp/hud.log || true
  echo "-- sway.log --"
  tail -20 /tmp/sway.log || true
  exit 1
fi
