import Foundation

func runTeamsTests() {
    claudeTeamsDir = testTmpDir + "/teams"

    // A fixture team: teams/session-<first8>/config.json (+ optional inbox files).
    func writeTeam(leadSessionId: String, config: String) {
        let dir = (claudeTeamsDir as NSString)
            .appendingPathComponent("session-\(leadSessionId.prefix(8))")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! config.write(toFile: (dir as NSString).appendingPathComponent("config.json"),
                          atomically: true, encoding: .utf8)
    }
    func inboxPath(leadSessionId: String, name: String) -> String {
        ((claudeTeamsDir as NSString)
            .appendingPathComponent("session-\(leadSessionId.prefix(8))") as NSString)
            .appendingPathComponent("inboxes/\(name).json")
    }

    test("teamMemberNames: the roster minus the lead") {
        let sid = "aaaa1111-2222-3333-4444-555555555555"
        writeTeam(leadSessionId: sid, config: #"""
        {"name":"session-aaaa1111","leadSessionId":"\#(sid)","members":[
          {"agentId":"team-lead@t","name":"team-lead","agentType":"team-lead"},
          {"agentId":"catalog-a@t","name":"catalog-a","agentType":"claude"},
          {"agentId":"catalog-b@t","name":"catalog-b","agentType":"claude"}
        ]}
        """#)
        expectEq(teamMemberNames(leadSessionId: sid), Set(["catalog-a", "catalog-b"]))
        expectNil(teamMemberNames(leadSessionId: "bbbb2222-0000-0000-0000-000000000000"),
                  "no team dir → nil")
        expectNil(teamMemberNames(leadSessionId: ""), "empty session id")
        // A colliding/stale dir whose config names ANOTHER lead must not read as this session's team.
        let impostor = "aaaa1111-9999-9999-9999-999999999999"   // same first 8 chars
        expectNil(teamMemberNames(leadSessionId: impostor), "leadSessionId mismatch → nil")
    }

    test("injectTeammateMessage: writes the proven inbox shape, appends, never clobbers") {
        let sid = "cccc3333-2222-3333-4444-555555555555"
        writeTeam(leadSessionId: sid, config: #"""
        {"leadSessionId":"\#(sid)","members":[{"name":"team-lead","agentType":"team-lead"},{"name":"worker","agentType":"claude"}]}
        """#)
        expect(injectTeammateMessage(leadSessionId: sid, to: "worker", text: "hello"),
               "fresh inbox → written")
        let path = inboxPath(leadSessionId: sid, name: "worker")
        var entries = (try! JSONSerialization.jsonObject(
            with: FileManager.default.contents(atPath: path)!)) as! [[String: Any]]
        expectEq(entries.count, 1)
        let e = entries[0]
        expectEq(e["from"] as? String, "team-lead", "the proven-working default sender")
        expectEq(e["text"] as? String, "hello")
        expectEq(e["msgV"] as? Int, 1)
        expectEq(e["type"] as? String, "message")
        expectEq(e["read"] as? Bool, false)
        expect((e["msg_id"] as? String)?.count == 36, "uuid-shaped msg_id")
        expect((e["msg_id"] as? String) == (e["msg_id"] as? String)?.lowercased(), "lowercase uuid")
        expect(parseUsageISODate(e["timestamp"] as? String) != nil, "parseable ISO timestamp")

        expect(injectTeammateMessage(leadSessionId: sid, to: "worker", text: "again", from: "shepherd"),
               "existing inbox → appended")
        entries = (try! JSONSerialization.jsonObject(
            with: FileManager.default.contents(atPath: path)!)) as! [[String: Any]]
        expectEq(entries.count, 2, "the first entry survives the append")
        expectEq(entries[1]["from"] as? String, "shepherd", "explicit sender override")

        // An inbox that doesn't parse belongs to a writer we don't understand — leave it alone.
        try! "not json".write(toFile: path, atomically: true, encoding: .utf8)
        expect(!injectTeammateMessage(leadSessionId: sid, to: "worker", text: "x"),
               "unparsable inbox → refused")
        expectEq(try! String(contentsOfFile: path, encoding: .utf8), "not json",
                 "and the file is untouched")

        expect(!injectTeammateMessage(leadSessionId: "dddd4444-0000-0000-0000-000000000000",
                                      to: "worker", text: "x"),
               "no team → refused")
        expect(!injectTeammateMessage(leadSessionId: sid, to: "worker", text: ""),
               "empty text → refused (a missing text crashes the receiver — measured)")
    }
}
