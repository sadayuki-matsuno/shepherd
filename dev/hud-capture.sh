#!/bin/bash
# Shepherd HUD を PNG に撮る（Claude の実機セルフ確認用 — CLAUDE.md「デバッグ手段」参照）。
# 使い方: dev/hud-capture.sh [出力.png]    # 省略時 /tmp/shepherd-hud.png
# Shepherd のウィンドウが複数ある場合（ポップオーバー表示中など）は -1, -2… を付けて全部撮り、
# 撮ったファイルのパスを1行ずつ stdout に出す。
set -euo pipefail
out="${1:-/tmp/shepherd-hud.png}"

# window id は起動ごとに変わるので毎回 CGWindowList から引く（osascript 不要・この列挙に TCC 不要）。
ids=$(swift - <<'EOF'
import CoreGraphics
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
// 面積の大きい順 — 先頭がメインパネル、ポップオーバー類は後ろに続く。
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Shepherd" }
    .compactMap { w -> (id: Int, area: Double)? in
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return (id, (b["Width"] ?? 0) * (b["Height"] ?? 0))
    }
    .sorted { $0.area > $1.area }
for w in wins { print(w.id) }
EOF
)

[ -n "$ids" ] || { echo "Shepherd のウィンドウが見つかりません（起動していますか？）" >&2; exit 1; }

n=$(wc -l <<<"$ids" | tr -d ' ')
i=0
for id in $ids; do
    i=$((i + 1))
    dest="$out"
    [ "$n" -gt 1 ] && dest="${out%.png}-$i.png"
    # -x 無音 / -o 影なし / -l ウィンドウ単位（非アクティブ・別ディスプレイ・重なりの下でも撮れる）
    screencapture -x -o -l "$id" "$dest"
    echo "$dest"
done
