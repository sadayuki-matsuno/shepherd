#!/bin/bash
# dev/demo-director.sh <ja|en> [beat] — demo-board.sh の架空盤面を「動画用」に beat 進行で動かす。
#
# demo-board.sh が作る静的な盤面のうち checkout カード（OPUS/plan）だけを、beat ごとに
# 書き換える: busy（全部緑）→ waiting+質問（オレンジに浮く）→ 回答済みで busy に復帰。
# 盤面は FSEvents+デバウンスで ~0.3s 追従するので、ファイルを書くだけで状態遷移が演出できる。
#
# 2つの使い方:
#   A) 対話モード（引数1つ）— 人が録画しながら Enter/回答で進める。
#      【必ず単一ペインの zellij セッション内で実行する】 demo-board の sleep pid がこのペインの
#      ZELLIJ_SESSION_NAME を env に持つことで、HUD のポップオーバー回答が本物の送信経路
#      （zellij action write-chars → このペイン）で成功する。回答テキスト+Enter がこのスクリプトの
#      stdin に流れ込むのを beat 2 への自動進行として利用している（回答クリック＝カード復帰）。
#        zellij -s shepherd-demo     # ペインを増やさないこと（増えると送信が拒否される）
#        ./dev/demo-director.sh ja   # → 印字された起動コマンドで Shepherd を起動 → 録画開始
#   B) beat 指定モード（引数2つ・非対話）— そのビートだけ書いて即終了する。`screencapture -v`
#      と組み合わせたスクリプト録画（README の GIF 再生成）用。beat 0 だけは盤面のステージング
#      込み、1/2 は既存フィクスチャ（beat 0 が採番した sid/pid）を書き換えるだけ。
#        ./dev/demo-director.sh en 0   # ステージ + 全部緑 → Shepherd を起動して録画開始
#        ./dev/demo-director.sh en 1   # 質問が浮く（録画中に外から叩く）
#        ./dev/demo-director.sh en 2   # 回答済みで復帰
#
# 後片付け: pkill -f "sleep 86340"; rm -rf "${DEMO_BASE:-/tmp/shepherd-demo}"; 実 Shepherd を再起動。
set -euo pipefail

LANGSEL="${1:-en}"
ONLY_BEAT="${2:-}"
BASE="${DEMO_BASE:-/tmp/shepherd-demo}"
SRC="$BASE/src"
FIX="$BASE/$LANGSEL"

if [ -z "$ONLY_BEAT" ] && [ -z "${ZELLIJ:-}" ]; then
  echo "⚠ zellij の外で実行しています。盤面の演出はできますが、ポップオーバーからの回答送信は失敗します。" >&2
fi

# beat 指定モードの 1/2 は既存フィクスチャ前提 — 再ステージすると sid/pid が採番し直しになる。
if [ -z "$ONLY_BEAT" ] || [ "$ONLY_BEAT" = 0 ]; then
  "$(dirname "$0")/demo-board.sh" "$LANGSEL"
fi

beat() { # <0|1|2> — checkout カードの registry+transcript を書き換える
  python3 - "$LANGSEL" "$FIX" "$SRC" "$1" <<'PYEOF'
import json, os, re, sys, time

lang, fix, src, beat = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ja = lang == "ja"
def T(ja_s, en_s): return ja_s if ja else en_s
def sanitize(cwd): return re.sub(r"[^A-Za-z0-9]", "-", cwd)

# demo-board が採番した sid/pid をそのまま使う（毎回変わるので roster から引く）
agents = json.load(open(os.path.join(fix, "agents.json")))
a = next(x for x in agents if x["cwd"] == f"{src}/checkout")
sid, pid, cwd, started = a["sessionId"], a["pid"], a["cwd"], a["startedAt"]

model, usage, mode = "claude-opus-4-8", (1200, 160000, 8800), "plan"
title  = T("決済APIの移行: checkout を新エンドポイントへ", "Migrate checkout to the new payments API")
prompt = T("checkout を新しい決済APIに移行して", "Migrate checkout to the new payments API")
q      = T("スキーマ変更を先に staging へ適用しますか？", "Apply the schema change to staging first?")
opts   = [T("適用する — staging でマイグレーション実行後に続行", "Apply first — run the migration on staging, then continue"),
          T("あとで — コード変更のみ先に進める", "Later — land the code change only")]

def final(content):  # モデルチップ/usage は「最後の assistant 行」から読まれる
    inp, cr, cc = usage
    return dict(type="assistant",
                message=dict(role="assistant", model=model,
                             usage=dict(input_tokens=inp, cache_read_input_tokens=cr,
                                        cache_creation_input_tokens=cc),
                             content=content))
ask = dict(type="tool_use", name="AskUserQuestion", id="toolu_q1",
           input=dict(questions=[dict(question=q, multiSelect=False,
                                      options=[dict(label=o) for o in opts])]))

lines = [
    dict(type="user", timestamp="2026-07-11T09:00:00.000Z",
         message=dict(role="user", content=prompt)),
    {"type": "permission-mode", "permissionMode": mode},
    {"type": "ai-title", "aiTitle": title},
]
if beat == 0:      # 全部緑の平常運転
    lines.append(final([dict(type="text", text=T("作業を継続しています。", "Continuing with the task."))]))
    status = "busy"
elif beat == 1:    # 質問が浮く（カードの一行プレビューは最新 assistant テキストなので散文を先に）
    lines.append(dict(type="assistant", message=dict(role="assistant",
                 content=[dict(type="text", text=q)])))
    lines.append(final([ask]))
    status = "waiting"
else:              # 回答済み → 再開
    lines.append(dict(type="assistant", message=dict(role="assistant",
                 content=[dict(type="text", text=q)])))
    lines.append(dict(type="assistant", message=dict(role="assistant", content=[ask])))
    lines.append(dict(type="user", message=dict(role="user", content=[
        dict(type="tool_result", tool_use_id="toolu_q1", content=opts[0])])))
    lines.append(final([dict(type="text", text=T(
        "staging にマイグレーションを適用してから続行します。",
        "Applying the migration to staging first, then continuing."))]))
    status = "busy"

pdir = os.path.join(fix, "projects", sanitize(cwd))
os.makedirs(pdir, exist_ok=True)
with open(os.path.join(pdir, f"{sid}.jsonl"), "w") as f:
    for l in lines:
        f.write(json.dumps(l, ensure_ascii=False) + "\n")
with open(os.path.join(fix, "sessions", f"{pid}.json"), "w") as f:
    json.dump(dict(pid=pid, sessionId=sid, cwd=cwd, kind="interactive",
                   status=status, startedAt=started, updatedAt=int(time.time() * 1000)),
              f, ensure_ascii=False)
print(f"beat {beat}: checkout -> {status}")
PYEOF
}

if [ -n "$ONLY_BEAT" ]; then
  beat "$ONLY_BEAT"
  exit 0
fi

beat 0
echo
echo "▶ beat 0: 全カード busy（緑）。Shepherd を上のコマンドで起動 → 録画開始 → Enter で質問を浮かせる"
echo "  （Shepherd はこの zellij の外＝別ターミナルから起動する。このセッションにペインを足すと"
echo "    単一ペインガードに引っかかり、ポップオーバー回答が黙って届かなくなる）"
read -r || true
beat 1
echo "▶ beat 1: checkout がオレンジ（応答待ち）。盤面のカードをクリックして選択肢に回答してください"
echo "  （回答のキー入力がこのペインに届き、自動で beat 2 = カード復帰に進みます）"
read -r _answer || true
beat 2
echo "▶ beat 2: 回答済み → checkout が緑に復帰。撮り終わったら Enter で終了（片付けはしない）"
read -r || true
echo "終了。片付け: pkill -f \"sleep 86340\"; rm -rf \"$BASE\"; 実 Shepherd を再起動"
