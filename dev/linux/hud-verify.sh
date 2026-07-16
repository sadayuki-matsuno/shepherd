#!/usr/bin/env bash
# Machine-verifies the Linux HUD (linux/hud) inside the shepherd-linux-dev
# container. v2 exercises the real aggregation path: fetchAgents (fake `claude
# agents` roster + sessions registry + transcripts + real git repos) → repo
# columns → status rails / blocked banner, plus the registry file monitor.
#
# Checks on grim captures of a headless sway:
#   (a) working green #A6E3A1 and blocked peach #FAB387 pixels exist (3-px runs)
#   (b) the blocked banner's peach exists as an AREA (a run far wider than the
#       3px rail can produce)
#   (c) the g_file_monitor pipeline works: flipping one registry file idle→busy
#       repaints within 2–3s (second capture differs and gains green rails)
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
mkdir -p "$FIX/sessions"

# Fake `claude` at ~/.claude/local/claude — the third claudeBin candidate
# (Config.swift), so no defaults/argument plumbing is needed on Linux. Same
# roster convention as dev/demo-board.sh: agents.json next to the sessions dir.
mkdir -p "$HOME/.claude/local"
cat > "$HOME/.claude/local/claude" <<'EOF'
#!/bin/bash
case "$1" in
  agents) cat "$(dirname "${SHEPHERD_SESSIONS_DIR:-/nonexistent}")/agents.json" 2>/dev/null || echo '[]' ;;
  *)      echo '{}' ;;
esac
EOF
chmod +x "$HOME/.claude/local/claude"

# Two real git repos: gitFacts needs a checkout with a commit (rev-parse HEAD),
# and repoName/repoKey are what groupByRepo builds the columns from.
for repo in proj-alpha proj-beta; do
  mkdir -p "$FIX/$repo"
  git -C "$FIX/$repo" init -q -b main
  git -C "$FIX/$repo" -c user.email=fx@example.com -c user.name=fx \
    commit -q --allow-empty -m init
done
touch "$FIX/proj-alpha/dirty.txt"   # ±1 changed-files badge

# readSessionsRegistry drops entries whose pid is dead (kill(pid,0)), so back
# each fake session with a live throwaway process.
sleep 9999 & PID_AW=$!   # alpha working
sleep 9999 & PID_AB=$!   # alpha blocked
sleep 9999 & PID_BW=$!   # beta working
sleep 9999 & PID_BI=$!   # beta idle → flipped busy for the monitor check

HUD_PID=""
SWAY_PID=""
cleanup() {
  [ -n "$HUD_PID" ] && kill "$HUD_PID" 2>/dev/null || true
  [ -n "$SWAY_PID" ] && kill "$SWAY_PID" 2>/dev/null || true
  kill "$PID_AW" "$PID_AB" "$PID_BW" "$PID_BI" 2>/dev/null || true
}
trap cleanup EXIT

# updatedAt two hours ago keeps the cards' elapsed-time label at a stable "2h"
# across the two captures, so check (c) sees only the flip-induced change.
MS_2H_AGO=$(( ($(date +%s) - 7200) * 1000 ))

session_json() { # pid sessionId cwd status
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","kind":"interactive","name":"%s","status":"%s","updatedAt":%s}\n' \
    "$1" "$2" "$3" "$2" "$4" "$MS_2H_AGO"
}
session_json "$PID_AW" s-alpha-working /tmp/fixture/proj-alpha busy    > "$FIX/sessions/$PID_AW.json"
session_json "$PID_AB" s-alpha-blocked /tmp/fixture/proj-alpha waiting > "$FIX/sessions/$PID_AB.json"
session_json "$PID_BW" s-beta-working  /tmp/fixture/proj-beta  busy    > "$FIX/sessions/$PID_BW.json"
session_json "$PID_BI" s-beta-idle     /tmp/fixture/proj-beta  idle    > "$FIX/sessions/$PID_BI.json"

# `claude agents --json --all` roster — fetchAgents builds its rows from this.
cat > "$FIX/agents.json" <<EOF
[
  {"sessionId":"s-alpha-working","id":"aw","kind":"interactive","pid":$PID_AW,"status":"busy","cwd":"/tmp/fixture/proj-alpha","startedAt":$MS_2H_AGO},
  {"sessionId":"s-alpha-blocked","id":"ab","kind":"interactive","pid":$PID_AB,"status":"busy","cwd":"/tmp/fixture/proj-alpha","startedAt":$MS_2H_AGO},
  {"sessionId":"s-beta-working","id":"bw","kind":"interactive","pid":$PID_BW,"status":"busy","cwd":"/tmp/fixture/proj-beta","startedAt":$MS_2H_AGO},
  {"sessionId":"s-beta-idle","id":"bi","kind":"interactive","pid":$PID_BI,"status":"idle","cwd":"/tmp/fixture/proj-beta","startedAt":$MS_2H_AGO}
]
EOF

# Transcripts (fixture shapes from Tests/TranscriptTests.swift): ai-title lines
# for the card title, main-chain assistant usage for model + context %, and for
# the blocked session an UNANSWERED AskUserQuestion as the newest record —
# blockedState reads that as .pending and blockedPromptFromTranscript yields
# the banner's question preview.
ALPHA_DIR="$FIX/projects/-tmp-fixture-proj-alpha"
BETA_DIR="$FIX/projects/-tmp-fixture-proj-beta"
mkdir -p "$ALPHA_DIR" "$BETA_DIR"

cat > "$ALPHA_DIR/s-alpha-working.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Porting the refresh pipeline","sessionId":"s-alpha-working"}
{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":50000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}
EOF
cat > "$ALPHA_DIR/s-alpha-blocked.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Choosing the auth flow","sessionId":"s-alpha-blocked"}
{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":20000,"cache_read_input_tokens":30000,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Which auth flow should the port use?","options":[{"label":"OAuth"},{"label":"API key"}]}]}}]}}
EOF
cat > "$BETA_DIR/s-beta-working.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Wiring the file monitor","sessionId":"s-beta-working"}
{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":30000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF
cat > "$BETA_DIR/s-beta-idle.jsonl" <<'EOF'
{"type":"ai-title","aiTitle":"Waiting for the next task","sessionId":"s-beta-idle"}
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
export SHEPHERD_SESSIONS_DIR="$FIX/sessions" SHEPHERD_PROJECTS_DIR="$FIX/projects"
GDK_BACKEND=wayland GSK_RENDERER=cairo \
  build-linux/shepherd-hud >/tmp/hud.log 2>&1 &
HUD_PID=$!

sleep 5

echo "== capture 1 =="
grim -t ppm /tmp/hud1.ppm
HEX1=$(od -An -v -tx1 /tmp/hud1.ppm | tr -d ' \n')

GREEN3='a6e3a1a6e3a1a6e3a1'
PEACH3='fab387fab387fab387'
PEACH30=$(printf 'fab387%.0s' $(seq 1 30))
PASS=1

if echo "$HEX1" | grep -q "$GREEN3"; then
  echo "  (a) working green #A6E3A1: found"
else
  echo "  (a) working green #A6E3A1: MISSING"; PASS=0
fi
if echo "$HEX1" | grep -q "$PEACH3"; then
  echo "  (a) blocked peach #FAB387: found"
else
  echo "  (a) blocked peach #FAB387: MISSING"; PASS=0
fi
if echo "$HEX1" | grep -q "$PEACH30"; then
  echo "  (b) peach banner area (30-px run): found"
else
  echo "  (b) peach banner area (30-px run): MISSING"; PASS=0
fi

echo "== flip s-beta-idle idle→busy (file monitor check) =="
sed 's/"status":"idle"/"status":"busy"/' "$FIX/sessions/$PID_BI.json" > "$FIX/sessions/$PID_BI.json.tmp"
mv "$FIX/sessions/$PID_BI.json.tmp" "$FIX/sessions/$PID_BI.json"
sleep 3   # debounce 0.2s + rebuild; well under the 30s fallback timer

echo "== capture 2 =="
grim -t ppm /tmp/hud2.ppm
if cmp -s /tmp/hud1.ppm /tmp/hud2.ppm; then
  echo "  (c) repaint after registry change: MISSING (captures identical)"; PASS=0
else
  HEX2=$(od -An -v -tx1 /tmp/hud2.ppm | tr -d ' \n')
  # The flipped card's rail goes dim-gray → pure green: the count of exact
  # green runs must GROW, proving the repaint carried the new status (not
  # some unrelated pixel wiggle).
  G1=$(echo "$HEX1" | grep -o "$GREEN3" | wc -l)
  G2=$(echo "$HEX2" | grep -o "$GREEN3" | wc -l)
  if [ "$G2" -gt "$G1" ]; then
    echo "  (c) repaint after registry change: found (green runs $G1 → $G2)"
  else
    echo "  (c) repaint after registry change: captures differ but green did not grow ($G1 → $G2)"; PASS=0
  fi
fi

if [ "$PASS" = 1 ]; then
  echo "PASS: fetchAgents board rendered and live-updates on the overlay"
else
  echo "FAIL"
  echo "-- hud.log --"
  cat /tmp/hud.log || true
  echo "-- sway.log --"
  tail -20 /tmp/sway.log || true
  exit 1
fi
