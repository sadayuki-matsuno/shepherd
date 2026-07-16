#!/usr/bin/env bash
# Machine-verifies the Linux HUD's card-click jump (linux/hud/main.swift:
# wireJumpGesture / jumpToSession): a claude session's pid resolves, through
# processTable's ppid chain, to the terminal window that owns it, and sway
# focuses that window.
#
# Headless sway has no pointer device to synthesize a real click with, so
# this exercises the exact same jumpToSession() the click handler calls, via
# the SHEPHERD_JUMP_SESSION=<sessionId> test hook (fires once, right after
# the first board render).
#
#   docker run --rm -v "$PWD":/work shepherd-linux-dev bash dev/linux/jump-verify.sh
set -euo pipefail

cd "$(cd "$(dirname "$0")/../.." && pwd)"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-dev}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== build =="
bash dev/linux/hud-build.sh

echo "== stage fixture =="
FIX=/tmp/fixture-jump
rm -rf "$FIX"
mkdir -p "$FIX/sessions"

# Same fake `claude` convention as hud-verify.sh.
mkdir -p "$HOME/.claude/local"
cat > "$HOME/.claude/local/claude" <<'EOF'
#!/bin/bash
case "$1" in
  agents) cat "$(dirname "${SHEPHERD_SESSIONS_DIR:-/nonexistent}")/agents.json" 2>/dev/null || echo '[]' ;;
  *)      echo '{}' ;;
esac
EOF
chmod +x "$HOME/.claude/local/claude"

mkdir -p "$FIX/proj"
git -C "$FIX/proj" init -q -b main
git -C "$FIX/proj" -c user.email=fx@example.com -c user.name=fx commit -q --allow-empty -m init

HUD_PID=""
SWAY_PID=""
FOOT1_PID=""
FOOT2_PID=""
cleanup() {
  [ -n "$HUD_PID" ] && kill "$HUD_PID" 2>/dev/null || true
  [ -n "$FOOT1_PID" ] && kill "$FOOT1_PID" 2>/dev/null || true
  [ -n "$FOOT2_PID" ] && kill "$FOOT2_PID" 2>/dev/null || true
  [ -n "$SWAY_PID" ] && kill "$SWAY_PID" 2>/dev/null || true
}
trap cleanup EXIT

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

# sway only puts SWAYSOCK in ITS OWN environment — processes it doesn't spawn
# (this script, and the swaymsg/foot it launches) never inherit it, unlike
# WAYLAND_DISPLAY which every client discovers via the socket file itself.
# Glob for the IPC socket sway creates next to it, the same way.
SWAYSOCK=""
for _ in $(seq 1 50); do
  for sock in "$XDG_RUNTIME_DIR"/sway-ipc.*.sock; do
    if [ -S "$sock" ]; then
      SWAYSOCK="$sock"
      break
    fi
  done
  if [ -n "$SWAYSOCK" ]; then
    break
  fi
  sleep 0.2
done
if [ -z "$SWAYSOCK" ]; then
  echo "FAIL: sway did not create an IPC socket"
  tail -40 /tmp/sway.log || true
  exit 1
fi
export SWAYSOCK
echo "SWAYSOCK=$SWAYSOCK"

# /proc-based child lookup — avoids depending on pgrep/procps being in the
# image, which the CLAUDE.md Linux notes flag as unverified.
children_of() {  # $1 = parent pid
  local parent="$1" p pid ppid
  for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    ppid="$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null || true)"
    [ "$ppid" = "$parent" ] && echo "$pid"
  done
}
wait_for_child() {  # $1 = parent pid -> prints the first child pid once one exists
  local parent="$1" child
  for _ in $(seq 1 50); do
    child="$(children_of "$parent" | head -1)"
    if [ -n "$child" ]; then echo "$child"; return 0; fi
    sleep 0.1
  done
  return 1
}

echo "== start two foot windows =="
# `sleep 9999 & wait` forces a real fork (backgrounding always forks,
# regardless of shell) so the claude-analogue pid is a genuine grandchild of
# the window pid — foot -> sh -> sleep — exercising the ancestor walk beyond
# a single hop.
foot -- sh -c 'sleep 9999 & wait' >/tmp/foot1.log 2>&1 &
FOOT1_PID=$!
foot -- sh -c 'sleep 9999 & wait' >/tmp/foot2.log 2>&1 &
FOOT2_PID=$!

SH1_PID="$(wait_for_child "$FOOT1_PID")" || { echo "FAIL: foot1's shell never started"; exit 1; }
SLEEP1_PID="$(wait_for_child "$SH1_PID")" || { echo "FAIL: foot1's sleep never started"; exit 1; }
echo "foot1: window pid=$FOOT1_PID sh pid=$SH1_PID sleep(session) pid=$SLEEP1_PID"

for _ in $(seq 1 50); do
  COUNT=$(swaymsg -t get_tree | jq '[.. | objects | select(.pid != null)] | length' 2>/dev/null || echo 0)
  [ "$COUNT" -ge 2 ] && break
  sleep 0.2
done
if [ "$COUNT" -lt 2 ]; then
  echo "FAIL: sway never saw both foot windows (COUNT=$COUNT)"
  swaymsg -t get_tree || true
  exit 1
fi

echo "== stage sessions registry (session pid = foot1's sleep) =="
MS_NOW=$(( $(date +%s) * 1000 ))
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","kind":"interactive","name":"%s","status":"%s","updatedAt":%s}\n' \
  "$SLEEP1_PID" "s-jump-target" "$FIX/proj" "s-jump-target" "busy" "$MS_NOW" \
  > "$FIX/sessions/$SLEEP1_PID.json"

cat > "$FIX/agents.json" <<EOF
[
  {"sessionId":"s-jump-target","id":"jt","kind":"interactive","pid":$SLEEP1_PID,"status":"busy","cwd":"$FIX/proj","startedAt":$MS_NOW}
]
EOF

PROJ_DIR="$FIX/projects/$(echo "$FIX/proj" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$PROJ_DIR"
cat > "$PROJ_DIR/s-jump-target.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Chasing the jump feature","sessionId":"s-jump-target"}
{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF

echo "== focus foot2 (so foot1 starts unfocused) =="
swaymsg "[pid=$FOOT2_PID] focus" >/dev/null

echo "== run HUD with SHEPHERD_JUMP_SESSION =="
export SHEPHERD_SESSIONS_DIR="$FIX/sessions" SHEPHERD_PROJECTS_DIR="$FIX/projects"
export SHEPHERD_JUMP_SESSION="s-jump-target"
GDK_BACKEND=wayland GSK_RENDERER=cairo \
  build-linux/shepherd-hud >/tmp/hud.log 2>&1 &
HUD_PID=$!

sleep 5

echo "== hud.log (jump line) =="
grep "SHEPHERD_JUMP_SESSION" /tmp/hud.log || true

PASS=1

if grep -q "SHEPHERD_JUMP_SESSION: session=s-jump-target pid=$SLEEP1_PID jump=true" /tmp/hud.log; then
  echo "  (a) jumpToSession reported success: found"
else
  echo "  (a) jumpToSession reported success: MISSING"; PASS=0
fi

TREE="$(swaymsg -t get_tree)"
FOOT1_FOCUSED=$(echo "$TREE" | jq "[.. | objects | select(.pid == $FOOT1_PID) | .focused] | first")
FOOT2_FOCUSED=$(echo "$TREE" | jq "[.. | objects | select(.pid == $FOOT2_PID) | .focused] | first")
echo "foot1 (target) focused=$FOOT1_FOCUSED  foot2 (was focused) focused=$FOOT2_FOCUSED"

if [ "$FOOT1_FOCUSED" = "true" ]; then
  echo "  (b) foot1 (the session's window) is focused: found"
else
  echo "  (b) foot1 (the session's window) is focused: MISSING"; PASS=0
fi
if [ "$FOOT2_FOCUSED" = "false" ]; then
  echo "  (c) foot2 (previously focused) lost focus: found"
else
  echo "  (c) foot2 (previously focused) lost focus: MISSING"; PASS=0
fi

if [ "$PASS" = 1 ]; then
  echo "PASS: card-click jump focused the session's terminal window"
else
  echo "FAIL"
  echo "-- hud.log --"
  cat /tmp/hud.log || true
  echo "-- sway.log --"
  tail -20 /tmp/sway.log || true
  exit 1
fi
