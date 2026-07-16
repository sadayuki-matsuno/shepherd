# CLAUDE.md

Shepherd はこのマシンで動く Claude Code セッション（zellij ペイン・素のターミナル・cc-daemon の background worker）を横断監視する、macOS の常時最前面フローティング HUD（AppKit / LSUIElement accessory app）。herdr にもフックにも依存しない。**インストールは Shepherd 本体だけ**で、`~/.claude/settings.json` には一切触らない。データ源は Claude Code 自身のファイル（sessions レジストリ / transcript / cc-daemon control socket / `ps` の env）と zellij CLI のみ。このファイルは開発に必要な前提知識（アーキテクチャ・ビルド・既知の地雷）をまとめたもの。まず一度通読すること。

## ドキュメント保守ルール（機能開発・改修時に必ず）

コード変更を伴う作業を終えるとき、**以下のドキュメントが変更内容に追従しているかを毎回確認し、ずれていれば同じ作業の中で更新する**（「あとで」にしない。ドキュメント更新までがタスクの完了条件）:

1. **この CLAUDE.md** — アーキテクチャ・データ源・地雷・デバッグ手段に変化があれば該当節を更新
2. **README.md** — ユーザー向けの機能説明・セットアップ手順・設定（defaults キー）に変化があれば更新
3. **docs/（GitHub Pages の docs サイト・7ページ構成・日英対応）** — 機能の追加/削除・スクリーンショットが古くなった場合に更新。**全ページが en/ja ツイン構造**（ブロック要素に `lang="en"`/`lang="ja"` を並置し `html[lang]` の CSS で切替、初期値は `navigator.language`・ヘッダーの EN/日本語トグルで変更・localStorage 永続・`?lang=` で強制）— 本文を変えるときは**両言語とも更新する**。スクリーンショットは **`./dev/demo-board.sh` で架空データの盤面を作って** `./dev/hud-capture.sh` で撮る（日英2枚: `docs/assets/hud-ja.png` / `hud-en.png`、`<img lang>` でページ言語に追従）。**実機の盤面をそのまま docs に載せない**（顧客プロジェクト名・実メールアドレスが写るため）
4. **docs/ 配下のガイド類**（活用ガイド等）— 操作方法・推奨ワークフローに影響する変更があれば更新

判断基準: 「この変更を知らない人が README/LP を読んで誤解するか?」— Yes なら更新対象。内部リファクタのみ（挙動・UI・設定に変化なし）なら CLAUDE.md の該当行だけ見直せばよい。

## プロジェクト概要とアーキテクチャ

- **`Sources/` は責務ごとに分割**。`main.swift` は設定グローバル読み込み・AppDelegate のクラス宣言（stored property）・エントリポイントだけ（約230行）。トップレベル文を書けるのは Swift の言語制約で main.swift のみ。
  - データ層: `Config`（bin解決・`L()`）/ `Models`（型・純ロジック）/ `Commands`（runCommand・zellij）/ `StatusStore`（キャッシュ・status dir・GC）/ `SessionsRegistry`（`~/.claude/sessions/<pid>.json`）/ `DaemonControl`（cc-daemon control socket）/ `ClaudeUsage` / `Transcript`（jsonl解析・リンク抽出・blocked質問抽出）/ `GitHubFacts`（git/gh）/ `UpdateCheck`（GitHub releases/latest・更新バッジ）/ `AgentFetch`（`fetchAgents` 集約）
  - UI層: `Components`（RowView等の部品）と `AppDelegate+*.swift`（メソッド群を関心事別に extension 分割: Jump / Actions / Reply / Notify / Deck / Lifecycle / Header / Cards / Columns）。**stored property は extension に置けない**ので必ず main.swift のクラス本体へ。
- **`Sources/StreamDeck.swift`** は IOKit HID の Stream Deck ドライバ（MK.2 / Original V2 Gen2）。開くときは **seize open 必須**（`kIOHIDOptionsTypeSeizeDevice`）。72×72 JPEG をキーに描画。⚙メニューから ON/OFF、接続時のみトグル可、成功していれば再起動時に自動再接続。
- **フックは使わない**。旧版が入れていた `~/.claude/hooks/shepherd-agent-status.sh`・`settings.json` の登録・`~/.claude/agent-status/` はこのマシンでは掃除済みで、掃除用の `hooks/uninstall.sh` も削除済み（必要になったら git 履歴から取れる。settings.json を触るときは in-place 書き換え必須 — rename すると hardlink 管理の dotfiles が切れる）。フックが持っていた情報の代替: 状態→sessions レジストリ、error→transcript の `isApiErrorMessage`、サブエージェント→`<session-id>/subagents/*.meta.json` ＋ 各 `agent-*.jsonl` の末尾（素の subagent は末尾ブロックが text なら終了。tail 窓は 256KB — 窓が最終レコードより小さいと永久 working になるため。根拠は地雷リスト。30分無更新の backstop は素の subagent にも適用〔tool_use 途中 kill 対策〕。**in-process teammate は末尾では判定できない**〔地雷リスト参照〕— 親 transcript の **`idle_notification`**〔`<teammate-message>` 内の JSON・ターン終了ごとに lead transcript へ書かれる・書き込みラグは lead 暇なら数十ms/ターン中は〜2分（2026-07 実測）〕が権威: jsonl mtime が最後の通知より新しければ再稼働＝working、通知なしで30分無更新なら idle に倒す backstop。`teammateWorking` / `teammateIdleTimes`〔増分スキャン `teammateIdleCache`〕）、zellij ペイン/親子→`ps -wwEp` の env、last_prompt / permission_mode→transcript の同名行。**compacting / starting 状態は扱わない**（前者はプロセス内 SDK イベントにしか出ず、外部から観測不能）。
- **ビルドは `swiftc` 直**（`build.sh`）。Xcode プロジェクトや SwiftPM は無い。フレームワークは AppKit / IOKit / ApplicationServices。
- **テストは `./test.sh`**（`Tests/`、自前ハーネス — CLT に XCTest が無いため）。main.swift と AppDelegate+\* 以外の全ソースをリンクして実装そのものを検証する。`claudeProjectsDir` / `claudeSessionsDir` はテストから差し替えられるよう `var`（テストシーム）。
- **アプリの性質**: `NSPanel`（borderless / nonactivatingPanel）＋ LSUIElement。**このアプリは決してアクティブにならない**。これが地雷の温床（後述）。

### HUD の構造

- **カードの構成**（`rowView(for:)`・上から）:
  1. ［状態バナー 19px — blocked=桃「? 応答待ち — N分（・放置中）」/ error=赤「ERROR — 対応が必要」のときだけ］
  2. タイトル行: **先頭に実行環境グリフ**（アイコン単独の計器はここだけ: zellij=分割ペイン / エディタ=`</>`〔未知の VS Code フォークも同グリフ・実名はホバー〕 / 端末アプリ=窓付き端末 / headless=素のプロンプト。純関数 `runtimeGlyph`。**グリフの色＝権限モード**〔lavender=plan / 緑=acceptEdits / 琥珀=dontAsk / 赤=bypass / 灰=default〕。ホバーで実行環境＋モード名をヒント行へ）→ activity（OSC タイトル → last_prompt。無ければセッション名）＋ `#issue` を追記。subagent=sparkles・ツールコール中=gear・遠隔マークもこの行
  3. 計器行（「アイコン＋テキスト」の計器。ピルが残るのは BG・parked・未知の権限モードだけ〔既知モードの判定は `lockGlyph(for:)` を述語として流用〕）: **段数バー＋モデル名**（`modelTier` 1=HAIKU〜4=FABLE。未知名はテキストチップにフォールバック。グリフの底はラベルの **baseline に接地**〔大文字ラベルの光学中心は幾何中心より上 — centerY 揃えは沈んで見える〕）・**描画矢印→吹き出し＋アドバイザー名**（`advisorArrowImage`＋SF `bubble.left`。矢印=相談する先・アドバイザー計器はホバーで説明ポップアップ。transcript 行レベル `advisorModel` 由来〔subagent/teammate の jsonl にも継承〕。「構成あり」の印で「相談した」印ではない）。描画は `tierBarsImage`＋`instrument()`（Components）
  4. ［blocked の「? 質問」1行プレビュー（`showBlockedQuestion`・needs → lastMessage）］
  5. ［成果物: **Artifact のみ**（1件=タイトルバッジ・2件以上=「最新タイトル（他+N）」1枚でクリック選択メニュー `artifactBadgeText`）。PR はカード面に出さず、右クリックメニューの「✓/✗/● PR #N を開く」で扱う］
  6. メタ行: 経過時間・±変更ファイル数・📎送信済み・stale?・✨子作業中、右端に◔コンテキスト%パイ（**状態の単語は置かない** — 状態は下記の装飾が担う）
- **状態はドットではなくカード装飾**: 左端3pxレール（赤error/桃blocked/緑working/灰idle）、blocked/error は薄い同色ウォッシュ、working は緑の呼吸ボーダー＋薄緑ティント、idle/終了は50%アルファ（ホバーで復帰）。未コミットは右上の琥珀ドッグイア（15×15）。パス⎇ブランチはカード面には無い（右クリックメニュー内のみ）。subagent/teammate カードは破線輪郭のコンパクトチップ（レールなし・破線色が状態色）。
- **ヒント行**: カード下部に自前のホバーヒント表示（`hintLabel` / `setHint`）。NSToolTip が効かないための代替。
- **カードのクリック＝そのセッションを開く**（`openRow`）: zellij 行は `zellij attach`＋ペインフォーカス、background worker は **Ghostty 新窓で `claude attach <short-id>`**（終了記録は確認シートを挟んで再開）。開けない行（素のターミナル）は toolTip で説明するだけ。
- **カード操作は右クリックメニュー**（`wireCardActions` のコンテキストメニュー）: 回答する（blocked時は先頭）／zellij・attach で開く／遠隔操作／範囲を撮影して送る／閉じる 等。旧ホバートレイは廃止済みで `RowView.tray` はどこからも populate されない（死にコード。触るなら削除してよい）。
- **ファミリーストリップ**（親カード最下部20px）: `⌄/› 子 N 件・稼働中 M`。折りたたみ中は子のステータスドット＋要注目の子の一言（blocked の `? 質問` 優先）も同居し、ホバーで覗き見ポップオーバー（`showFamilyPeek`）。クリックはストリップ全面でトグル — `RowView.hitTest` は NSButton 系しかクリックを通さないので**透明 `HoverButton` を全面に重ねる**構成。
- **HUDサイズモード**: ⚙メニュー「HUD サイズ」で `auto`（内容追従）/ 小=1列 / 中=2列 / 大=3列（固定サイズ・高さは 520/640/760 をディスプレイ高でクランプ）/ `fullDisplay`（載っているディスプレイの visibleFrame 全面）を切り替え（`hudSizeMode` に永続化）。`stack` は常に `DragScrollView`（縦スクロールのみ・documentView は `FlippedView` で上詰め・幅は clip 幅に固定＝横スクロール構造的に不可）内に住み、auto ではパネルが内容にフィットするためスクロールは発生しない。固定系の列数は `effectiveColumns`（プリセット列数 / fullDisplay は `hudFitColumns` で画面幅から算出）が単一の真実で、`columnsView`・`applyManualDrop`・`boardWidth` すべてがこれを参照。ヘッダー/ダッシュボード/ヒント行の幅は `boardSpanWidth`（固定系はパネル内寸）。最小化は固定サイズより優先（小さいストリップに縮む）。**最小化ストリップの中身は「ブランドバー＋compact ダッシュボード＋ステータス行」**: ダッシュボードは `usageDashboardView(width:compact:)` の compact でゲージのみ（クレジット列と仕切りを省略・幅は必ずストリップ内寸 `contentWidth-24` — wide 幅のまま渡すとクリップされてゲージが見切れる）、ステータス行（件数ピル＋quota/クレジットチップ）は最小化でも返す（24hフィルタチップと＋だけ省略）。純ロジック（`hudPreset`/`hudPanelWidth`/`hudFitColumns`）は Models.swift・テスト済み。
- **コンテキスト%**: メタ行右端の小さなパイ＋%（60%未満はグレーでカードに溶け、60%で黄・85%で赤）。パイへのホバーで残量ヒント（`HoverView`）。
- **各ポップオーバー**（すべて `behavior = .applicationDefined`・表示前に `NSApp.activate`）:
  - 回答（`showReply`）— blocked agent にインライン回答。質問文は transcript の最新 AskUserQuestion/ExitPlanMode tool_use input（`blockedPromptFromTranscript`）、bg worker は socket の `needs`。送信は zellij なら write-chars＋Enter、bg worker なら control socket の `reply` op（**auth 必須**: `~/.claude/daemon/control.key`）。📋コピーボタン＋⌘Cローカルモニタ。
  - ＋新規セッション（`showNewSessionMenu`）— ghq base リポジトリ検索ピッカー→`git worktree add`→Ghostty 新窓で `claude`（cwd=worktree）。
  - ドロップ確認（`showDropPopover`）— ファイルD&D時。

### 更新パイプライン

- **トリガー**: ① `~/.claude/sessions` の FSEvents（latency 0.1s＋デバウンス 0.2s。claude プロセス自身が状態変化のたびに書く）② 30秒フォールバックタイマー。**ポーリングは無い**。
- **refresh はドロップしない**: 実行中に来た要求は `refreshPending` に積み、完了直後にもう1周（黙って捨てると最悪30秒待ちになる）。
- **fetchAgents は行ごとに並列**（`concurrentPerform`）。共有キャッシュは `factsLock`（StatusStore）で保護。**キャッシュ dict を触るコードは必ず factsLock を取り、サブプロセス/ファイルIOはロックの外で行う**。
- **runCommand はデフォルト10秒タイムアウト**（ハングした gh が refresh を固めない）。対話的 `screencapture -i`（600s）と `git worktree add`（120s）だけ明示的に延長。
- 所要時間は毎回 stderr に `refresh N.NNs rows=M` を出す（→ `/tmp/shepherd-deck.log`）。実測: 定常 0.2〜0.3s、コールド 1.1s。

### データ源

- **`~/.claude/sessions/<pid>.json`**（`Sources/SessionsRegistry.swift`）: **claude プロセス自身が書く** status レジストリ（`claude agents` が読んでいる実体）。`pid / sessionId / cwd / kind / entrypoint("cli"=対話REPL・"sdk-cli"=`claude -p`/SDK・"claude-vscode"=拡張パネル、2026-07 実測) / name / status(busy|idle|waiting) / waitingFor("permission prompt" 等) / updatedAt`。サブプロセス不要のディレクトリ読み・リアルタイム更新・FSEvents 可。**フック未導入セッションの状態源**であり、blocked の理由（waitingFor）は `needs` のフォールバックにも使う。死んだ pid のファイルは skip（`kill(pid,0)`）。非公開ファイルなので additive に読む。
- **`claude` CLI**: `agents --json --all`（0.29s・終了済み background 記録の唯一の源）/ `stop` / `rm` / **`attach <short-id>`（隠しコマンド。カードクリックの実体）**。zellij `dump-layout`（sendable判定）は30sキャッシュ。
- **cc-daemon control socket**（`Sources/DaemonControl.swift`・プロトコルは 2026-07 実測）: `claude stop` が実際に喋っている非公開プロトコル。`/tmp/cc-daemon-<uid>/<hash>/control.sock` へ改行区切り JSON 1往復（`{"proto":1,"op":"list"|"kill"|"ping"}`）。**サブプロセス無し・1ms**。認証は無く 0700 dir と uid チェックのみ（`control.key` は `attach` 用）。socket パスは **roster の `workers[].rendezvousSock` から導出**する（`/tmp` を glob しない — `CLAUDE_CONFIG_DIR` ごとに別 daemon になるため）。生きた bg worker だけを返し、`detail`（今のターンの作業内容）と `needs`（blocked が求める決定）は**他のどの源にも無い**。`daemonJobs()` は 2s キャッシュ。
  - **`claude stop` の exit 0 を信じてはいけない**: daemon 無応答時、5秒待って exit 0 を返すのに worker は生きている（実測）。close 系は `daemonJobExists` で消失を確認してから status ファイルを消すこと（`stopBackgroundWorker`）。
  - kill は**非同期**（受理 0.6ms → 消失 ~600ms）。消えた id への kill は `ENOJOB` だが、これは求める終状態なので**成功として読む**。
  - **socket をポーリングしても daemon は延命しない**（lease を取るのは `attach` だけ。隔離 `CLAUDE_CONFIG_DIR` の対照実験で確認）。refresh から自由に呼んでよい。
  - `proto` 不一致は `EPROTO` で即拒否される。将来のバージョンで機能が消えても HUD が壊れないよう、すべて nil 返し＝additive に扱う。
- **Claude OAuth API**（`Sources/ClaudeUsage.swift`・レスポンス形は 2026-07 実測）: `GET api.anthropic.com/api/oauth/usage`（要 `anthropic-beta: oauth-2025-04-20` ヘッダ＋claude-code UA）でプラン使用量ダッシュボードの全データ — `limits[]`（session/weekly/モデル別の percent・resets_at・severity。**is_active** は「いま支配的な窓」の意で「進行中」ではない〔実測では消費%最大の窓に付いた — session 4% 進行中でも false〕・分かりにくいためユーザー判断で表示せずパースもしない）と `spend`（クレジット: `used` は未契約でも $0.00 が返る・**`balance`/`cap` は未契約時 null**・有効時は `limit`=月間上限のマネーオブジェクト・`cap` は `{money,credits}` のネスト形で別物・**残額は API に無いので limit−used で計算**）。プランチップ（MAX 20X）は `GET /api/oauth/profile` の `organization.rate_limit_tier`（`planTierCache` で1日1回・失敗もキャッシュ）。パースは純関数 `parseUsage`（テスト済み）。取得は `maybeRefreshUsage`（60秒ガード・ダッシュボード非表示でも走る — ヘッダーのクレジット/quotaチップの源が凍結しないように。**stale-while-error**: 失敗 snapshot は lastUsage を上書きせず `usageError` に退避 — ゲージは旧値のまま減光＋「更新失敗」表示）。ダッシュボードの ↻（`forceDashboardRefresh`）は usage/planTier/accountCache の全ガードを無視して即再取得。**OAuth token の読み出しは `security` サブプロセスが第一経路**（下記地雷参照）。**クレジット消費中判定（`creditBurnActive`）**: transcript/レジストリに per-session のクレジット信号は存在しない（2026-07 実測 — クレジット中も定常レコードは通常時と同一・429 rate_limit 行は壁に当たった1セッションにしか残らない）ので口座レベルで判定する — ①連続 snapshot 間で `spend.used`（`CreditInfo.usedMinor`）が増えた（直接証拠・単独で真）or ②いずれかの limit 窓が100%以上×extra usage 有効×稼働セッションあり（枯渇窓はリセットまで持続するので稼働ゲートが要る）。真なら `creditBurn` が立ち、クレジット欄が琥珀の呼吸グロー＋「消費中」・ヘッダーに琥珀「クレジット消費中」チップ（クリックで usage パネル。カード個別のマークは付けない — 口座レベルの事実は口座レベルの場所で光らせるというユーザー決定）。キャプチャ用シーム: env `SHEPHERD_FAKE_CREDIT_BURN=1` で常時点灯。
- **git**: ブランチ・変更ファイル数・repo grouping（`--git-common-dir`）・default branch 検出。git由来 facts は cwd ごとに15sキャッシュ（`gitFactsCache`。PR facts はキャッシュに含めず毎回 prCache からオーバーレイ）。
- **gh**: PR番号・URL（`gh pr view --json`）、CI（`gh pr checks --json bucket`、`ignoreExit`）。60秒キャッシュ＋ **stale-while-revalidate**（`prInfo` は同期で gh を呼ばない。期限切れでも手持ち値を即返し、裏の `prFetchQueue` で更新→変化時 `onPRFactsChanged` で再描画。`SHEPHERD_DUMP` は即 exit するため PR facts が空で出るのは仕様）。
- **GitHub releases/latest**（`Sources/UpdateCheck.swift`）: `api.github.com/repos/…/releases/latest` を認証なしで1日1回（`maybeCheckForUpdate`・refresh 便乗・24hガード）取得し、バンドルの `CFBundleShortVersionString` と数値比較。新しければブランドバーに「更新 vX.Y.Z」バッジ（クリックでリリースページ。更新自体は brew でユーザーが行う）。失敗は全て nil＝バッジ非表示の additive。キャプチャ用シーム: env `SHEPHERD_LATEST_TAG=v9.9.9` でネットワークを飛ばして偽の最新タグを返せる。
- **Claude Code transcript jsonl**: `~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl`。sanitize = 非英数字すべて`-`。**カードタイトルの第一候補は `{"type":"ai-title","aiTitle":"…"}` 行**（Claude Code が OSC でターミナルに流すのと同じ AI 生成タイトル＝zellij のペインタイトルの正体。タイトル更新のたび追記されるので末尾側の最後の1行が現在値。実測で EOF から 5〜28KB に常在、末尾256KB走査＋20sキャッシュ `transcriptAITitle` で取得。zellij CLI からペインタイトルは取れない — `dump-layout` に実行時タイトルは出ない）。末尾64KBを読み、最後の **main-chain**（`isSidechain: true` はサブエージェントの usage なのでスキップ）assistant メッセージの `message.usage`（input+cache_read+cache_creation）÷ **モデル別窓サイズ**（`contextWindow()`: fable / opus-4-7 / opus-4-8 = 1M、その他 200k。jsonl に窓サイズは記録されないため実測ベースの写像。`defaults` の `contextLimits` で上書き可）でコンテキスト%、`message.model` でモデル。
- **Ghostty AppleScript 統合**: 行クリックのジャンプに使用（後述の地雷参照）。sdef は `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`。
- **VSCode 系エディタ（2026-07 実測・VSCode 1.102.3）**: 統合ターミナル発のセッションは env の `TERM_PROGRAM=vscode` で判別（zellij は TERM_PROGRAM をスクラブせず素通しするので、zellij ペインは host 端末の値=ghostty になる）。ジャンプ先とフォーク識別は `__CFBundleIdentifier`（bundle id そのものなので `open -b` に直渡し・Cursor/Windsurf の対応表不要。ただし**キーに小文字を含む**ので env パーサのキーフィルタは isLetter 許可）。`VSCODE_GIT_ASKPASS_MAIN` は使わない（"Visual Studio Code.app" の空白で `ps -wwEp` の値が途切れる）。返信は**非対応**（外部キー注入手段が存在しない。クリックでフォーカスごとエディタが前面化するのでそこで回答してもらう — ユーザー決定）。**拡張パネル内セッション（2026-07 実測・拡張同梱 CLI 2.1.207）**: 統合ターミナルを介さず拡張が claude を直接 spawn するため **TERM_PROGRAM=vscode が付かない**（VS Code を cold start したシェルの env — ghostty や ZELLIJ_* — がそのまま漏れて写る。env だけ見ると無関係な zellij ペインに誤分類される）。判別はレジストリの **`entrypoint: "claude-vscode"`** が唯一のクリーンな事実で、`resolveBackend` はこれを全 env 事実より優先する。`__CFBundleIdentifier` は健在なのでジャンプは通常どおり `open -b`。また拡張パネルセッションは**レジストリに `status` フィールドを書かない**（ターン完了後も無し・`claude -p`/sdk-cli も同様。拡張は claude を SDK stream-json モードで駆動し、busy/idle と権限やり取りは stdout の socketpair 経由で拡張ホストのメモリに流れディスクに出ない — 2026-07 実測。daemon も非経由）ため、registry も `claude agents` も daemon も blocked/working を出さない。**代わりに transcript から回収する**（`Sources/Transcript.swift`）: blocked は末尾 main-chain の未回答 AskUserQuestion/ExitPlanMode（`blockedPending` ＝ `blockedState == .pending`）、working/idle は末尾 main-chain assistant の `stop_reason == "end_turn"` を idle とみなすターン境界判定（`transcriptTurnActive`）。`AgentFetch` が「live 源が blocked を出さず daemon worker でもないとき pending なら blocked」「merged status が unknown のとき turn 状態から working/idle」を配線する。トークン単位のリアルタイム working だけは socketpair のメモリに閉じて取れず、ターン境界が天井（Manual モードの権限承認待ちも「実行中」と区別できないため blocked にしない）。Cursor/Windsurf は未実測（ユーザー判断で検証対象外・判定は TERM_PROGRAM 主・bundleId 従で書いてある）。レジストリ・transcript は端末非依存で通常どおり。
- **zellij CLI**（`ZELLIJ_SESSION_NAME` の env 指定でヘッドレス実行）: セッションの env にある `ZELLIJ_PANE_ID`（素の整数・`ps -wwEp` で回収）で対象ペインを特定できる。zellij 0.43 にはペインID直接フォーカスの action が**無い**ので、`focus-next-pane`/`go-to-next-tab` で歩行し `list-clients`（attach 中クライアントのフォーカスペインが `terminal_N` 形式で出る）で照合する（`zellijFocusPane`）。multi-pane への送信は「対象ペインへフォーカス→`write-chars`→元のペインへフォーカス復帰」（`sendToZellijPane`）で、**attach 中クライアントがいる時のみ可**（照合が効かないため。1タブ1ペインは未 attach でも送信可）。

## ビルド & 反映の定型

```sh
./build.sh                                   # swiftc → /Applications/Shepherd.app に install
pkill -x Shepherd
env -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  /Applications/Shepherd.app/Contents/MacOS/Shepherd >/tmp/shepherd-deck.log 2>&1 &
```

- 起動時に `HERDR_*` を落とすのは**惰性の安全策**（Shepherd はもう herdr を起動しない）。`runCommand` 内でも `HERDR_` プレフィックスの env を除去している。
- SourceKit が `Cannot find type 'StreamDeck'` を出すのは単一ファイル解析のノイズ。`build.sh` が通れば無視してよい。

## 地雷リスト（この開発で踏んだもの全部）

- **`SecItemCopyMatching` は Keychain の ACL 同意ダイアログが出ると呼び出しスレッドを無期限ブロックする**（2026-07-16 実測）。Shepherd を再ビルドするとバイナリが変わり「Claude Code-credentials」への同意が再要求され、ユーザーが気付かない限りダイアログが放置 → usage fetch が `取得中…` のまま永久に固まる（`usageFetching` が下りない）。→ **token 読みは `/usr/bin/security find-generic-password` サブプロセスを第一経路にする**（Claude Code 自身の書き込み経路なので ACL 済み＝プロンプトなし・runCommand の10秒タイムアウトで最悪も有界）。直接 Keychain 読みは第二経路として残してある。
- **rebuild 経路でメインスレッド同期サブプロセスを走らせない**（2026-07-14 実測）。旧 `claudeAccount()` は5分キャッシュ切れのたび `claude auth status`（〜0.3s）を rebuild 内で同期実行し、全ビュー撤去直後だったため**空のパネルが約0.5秒画面に出て「HUD が閉じて開く」ように見えた**（フレームキャプチャで確証。ウィンドウ枠・バッファ監視には写らない）。対策は二重: ①facts 系は必ず stale-while-revalidate（prInfo と同型・`onAccountChanged`）②rebuild は**新ビューを全部構築してから旧ビューと入れ替える**（teardown-first に戻さないこと）。
- **`NSStackView.edgeInsets` は popover の contentViewController.view に直接使うと無視される**（2026-07-15 実測: インセットを 9→13→22 に変えてもポップオーバー幅が 131pt から1pxも動かず、合成ホバー＋ウィンドウ実測で確定）。パディングは**素の NSView ラッパー＋明示制約**で付ける（`showHoverTip` 参照）。あわせて `fittingSize` は**圧縮可能なラベルを潰した最小値**を返すので、採寸前に全 NSTextField の compression resistance を required にする（同関数の `harden`）。
- **非アクティブパネルでは `NSToolTip`・`NSCursor`（ポインタ変更）・`NSApp.activate` が効かない**。→ ツールチップは自前ヒント行、カーソル変更は諦め、ポップオーバー表示時は明示的に `NSApp.activate(ignoringOtherApps:)`。
- **Shepherd（決してアクティブにならない accessory app）発の AppleScript では、Ghostty の `activate window` がウィンドウ前面化だけ許可されアプリのアクティブ化を拒否されることがある**（macOS 14+ cooperative activation。ペインは見えるのにキー入力が別アプリに行く — 2026-07-08 実機報告）。→ クリック受領直後に `NSApp.yieldActivation(toApplicationWithBundleIdentifier:)` で権限を譲渡し、AppleScript 側にもアプリレベル `activate` を入れる（`jumpToZellij` / `focusGhosttyZellijWindow` 参照）。
- **Ghostty の操作は AppleScript API 一択**。`open -na` は幽霊インスタンス＋二重配送、`open -a`（-nなし）は起動済みアプリに引数を渡さない、`-e` 直接実行はシェルを介さず環境が欠落する。→ ジャンプは `new window with configuration {command}`（新規）/ `activate window`（既存、id は UserDefaults 永続化）。**Shepherd 自身が `new window` で作った window id だけを信頼**（zellij 等の既存 window id を種付けしない）。surface configuration には `initial working directory` があるので、新規セッションは worktree を cwd に指定して開ける（シェル経由不要）。初回に自動化のTCC同意ダイアログ（Shepherd→Ghostty）が出る。
- **ポップオーバー表示中・ファイルドラッグ中は `rebuild` をスキップする**。rebuild するとアンカー/ドロップ先ビューが再生成されてポップオーバーが道連れで閉じる。`refresh()` のガード（`replyPopover == nil && repoPickerPopover == nil && dropPopover == nil && Date().timeIntervalSince(lastDragAt) > 1.0`）を壊さないこと。
- **bg worker は blocked 中、質問を transcript に書かない**（assistant 行はターン完了後にまとめて flush される）。blocked bg の質問文は control socket の `needs` が唯一の源。interactive セッションは即書くので transcript から取れる（`blockedPromptFromTranscript`）。
- **bg worker のフックは起動元ペインの env を拾う**（`claude --bg` を zellij ペインから叩くと `ZELLIJ_SESSION_NAME` が status ファイルに入る）。worker に端末は無いので、`isBackground` の行は zellij 情報を捨てて `.other` に固定すること（さもないとカードのクリックが起動元ペインへのジャンプになる）。
- **zellij ペインから cold start した VSCode は `ZELLIJ_SESSION_NAME`/`ZELLIJ_PANE_ID` を全ターミナルに継承する**（2026-07-11 実機で発生）。env だけ見ると VSCode セッションが zellij に誤分類され、無関係なペインへジャンプ・誤送信する。逆の「VSCode ターミナル内の zellij」も env は同型なので、**祖先プロセス表（`processTable` → `zellijDescendant`）で「zellij server の子孫か」を見て裁定**する（`resolveBackend`）。vscode 裁定になった行の zellij フィールドは必ず捨てる（残すと `sendable` が立つ）。
- **claude セッションの Bash から cold start した VSCode は `CLAUDECODE=1`/`CLAUDE_CODE_CHILD_SESSION=1`/`CLAUDE_CODE_SESSION_ID` も継承し、その中で起動した claude は sessions レジストリも自前 transcript も書かない**（子セッション扱い・2026-07-11 probe で確認）。「VSCode 内の claude が盤面に出ない」報告はまずこれを疑う。Dock/Spotlight 起動の VSCode では起きない。
- **claude CLI は VSCode 内で走ると Claude Code 拡張（anthropic.claude-code）を自動インストールする**。以後その拡張が統合ターミナルに `CLAUDE_CODE_SSE_PORT` を注入する（拡張の有無に依存するので判別子には使わない）。
- **Apple プラットフォームバイナリ（`/bin/sleep` 等）の env は `ps -E` で読めない**（同 uid でも空・2026-07-12 実測）。homebrew 等の非プラットフォームバイナリは読める。demo-board.sh がレジストリ裏打ちの pid を `gsleep`（coreutils）で立てるのはこのため — `/bin/sleep` に戻すと実行環境チップ（runtime）が全カードから消える。
- **in-process teammate の終了は自分の jsonl 末尾から判定できない**（2026-07-14 実測）。「これから書きます」ナレーション text の後に数分のツールコール生成が続くと終了と見分けがつかず、lead 自身も誤認して代替 teammate を起動した。→ 判定は lead transcript の `idle_notification` を権威にする（アーキテクチャ節「フックは使わない」参照）。
- **subagent の tail 読み窓が最終レコードより小さいと、JSON の途中から始まってパース不能＝カードが永久 working になる**（2026-07-16 実測: Explore の最終報告は1行 17〜25KB）。→ tail 窓は 256KB、さらに30分無更新 backstop。
- **macOS の bash は 3.2** で `wait -n` が無い。
- **Inkscape は `feDropShadow` 非対応**（アイコンSVGで使うと要素が全消えする）。
- スクリーンショット系（`screencapture -i`）は撮影前に `panel.orderOut(nil)`、後で `orderFrontRegardless()` して HUD を写り込ませない。

## デバッグ手段

- **`./dev/hud-capture.sh [出力.png]`** — 実機の HUD をウィンドウ単位で PNG に撮り、パスを stdout に出す（省略時 `/tmp/shepherd-hud.png`）。CGWindowList で Shepherd の window id を引いて `screencapture -x -o -l` するので、非アクティブ・別ディスプレイ・重なりの下でも正確に撮れる。ポップオーバー表示中は `-1.png -2.png …` で全ウィンドウ撮る。**ビルド反映後の見た目確認は、ユーザーに依頼する前にまず必ずこれを実行して Read で画像を確認する**（静的なレイアウト崩れ・アイコン欠け・文字切れは自分で検出できる。ホバー・アニメーション・クリック挙動など動的な確認のみユーザーに依頼する）。Screen Recording の TCC はこのマシンのシェルに許可済み。
- **`./dev/demo-board.sh <ja|en>`** — スクリーンショット用の**完全架空のデモ盤面**を `/tmp/shepherd-demo` にステージする（デモ git repo＋worktree・生きた `gsleep` pid で裏打ちした sessions レジストリ — 行1〜3は zellij/Ghostty・行4は VSCode の env を exec 時に与えて実行環境チップと `</>` マークを写す・ai-title/usage/permission-mode/blocked質問/Artifact/subagent 入りの偽 transcript・偽 `claude`（auth/agents）と偽 `gh`（PR/CI））。起動は出力どおり: 実 Shepherd を pkill → `SHEPHERD_SESSIONS_DIR`/`SHEPHERD_PROJECTS_DIR`（main.swift の fixture シーム）＋ `-claudePath`/`-ghPath`（引数ドメイン・永続しない）＋ 英語版は `-AppleLanguages "(en)"`。**実データ・実プロジェクト名は一切写らない**（顧客リポジトリ名を docs に載せない）。列の左→右はヘッダー名のアルファベット順（`layoutColumns`）、カードの「? 質問」行は最後の assistant **テキスト**から出る（tool_use だけでは出ない）。後片付け: `pkill -f "sleep 86340"; rm -rf /tmp/shepherd-demo` → 実 Shepherd を通常起動。
- **`./dev/demo-director.sh <ja|en> [beat]`** — demo 盤面の checkout カードを busy→質問→復帰の3ビートで動かす動画用ドライバ。対話モード（人が録画しながら Enter/ポップオーバー回答で進める・要単一ペイン zellij）と、beat 指定の非対話モード（`en 0` でステージ＋全緑 → 録画中に外から `en 1` / `en 2`）。README の GIF（`docs/assets/demo-en.gif`・800px/10fps）はこの beat モード＋`screencapture -v -R <窓rect> -V 24`＋ffmpeg palettegen で再生成する。
- `SHEPHERD_DUMP=1` ＋上記 env/引数 — GUI を出さずにデモ盤面の行とツリーを stderr にダンプ（fixture の検証はまずこれ。GUI は watched dir を消すと更新が止まるので、fixture を作り直したらアプリも再起動する）。
- `/tmp/shepherd-activate.log` — ジャンプ処理のタイムスタンプ付きログ（`activateLog`）。
- `/tmp/shepherd-deck.log` — 起動時の標準出力（Stream Deck含む）。
- `log show --predicate 'subsystem == "com.mitchellh.ghostty"' --last 5m` — Ghostty 子プロセス異常終了の切り分け。
- `~/.claude/sessions/<pid>.json` / control socket の `{"op":"list"}` — 状態が合わないときの一次データ。

