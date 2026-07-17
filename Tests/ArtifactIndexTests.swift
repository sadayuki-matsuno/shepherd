import Foundation

// Fixture builders for Artifact publish transcript lines.
private func toolUseLine(id: String, favicon: String? = "🐏", desc: String? = "設計ドキュメント") -> String {
    var input = "{\"file_path\":\"/tmp/x.html\""
    if let favicon = favicon { input += ",\"favicon\":\"\(favicon)\"" }
    if let desc = desc { input += ",\"description\":\"\(desc)\"" }
    input += "}"
    return """
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"\(id)","name":"Artifact","input":\(input)}]}}
    """
}

private func toolResultLine(id: String, url: String, ts: String = "2026-07-17T01:00:00Z",
                            cwd: String = "/tmp/fake/myrepo") -> String {
    """
    {"type":"user","timestamp":"\(ts)","cwd":"\(cwd)","message":{"content":[{"type":"tool_result","tool_use_id":"\(id)","content":[{"type":"text","text":"Published /tmp/x.html at \(url)"}]}]}}
    """
}

private let artifactURL = "https://claude.ai/code/artifact/11111111-2222-3333-4444-555555555555"

func runArtifactIndexTests() {
    claudeProjectsDir = testTmpDir + "/projects"
    ArtifactIndex.indexPath = testTmpDir + "/artifact-index.json"

    test("artifactSlug") {
        expectEq(artifactSlug(from: artifactURL), "11111111-2222-3333-4444-555555555555")
        expectEq(artifactSlug(from: "https://claude.ai/code/artifact/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                 "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "lowercased")
        expectNil(artifactSlug(from: "https://claude.ai/code/artifact/not-a-uuid"))
        expectNil(artifactSlug(from: "https://github.com/o/r/pull/1"))
    }

    test("parseFrames: live shape (2026-07-17 probe)") {
        let body = """
        {"frames":[{"slug":"fdeeabb5-9c4a-4341-808e-478d6599015d","title":"設計ドキュメント",
          "favicon":"📦","label":"x","rel":"mine","view_count":10,
          "updatedAt":"2026-07-16T09:37:05Z","created_at":"2026-07-16T09:37:05Z","audience":"owner"},
         {"slug":"a250c12e-d065-429d-84d2-98ee69603a02","title":"dead one","rel":"mine","softDeleted":true}],
         "thumbsEnabled":false}
        """
        let obj = try? JSONSerialization.jsonObject(with: body.data(using: .utf8)!)
        let frames = parseFrames(obj)
        expectEq(frames?.count, 2)
        expectEq(frames?[0].slug, "fdeeabb5-9c4a-4341-808e-478d6599015d")
        expectEq(frames?[0].favicon, "📦")
        expectEq(frames?[0].softDeleted, false, "absent softDeleted reads false")
        expect(frames?[0].updatedAt != nil, "ISO updatedAt parses")
        expectEq(frames?[1].softDeleted, true)
    }

    test("parseFrames: defensive shapes") {
        expectNil(parseFrames("garbage"), "non-JSON-collection input")
        expectNil(parseFrames(["nope": 1] as [String: Any]), "dict without frames array")
        // Bare array + epoch-ms updatedAt + alternative keys survive.
        let arr: [[String: Any]] = [["id": "AAAAAAAA-0000-0000-0000-000000000000",
                                     "updated_at": 1784194625000 as NSNumber, "soft_deleted": true]]
        let frames = parseFrames(arr)
        expectEq(frames?.count, 1)
        expectEq(frames?[0].slug, "aaaaaaaa-0000-0000-0000-000000000000")
        expectEq(frames?[0].softDeleted, true)
        expect(abs((frames?[0].updatedAt?.timeIntervalSince1970 ?? 0) - 1784194625) < 1, "epoch ms")
    }

    test("mergedRecord: API wins title/updatedAt/softDeleted, transcript wins favicon") {
        let publish = ArtifactPublish(url: artifactURL, favicon: "🐏", title: "publish title",
                                      timestamp: "2026-07-15T00:00:00Z", cwd: "/tmp/fake/myrepo")
        var rec = mergedRecord(nil, publish: publish, repoName: "myrepo")
        expectEq(rec?.slug, "11111111-2222-3333-4444-555555555555")
        expectEq(rec?.title, "publish title")
        expectEq(rec?.favicon, "🐏")
        expectEq(rec?.repoName, "myrepo")
        expect(rec?.updatedAt != nil, "publish timestamp fills updatedAt while API-unseen")

        let frame = FrameEntry(slug: rec!.slug, title: "api title", favicon: "📦", rel: "mine",
                               updatedAt: Date(timeIntervalSince1970: 1_800_000_000), softDeleted: true)
        rec = mergedRecord(rec, frame: frame)
        expectEq(rec?.title, "api title", "API title wins")
        expectEq(rec?.favicon, "🐏", "transcript favicon survives the API merge")
        expectEq(rec?.softDeleted, true)
        expectEq(rec?.updatedAt, Date(timeIntervalSince1970: 1_800_000_000))
        expect(rec?.lastSeenInAPI != nil, "API merge stamps lastSeenInAPI")

        // After the record was seen in the API, a transcript publish no longer moves updatedAt…
        let later = ArtifactPublish(url: artifactURL, favicon: "🦄", title: nil,
                                    timestamp: "2026-07-17T09:00:00Z", cwd: nil)
        rec = mergedRecord(rec, publish: later, repoName: nil)
        expectEq(rec?.updatedAt, Date(timeIntervalSince1970: 1_800_000_000), "API updatedAt is canonical")
        expectEq(rec?.favicon, "🦄", "…but the favicon still follows the newest publish")

        // API-only favicon fills a favicon-less record.
        let bare = mergedRecord(nil, frame: frame)
        expectEq(bare.favicon, "📦")
        expectNil(mergedRecord(nil, publish: ArtifactPublish(url: "https://a.com/x"), repoName: nil),
                  "non-artifact URL never makes a record")
    }

    test("artifactPublishesFromSlice: pairing, timestamp, cwd") {
        let lines = [
            toolUseLine(id: "tu1"),
            toolResultLine(id: "tu1", url: artifactURL),
            // An unpaired "Published … at" (a fixture being read back) must NOT count.
            """
            {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"other","content":[{"type":"text","text":"Published /y at https://claude.ai/code/artifact/99999999-9999-9999-9999-999999999999"}]}]}}
            """,
        ]
        let pubs = artifactPublishesFromSlice(lines.joined(separator: "\n"))
        expectEq(pubs.count, 1)
        expectEq(pubs.first?.url, artifactURL)
        expectEq(pubs.first?.favicon, "🐏")
        expectEq(pubs.first?.title, "設計ドキュメント")
        expectEq(pubs.first?.timestamp, "2026-07-17T01:00:00Z")
        expectEq(pubs.first?.cwd, "/tmp/fake/myrepo")
    }

    test("linksFromTranscriptSlice still carries publishes (shared pairing)") {
        let links = linksFromTranscriptSlice([toolUseLine(id: "tu1"),
                                              toolResultLine(id: "tu1", url: artifactURL)].joined(separator: "\n"))
        expectEq(links.count, 1)
        expectEq(links.first?.favicon, "🐏")
        expectEq(links.first?.title, "設計ドキュメント")
    }

    test("repoNameFromPath") {
        expectEq(repoNameFromPath("/Users/x/ghq/github.com/o/shepherd/.claude/worktrees/wt-1"), "shepherd")
        expectEq(repoNameFromPath("/Users/x/ghq/github.com/o/shepherd"), "shepherd")
        expectNil(repoNameFromPath(""))
    }

    test("shelfListOrder: query filter + pinned-first + newest-first") {
        func rec(_ slug: String, title: String?, repo: String?, at: TimeInterval?) -> ArtifactRecord {
            var r = ArtifactRecord(slug: slug, url: "https://claude.ai/code/artifact/\(slug)")
            r.title = title; r.repoName = repo
            r.updatedAt = at.map(Date.init(timeIntervalSince1970:))
            return r
        }
        let records = [
            rec("aaaa", title: "配送見取り図", repo: "mailer", at: 100),
            rec("bbbb", title: "検証レポート", repo: "lobby", at: 300),
            rec("cccc", title: "設計ドキュメント", repo: "mailer", at: 200),
            rec("dddd", title: nil, repo: nil, at: nil),
        ]
        expectEq(shelfListOrder(records, pins: [], query: "").map(\.slug),
                 ["bbbb", "cccc", "aaaa", "dddd"], "newest first, nil updatedAt last")
        expectEq(shelfListOrder(records, pins: ["aaaa"], query: "").map(\.slug),
                 ["aaaa", "bbbb", "cccc", "dddd"], "pinned floats to the top")
        expectEq(shelfListOrder(records, pins: [], query: "mailer").map(\.slug),
                 ["cccc", "aaaa"], "repo name matches")
        expectEq(shelfListOrder(records, pins: [], query: "設計").map(\.slug), ["cccc"], "title matches")
        expectEq(shelfListOrder(records, pins: [], query: "dd").map(\.slug), ["dddd"], "slug prefix matches")
        expectEq(shelfListOrder(records, pins: ["cccc"], query: "レポート").map(\.slug), ["bbbb"],
                 "filter applies before pinning")
        expectEq(shelfListOrder(records, pins: [], query: "", repoFilter: "mailer").map(\.slug),
                 ["cccc", "aaaa"], "repo filter: exact repo")
        expectEq(shelfListOrder(records, pins: [], query: "", repoFilter: "").map(\.slug),
                 ["dddd"], "repo filter: unattributed sentinel")
        expectEq(shelfListOrder(records, pins: [], query: "設計", repoFilter: "lobby").map(\.slug),
                 [], "repo filter and query compose")
    }

    test("shelfDateText") {
        expectEq(shelfDateText(nil), "—")
        expectEq(shelfDateText(ISO8601DateFormatter().date(from: "2025-11-02T12:00:00Z")).count,
                 "yyyy/MM/dd".count, "always yyyy/MM/dd")
        // Rendered in local time — build the expectation with the same calendar.
        let d = ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z")!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        expectEq(shelfDateText(d), String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
    }

    test("ArtifactIndex: scan → persist → incremental append") {
        ArtifactIndex.indexPath = testTmpDir + "/artifact-index-scan.json"
        let projects = testTmpDir + "/artifact-projects"
        let dir = projects + "/" + sanitizeCwd("/tmp/fake/myrepo")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let jsonl = dir + "/sess-artifact-1.jsonl"
        try! ([toolUseLine(id: "tu1"), toolResultLine(id: "tu1", url: artifactURL)]
            .joined(separator: "\n") + "\n").write(toFile: jsonl, atomically: true, encoding: .utf8)

        let index = ArtifactIndex()
        index.scanTranscripts(projectsDir: projects)
        var recs = index.snapshot()
        expectEq(recs.count, 1)
        expectEq(recs.first?.favicon, "🐏")
        expectEq(recs.first?.repoName, "myrepo", "path heuristic when the cwd doesn't exist")

        // Persisted: a fresh instance loads the same record from disk.
        let reloaded = ArtifactIndex()
        expectEq(reloaded.snapshot().count, 1, "index file round-trips")

        // Append a redeploy with a new favicon — only the delta is read, the record updates.
        // (Sleep 1.1s so the file mtime visibly changes: HFS+/APFS mtime granularity can hide a
        // same-second append from the size+mtime change check only if size also matched — size
        // changes here, but keep the mtime honest anyway.)
        let fh = FileHandle(forWritingAtPath: jsonl)!
        fh.seekToEndOfFile()
        fh.write(([toolUseLine(id: "tu2", favicon: "🦄", desc: "更新版"),
                   toolResultLine(id: "tu2", url: artifactURL, ts: "2026-07-17T02:00:00Z")]
            .joined(separator: "\n") + "\n").data(using: .utf8)!)
        try? fh.close()
        index.scanTranscripts(projectsDir: projects)
        recs = index.snapshot()
        expectEq(recs.count, 1, "same slug upserts")
        expectEq(recs.first?.favicon, "🦄", "delta scan enriched the record")
    }

    test("ArtifactIndex: partial tail line is not consumed, recovered on completion") {
        ArtifactIndex.indexPath = testTmpDir + "/artifact-index-partial.json"
        let projects = testTmpDir + "/artifact-projects-partial"
        let dir = projects + "/" + sanitizeCwd("/tmp/fake/otherrepo")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let jsonl = dir + "/sess-artifact-2.jsonl"
        let full = toolUseLine(id: "tu1") + "\n" + toolResultLine(id: "tu1", url: artifactURL) + "\n"
        // Write all but the trailing half of the last line — a writer caught mid-record.
        let cut = full.index(full.endIndex, offsetBy: -30)
        try! String(full[..<cut]).write(toFile: jsonl, atomically: true, encoding: .utf8)
        let index = ArtifactIndex()
        index.scanTranscripts(projectsDir: projects)
        expectEq(index.snapshot().count, 0, "mid-write record not consumed")
        // Complete the line; the next scan re-reads from the partial line's head.
        let fh = FileHandle(forWritingAtPath: jsonl)!
        fh.seekToEndOfFile()
        fh.write(String(full[cut...]).data(using: .utf8)!)
        try? fh.close()
        index.scanTranscripts(projectsDir: projects)
        expectEq(index.snapshot().count, 1, "completed record recovered")
    }

    test("redeploy pulse: delta republish stamps artifactPulseAt") {
        let cwd = "/tmp/fake/pulserepo"
        let sess = "sess-pulse-1"
        writeTranscript(cwd: cwd, sessionId: sess, lines: [
            toolUseLine(id: "tu1"), toolResultLine(id: "tu1", url: artifactURL, cwd: cwd),
        ])
        _ = extractLinksFromTranscript(cwd: cwd, sessionId: sess)
        factsLock.lock(); let firstPulse = artifactPulseAt[sess]; factsLock.unlock()
        expectNil(firstPulse, "first full scan never pulses")

        let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
        let fh = FileHandle(forWritingAtPath: dir + "/\(sess).jsonl")!
        fh.seekToEndOfFile()
        fh.write(([toolUseLine(id: "tu2", favicon: "🔁"),
                   toolResultLine(id: "tu2", url: artifactURL, cwd: cwd)].joined(separator: "\n") + "\n")
            .data(using: .utf8)!)
        try? fh.close()
        _ = extractLinksFromTranscript(cwd: cwd, sessionId: sess)
        factsLock.lock(); let pulsed = artifactPulseAt[sess]; factsLock.unlock()
        expect(pulsed != nil, "republish of a known URL pulses")
    }
}
