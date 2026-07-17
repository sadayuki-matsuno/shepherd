#!/bin/bash
# dev/demo-board.sh <ja|en> — stage a fully fictional demo board for screenshots.
#
# Builds demo git repos, a fake sessions registry (backed by live `sleep` pids), fake transcripts
# (ai-title / model+usage / permission-mode / a pending AskUserQuestion / an Artifact deliverable /
# a working Explore subagent), and fake `claude` / `gh` binaries — then prints the command that
# launches Shepherd against them. Nothing touches the real ~/.claude or the app's saved defaults:
# the data dirs come from SHEPHERD_SESSIONS_DIR / SHEPHERD_PROJECTS_DIR (main.swift fixture seams)
# and the tool paths ride the NSUserDefaults ARGUMENT domain (-claudePath / -ghPath), which never
# persists. Quit the real Shepherd first (single-instance guard) and relaunch it normally after.
#
#   ./dev/demo-board.sh ja
#   SHEPHERD_SESSIONS_DIR=… SHEPHERD_PROJECTS_DIR=… Shepherd -claudePath … -ghPath …   # printed
set -euo pipefail

LANGSEL="${1:-en}"
BASE="${DEMO_BASE:-/tmp/shepherd-demo}"
SRC="$BASE/src"
FIX="$BASE/$LANGSEL"
BIN="$BASE/bin"
mkdir -p "$SRC" "$BIN" "$FIX/sessions" "$FIX/projects"

# ── demo repos (shared between languages; idempotent) ─────────────────────────
mkrepo() { # <name> <branch>
  local d="$SRC/$1"
  if [ ! -d "$d/.git" ]; then
    git init -q -b main "$d"
    (cd "$d" && git -c user.email=demo@example.com -c user.name=demo commit -q --allow-empty -m init)
  fi
  (cd "$d" && git checkout -q -B "$2" 2>/dev/null || true)
}
touchn() { # <dir> <count>  — n uncommitted files → ±n and the dog-ear
  local d="$1" n="$2" i
  for ((i = 1; i <= n; i++)); do echo "demo $RANDOM" > "$d/wip-$i.txt"; done
}
# Column order is alphabetical by repo name (layoutColumns), so `checkout` (the blocked card's
# repo) lands leftmost: checkout < lobby < mailer.
mkrepo checkout issue2894-payments-api
touchn "$SRC/checkout" 6
if [ ! -d "$SRC/checkout-fix-auth-spec" ]; then
  git -C "$SRC/checkout" worktree add -q "$SRC/checkout-fix-auth-spec" -b fix-auth-spec 2>/dev/null || true
fi
touchn "$SRC/checkout-fix-auth-spec" 14
mkrepo mailer main
touchn "$SRC/mailer" 1
mkrepo lobby feat-spectator-mode
touchn "$SRC/lobby" 3

# ── fake claude / gh ──────────────────────────────────────────────────────────
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
# The roster lives next to the sessions dir Shepherd was launched with, so one fake binary
# serves every language's fixture set.
case "$1" in
  auth)   echo '{"loggedIn":true,"email":"you@example.com","subscriptionType":"max"}' ;;
  agents) cat "$(dirname "${SHEPHERD_SESSIONS_DIR:-/nonexistent}")/agents.json" 2>/dev/null || echo '[]' ;;
  *)      echo '{}' ;;
esac
EOF
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
case "$PWD" in
  */checkout-fix-auth-spec)
    case "$1 $2" in
      "pr view")   echo '{"number":3262,"url":"https://github.com/acme/checkout/pull/3262"}' ;;
      "pr checks") printf 'pass\npass\npass\n' ;;
    esac ;;
  */lobby)
    case "$1 $2" in
      "pr view")   echo '{"number":101,"url":"https://github.com/acme/lobby/pull/101"}' ;;
      "pr checks") printf 'pending\npass\n'; exit 8 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/claude" "$BIN/gh"

# ── live pids for the registry (the registry skips dead pids) ─────────────────
# Each sleep is exec'd with an explicit env: `ps -wwEp` reads the env captured at exec, which is
# where the board's runtime chips (zellij / VS Code / Ghostty) and the </> mark come from. Rows
# 1–3 pose as zellij panes under Ghostty; row 4 poses as a VS Code integrated terminal — so the
# screenshots show the chips deterministically instead of leaking the invoking shell's env.
# gsleep (homebrew coreutils), NOT /bin/sleep: macOS hides an Apple platform binary's env from
# `ps -E` entirely (measured 2026-07-12), so a /bin/sleep-backed row can never wear a chip.
# The zellij vars pass through from the invoking pane when present (dev/demo-director.sh runs
# inside a single-pane zellij session): the rows then name a REAL session, so the HUD's popover
# reply actually delivers. Outside zellij they fall back to the fixed fake ("demo").
SLEEPBIN=$(command -v gsleep || echo /bin/sleep)
[ "$SLEEPBIN" = /bin/sleep ] && echo "warn: gsleep not found — runtime chips won't show (brew install coreutils)" >&2
pkill -f "sleep 86340" 2>/dev/null || true
PIDS=()
for _ in 1 2 3; do
  env -i ZELLIJ_SESSION_NAME="${ZELLIJ_SESSION_NAME:-demo}" ZELLIJ_PANE_ID="${ZELLIJ_PANE_ID:-7}" TERM_PROGRAM=ghostty \
    "$SLEEPBIN" 86340 >/dev/null 2>&1 & PIDS+=($!)
done
env -i TERM_PROGRAM=vscode __CFBundleIdentifier=com.microsoft.VSCode \
  "$SLEEPBIN" 86340 >/dev/null 2>&1 & PIDS+=($!)
disown -a 2>/dev/null || true

# ── registry + transcripts + subagent files ───────────────────────────────────
python3 - "$LANGSEL" "$FIX" "$SRC" "${PIDS[@]}" <<'PYEOF'
import json, os, re, sys, time, uuid

lang, fix, src = sys.argv[1], sys.argv[2], sys.argv[3]
pids = [int(p) for p in sys.argv[4:8]]
now = time.time()
ja = lang == "ja"

def sanitize(cwd): return re.sub(r"[^A-Za-z0-9]", "-", cwd)
def ms(sec_ago): return int((now - sec_ago) * 1000)

def T(ja_s, en_s): return ja_s if ja else en_s

S = [
    # blocked: OPUS on PLAN in the main checkout, waiting 4m on a question (leftmost column)
    dict(sid=str(uuid.uuid4()), cwd=f"{src}/checkout", status="waiting",
         started=11*60, updated=4*60,
         model="claude-opus-4-8", usage=(1200, 160000, 8800), mode="plan",
         title=T("決済APIの移行: checkout を新エンドポイントへ", "Migrate checkout to the new payments API"),
         prompt=T("checkout を新しい決済APIに移行して", "Migrate checkout to the new payments API"),
         question=dict(
             q=T("スキーマ変更を先に staging へ適用しますか？", "Apply the schema change to staging first?"),
             opts=[T("適用する — staging でマイグレーション実行後に続行", "Apply first — run the migration on staging, then continue"),
                   T("あとで — コード変更のみ先に進める", "Later — land the code change only")])),
    # working: SONNET (+OPUS advisor) auto-accepting edits in a linked worktree, PR CI passing
    dict(sid=str(uuid.uuid4()), cwd=f"{src}/checkout-fix-auth-spec", status="busy",
         started=34*60, updated=8*60,
         model="claude-sonnet-5", advisor="claude-opus-4-8",
         usage=(900, 120000, 7100), mode="acceptEdits",
         title=T("flaky な認証テストの修正", "Fix the flaky auth spec"),
         prompt=T("認証テストがたまに落ちるので直して", "The auth spec fails intermittently — fix it")),
    # working lead: FABLE on bypass, publishes an Artifact, runs an Explore subagent
    dict(sid=str(uuid.uuid4()), cwd=f"{src}/mailer", status="busy",
         started=47*60, updated=13*60,
         model="claude-fable-5", usage=(1500, 300000, 8500), mode="bypassPermissions",
         title=T("調査: 通知メールが二重送信されるバグ", "Investigate duplicate notification emails"),
         prompt=T("通知メールが二重に届くことがある。原因を調査して", "Notification emails sometimes arrive twice — find out why"),
         artifacts=[dict(favicon="🗺",
                         desc=T("配送経路の見取り図", "Delivery-path map"),
                         url="https://claude.ai/code/artifact/cccc1111-2222-3333-4444-555566667777",
                         redeploy=True),
                    dict(favicon="🧪",
                         desc=T("再現手順ノート", "Repro-steps note"),
                         url="https://claude.ai/code/artifact/bbbb1111-2222-3333-4444-555566667777"),
                    dict(favicon="📮",
                         desc=T("二重送信バグの原因調査レポート", "Duplicate-send root-cause report"),
                         url="https://claude.ai/code/artifact/aaaa1111-2222-3333-4444-555566667777")],
         subagent=dict(name=T("送信キュー呼び出し箇所の走査", "scan send-queue call sites"))),
    # working: SONNET, young session, PR #101 with CI still running
    dict(sid=str(uuid.uuid4()), cwd=f"{src}/lobby", status="busy",
         started=6*60, updated=90,
         model="claude-sonnet-5", usage=(400, 17000, 600), mode="acceptEdits",
         title=T("ロビーに観戦モードを追加", "Add spectator mode to the lobby"),
         prompt=T("ロビーに観戦モードを足してください", "Please add a spectator mode to the lobby")),
]

# `claude agents --json --all` roster — the entry-point source rows are built from
agents = [dict(sessionId=s["sid"], id=s["sid"][:8], kind="interactive", pid=pids[i],
               status="busy", cwd=s["cwd"], startedAt=ms(s["started"]))
          for i, s in enumerate(S)]
with open(os.path.join(fix, "agents.json"), "w") as f:
    json.dump(agents, f, ensure_ascii=False)

for i, s in enumerate(S):
    # sessions registry — what `claude` itself writes per process
    reg = dict(pid=pids[i], sessionId=s["sid"], cwd=s["cwd"], kind="interactive",
               status=s["status"], startedAt=ms(s["started"]), updatedAt=ms(s["updated"]))
    if "waiting" in s: reg["waitingFor"] = s["waiting"]
    with open(os.path.join(fix, "sessions", f"{pids[i]}.json"), "w") as f:
        json.dump(reg, f, ensure_ascii=False)

    # transcript jsonl
    pdir = os.path.join(fix, "projects", sanitize(s["cwd"]))
    os.makedirs(pdir, exist_ok=True)
    inp, cr, cc = s["usage"]
    lines = [
        dict(type="user", timestamp="2026-07-11T09:00:00.000Z",
             message=dict(role="user", content=s["prompt"])),
        {"type": "permission-mode", "permissionMode": s["mode"]},
        {"type": "ai-title", "aiTitle": s["title"]},
    ]
    for ai, a in enumerate(s.get("artifacts", [])):
        # timestamp + cwd on the tool_result line feed the artifact shelf's index (updated stamp
        # + repo attribution). A second publish of the same URL is the redeploy fixture (P4).
        publish = [
            dict(type="assistant", message=dict(role="assistant", content=[
                dict(type="tool_use", name="Artifact", id=f"toolu_art{ai}",
                     input=dict(file_path=f"report{ai}.html", favicon=a["favicon"], description=a["desc"]))])),
            dict(type="user", timestamp="2026-07-11T09:05:00.000Z", cwd=s["cwd"],
                 message=dict(role="user", content=[
                dict(type="tool_result", tool_use_id=f"toolu_art{ai}",
                     content=f"Published report{ai}.html at {a['url']}")])),
        ]
        lines += publish
        if a.get("redeploy"):
            lines += json.loads(json.dumps(publish).replace(f"toolu_art{ai}", f"toolu_art{ai}r"))
    if "question" in s:
        # The card's one-line "? …" preview reads the latest assistant TEXT, so say the question
        # in prose first — the tool_use record follows, like a real session.
        lines.append(dict(type="assistant", message=dict(role="assistant", content=[
            dict(type="text", text=s["question"]["q"])])))
    final = dict(type="assistant",
                 message=dict(role="assistant", model=s["model"],
                              usage=dict(input_tokens=inp, cache_read_input_tokens=cr,
                                         cache_creation_input_tokens=cc)))
    # Advisor pairing shows as a line-level advisorModel field (same as a real `--advisor` run).
    if "advisor" in s: final["advisorModel"] = s["advisor"]
    if "question" in s:
        q = s["question"]
        final["message"]["content"] = [dict(
            type="tool_use", name="AskUserQuestion", id="toolu_q1",
            input=dict(questions=[dict(question=q["q"], multiSelect=False,
                                       options=[dict(label=o) for o in q["opts"]])]))]
    else:
        final["message"]["content"] = [dict(
            type="text", text=("作業を継続しています。" if ja else "Continuing with the task."))]
    lines.append(final)
    with open(os.path.join(pdir, f"{s['sid']}.jsonl"), "w") as f:
        for l in lines:
            f.write(json.dumps(l, ensure_ascii=False) + "\n")

    # a working Explore subagent (nested card + family strip on the parent)
    if "subagent" in s:
        sub = os.path.join(pdir, s["sid"], "subagents")
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, "agent-demo1.meta.json"), "w") as f:
            json.dump(dict(agentType="Explore", name=s["subagent"]["name"],
                           description=s["subagent"]["name"]), f, ensure_ascii=False)
        # model + usage on the line: that's where the nested card's model chip (HAIKU — an
        # Explore subagent on the cheap tier, the playbook's own advice) and ctx % come from.
        with open(os.path.join(sub, "agent-demo1.jsonl"), "w") as f:
            f.write(json.dumps(dict(type="assistant", message=dict(role="assistant",
                model="claude-haiku-4-5-20251001",
                usage=dict(input_tokens=600, cache_read_input_tokens=40000,
                           cache_creation_input_tokens=2400),
                content=[dict(type="tool_use", name="Grep", input=dict(pattern="enqueueSend"))])),
                ensure_ascii=False) + "\n")

print("demo pids:", pids)
PYEOF

APPLELANG=""
[ "$LANGSEL" = "en" ] && APPLELANG='-AppleLanguages (en)'
cat <<EOF

Staged. Launch (quit the real Shepherd first — single-instance guard):

  pkill -x Shepherd
  SHEPHERD_SESSIONS_DIR="$FIX/sessions" SHEPHERD_PROJECTS_DIR="$FIX/projects" \\
    /Applications/Shepherd.app/Contents/MacOS/Shepherd \\
    -claudePath "$BIN/claude" -ghPath "$BIN/gh" $APPLELANG &

Cleanup: pkill -f "sleep 86340"; rm -rf "$BASE"; relaunch Shepherd normally.
EOF
