import AppKit

extension AppDelegate {
    // MARK: - Stream Deck

    var deckEnabled: Bool { deck != nil }

    @objc func toggleDeck() {
        if deck != nil || deckOpening {
            disableDeck()
            defaults.set(false, forKey: "deckEnabled")   // user turned it off
        } else {
            enableDeck(userInitiated: true)   // records deckEnabled=true only once the device actually opens
        }
        rebuild(rows: lastRows)
    }

    // userInitiated: the user clicked "Use Stream Deck" (so a failure earns a brief header warning
    // pill explaining why). Auto-reconnect at launch stays silent on failure — not-connected is the
    // normal state and shouldn't paint a permanent badge (A7).
    func enableDeck(userInitiated: Bool = false) {
        if deck != nil || deckOpening { return }
        deckOpening = true
        let serial = defaults.string(forKey: "deckSerial")
        prepareStaticDeckImages()
        // Always land on the top screen (column list) when the deck comes up.
        let sections = groupByRepo(lastRows ?? [])
        let keys = deckKeyLayout(sections: sections, page: .columns)
        deckQueue.async {
            // The official Elgato app grabs the device over HID; the two can't share it.
            if runCommand(["/usr/bin/pgrep", "-x", "Stream Deck"]) != nil {
                self.failOpen(L("Deck: Elgato アプリを終了して", "Deck: quit the Elgato app"), warn: userInitiated); return
            }
            guard let d = StreamDeck.open(serial: serial) else {
                self.failOpen(L("Deck: 見つかりません", "Deck: not found"), warn: userInitiated); return
            }
            // open() already reset + set brightness while probing. Start delivering key
            // presses on the main run loop, then paint the board.
            DispatchQueue.main.sync {
                d.onKey = { [weak self] key, pressed in
                    guard pressed else { return }
                    self?.handleDeckKey(key)
                }
                d.startInput()
            }
            _ = self.sendBoard(d, sections: sections, keys: keys, flashOn: true)
            DispatchQueue.main.async {
                self.deckOpening = false
                self.deckStatus = nil
                self.deckWarnUntil = nil
                defaults.set(true, forKey: "deckEnabled")   // remember for auto-reconnect
                self.deck = d
                self.deckPage = .columns
                self.deckSections = sections
                self.deckRows = sections.flatMap { $0.rows }
                self.deckKeys = keys
                self.deckFlashOn = true
                self.blinkTimer?.invalidate()
                self.blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.blinkTick() }
                self.rebuild(rows: self.lastRows)
            }
        }
    }

    private func failOpen(_ status: String, warn: Bool = false) {
        DispatchQueue.main.async {
            self.deckOpening = false
            self.deckStatus = status
            self.deckWarnUntil = warn ? Date().addingTimeInterval(8) : nil
            self.rebuild(rows: self.lastRows)
        }
    }

    func disableDeck() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard let d = deck else { deckStatus = nil; return }
        deck = nil
        deckKeys = []
        deckSections = []
        deckPage = .columns
        deckStatus = nil
        d.stopInput()
        deckQueue.async { d.close() }
    }

    func handleDeckKey(_ key: Int) {
        guard key >= 0, key < deckKeys.count else { return }
        switch deckKeys[key] {
        case .logo:
            refresh()               // the brand key doubles as a manual refresh
        case .back:
            deckPage = .columns
            renderDeck()
        case .column(let repoKey):
            deckPage = .sessions(repoKey: repoKey)
            renderDeck()
        case .session(let sessionId):
            if let row = deckRows.first(where: { $0.sessionId == sessionId }) { openRow(row) }
        case .blank:
            break
        }
    }

    // Push the current screen to the deck. Top screen = one key per repo column (key 0: logo),
    // column screen = that column's sessions in urgency order (key 0: back).
    func renderDeck() {
        guard let d = deck else { return }
        let sections = groupByRepo(lastRows ?? [])
        deckPage = resolvedDeckPage(sections: sections, page: deckPage)
        let keys = deckKeyLayout(sections: sections, page: deckPage)
        deckSections = sections
        deckRows = sections.flatMap { $0.rows }
        deckKeys = keys
        deckFlashOn = true
        deckQueue.async {
            let ok = self.sendBoard(d, sections: sections, keys: keys, flashOn: true)
            DispatchQueue.main.async {
                if !ok, self.deck === d {   // a write failed — device likely unplugged
                    self.disableDeck()
                    // It WAS connected and dropped — a real event worth a (brief) coloured warning.
                    self.deckStatus = L("Deck: 切断されました", "Deck: disconnected")
                    self.deckWarnUntil = Date().addingTimeInterval(60)
                    self.rebuild(rows: self.lastRows)
                }
            }
        }
    }

    // Runs on deckQueue. Returns false if a write failed (unplugged).
    private func sendBoard(_ d: StreamDeck, sections: [RepoSection], keys: [DeckKey], flashOn: Bool) -> Bool {
        var rowById: [String: AgentRow] = [:]
        for r in sections.flatMap({ $0.rows }) { rowById[r.sessionId] = r }
        var ok = true
        for (k, key) in keys.enumerated() {
            let jpeg: Data
            switch key {
            case .logo:
                jpeg = _deckLogo ?? deckBlankImage()
            case .back:
                jpeg = _deckBack ?? deckBlankImage()
            case .column(let repoKey):
                if let sec = sections.first(where: { repoGroupKey($0) == repoKey }) {
                    jpeg = deckColumnImage(sec, flashOn: flashOn)
                } else { jpeg = deckBlankImage() }
            case .session(let sessionId):
                if let row = rowById[sessionId] {
                    jpeg = deckAgentImage(row, flashOn: flashOn)
                } else { jpeg = deckBlankImage() }
            case .blank:
                jpeg = deckBlankImage()
            }
            if !d.setKeyImage(k, jpeg: jpeg) { ok = false }
        }
        return ok
    }

    // Blink the keys that need input — a blocked session key, or a column key holding one —
    // so "needs input" is impossible to miss, without redrawing the whole board every tick.
    func blinkTick() {
        guard let d = deck else { return }
        deckFlashOn.toggle()
        let flashOn = deckFlashOn
        let keys = deckKeys
        let sections = deckSections
        let rows = deckRows
        deckQueue.async {
            for (k, key) in keys.enumerated() {
                switch key {
                case .column(let repoKey):
                    guard let sec = sections.first(where: { repoGroupKey($0) == repoKey }),
                          sec.rows.contains(where: { $0.status == "blocked" }) else { continue }
                    d.setKeyImage(k, jpeg: self.deckColumnImage(sec, flashOn: flashOn))
                case .session(let sessionId):
                    guard let row = rows.first(where: { $0.sessionId == sessionId }),
                          row.status == "blocked" else { continue }
                    d.setKeyImage(k, jpeg: self.deckAgentImage(row, flashOn: flashOn))
                default:
                    continue
                }
            }
        }
    }

    // MARK: Stream Deck key rendering (reuses style()/Cat from the HUD)

    private func drawKeyText(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat, px: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        var s = text as NSString
        while s.length > 1 && s.size(withAttributes: attrs).width > px - 6 { s = s.substring(to: s.length - 1) as NSString }
        let h = s.size(withAttributes: attrs).height
        s.draw(in: NSRect(x: 0, y: centerY - h / 2, width: px, height: h), withAttributes: attrs)
    }

    // Greedy character wrap (titles are mostly Japanese — no word boundaries to break on) into
    // at most `maxLines` lines that fit the key; overflow past the last line becomes an ellipsis.
    private func wrapKeyText(_ text: String, size: CGFloat, weight: NSFont.Weight, maxLines: Int, px: CGFloat) -> [String] {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        var lines: [String] = []
        var current = ""
        for ch in text {
            let candidate = current + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > px - 6 && !current.isEmpty {
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[maxLines - 1] = lines[maxLines - 1].dropLast() + "…"
        }
        return lines
    }

    // A session key. The whole key is painted in the status colour (the HUD's dot colour) —
    // no status bar or status word — which frees the face for a two-line title plus one info
    // line (#issue · time in this status · changed files). Blocked keys blink by dropping to
    // the dark base every other tick.
    func deckAgentImage(_ row: AgentRow, flashOn: Bool) -> Data {
        let st = style(for: row.status)
        let dark = row.status == "blocked" && !flashOn   // blink = dark phase
        let bg = dark ? Cat.base : st.dot
        let fg = dark ? st.dot : Cat.crust
        // The same title the HUD card leads with: the work title (activity: ai-title → last
        // prompt), falling back to row.label only when there is none — the label is a workspace
        // name, often an id-like string that means nothing on a 72px key.
        var label = (row.activity.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }) ?? row.label
        if label.hasPrefix("⚙ ") { label = String(label.dropFirst(2)) }
        if let n = row.issueNo, let r = label.range(of: "#\(n)") {
            label.removeSubrange(r)
            label = label.trimmingCharacters(in: .whitespaces)
        }
        var info: [String] = []
        if let n = row.issueNo { info.append("#\(n)") }
        if row.statusSince > Date.distantPast {
            info.append(formatDuration(Date().timeIntervalSince(row.statusSince)))
        }
        if let c = row.changedFiles, c > 0 { info.append("±\(c)") }
        return StreamDeck.encodeKeyImage { px in
            bg.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
            for (i, line) in self.wrapKeyText(label, size: 12, weight: .semibold, maxLines: 2, px: px).enumerated() {
                self.drawKeyText(line, size: 12, weight: .semibold, color: fg,
                                 centerY: px * (0.78 - 0.22 * CGFloat(i)), px: px)
            }
            self.drawKeyText(info.joined(separator: " "), size: 10, weight: .medium,
                             color: fg.withAlphaComponent(0.8), centerY: px * 0.16, px: px)
        } ?? Data()
    }

    // A column key (top screen): repo name on two lines, one status-coloured dot per session
    // (the column's health at a glance), and the session count. Blinks in the blocked colour
    // while any session inside needs input.
    func deckColumnImage(_ section: RepoSection, flashOn: Bool) -> Data {
        let hot = section.rows.contains { $0.status == "blocked" } && flashOn
        let bg = hot ? Cat.peach : Cat.base
        let fg = hot ? Cat.crust : Cat.text
        let name = section.header ?? L("その他", "other")
        let rows = section.rows
        return StreamDeck.encodeKeyImage { px in
            bg.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
            for (i, line) in self.wrapKeyText(name, size: 12, weight: .semibold, maxLines: 2, px: px).enumerated() {
                self.drawKeyText(line, size: 12, weight: .semibold, color: fg,
                                 centerY: px * (0.80 - 0.22 * CGFloat(i)), px: px)
            }
            let maxDots = 7
            let dotCount = min(rows.count, maxDots)
            let dot: CGFloat = 7, gap: CGFloat = 3
            let totalW = CGFloat(dotCount) * dot + CGFloat(max(0, dotCount - 1)) * gap
            var x = (px - totalW) / 2
            for row in rows.prefix(maxDots) {
                (hot ? Cat.crust : style(for: row.status).dot).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: px * 0.32 - dot / 2, width: dot, height: dot)).fill()
                x += dot + gap
            }
            self.drawKeyText(L("\(rows.count)件", "\(rows.count)"), size: 10, weight: .medium,
                             color: hot ? Cat.crust : Cat.subtext, centerY: px * 0.12, px: px)
        } ?? Data()
    }

    // Rasterize the static key faces (logo / back) once, on the main thread — markIcon is a lazy
    // NSImage, not safe to first-touch from deckQueue. After this, deckQueue only reads Data.
    func prepareStaticDeckImages() {
        let icon = markIcon
        if _deckLogo == nil {
            _deckLogo = StreamDeck.encodeKeyImage { px in
                Cat.base.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
                let side = px * 0.60
                icon?.draw(in: NSRect(x: (px - side) / 2, y: px * 0.30, width: side, height: side))
                self.drawKeyText("Shepherd", size: 9, weight: .medium, color: Cat.subtext, centerY: px * 0.14, px: px)
            }
        }
        if _deckBack == nil {
            _deckBack = StreamDeck.encodeKeyImage { px in
                Cat.base.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
                let side = px * 0.48
                icon?.draw(in: NSRect(x: (px - side) / 2, y: px * 0.40, width: side, height: side))
                self.drawKeyText(L("‹ 戻る", "‹ back"), size: 12, weight: .semibold, color: Cat.text, centerY: px * 0.18, px: px)
            }
        }
    }

    func deckBlankImage() -> Data {
        if let d = _deckBlank { return d }
        let d = StreamDeck.encodeKeyImage { px in
            Cat.base.setFill(); NSRect(x: 0, y: 0, width: px, height: px).fill()
        } ?? Data()
        _deckBlank = d
        return d
    }

}
