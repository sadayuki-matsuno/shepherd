import Foundation

func runTranscriptTests() {
    // Point transcript reads at this run's scratch directory.
    claudeProjectsDir = testTmpDir + "/projects"

    test("sanitizeCwd") {
        expectEq(sanitizeCwd("/Users/x/.ghq/github.com/o/r"), "-Users-x--ghq-github-com-o-r")
        expectEq(sanitizeCwd("abc123"), "abc123", "alphanumerics survive")
        expectEq(sanitizeCwd("a b.c"), "a-b-c", "space and dot become dashes")
    }

    test("validHTTPURL") {
        expectEq(validHTTPURL("https://github.com/o/r/pull/1")?.absoluteString, "https://github.com/o/r/pull/1")
        expectEq(validHTTPURL("https://claude.ai/x。")?.absoluteString, "https://claude.ai/x", "full-width period trimmed")
        expectEq(validHTTPURL("https://a.com/b),")?.absoluteString, "https://a.com/b", "trailing punctuation trimmed")
        expectNil(validHTTPURL("ftp://a.com/b"), "non-http scheme")
        expectNil(validHTTPURL("https://"), "no host")
        expectNil(validHTTPURL("not a url"))
    }

    test("linksFromText: HERD markers win") {
        let text = """
        HERD_ARTIFACT: https://claude.ai/code/artifact/11111111-2222-3333-4444-555555555555
        some noise https://github.com/other/repo/pull/99
        HERD_PR: https://github.com/o/r/pull/12
        """
        let links = linksFromText(text)
        expectEq(links.count, 2)
        expectEq(links.first { $0.label == "PR" }?.url, "https://github.com/o/r/pull/12",
                 "marker PR wins over the bare fallback URL")
        expectEq(links.first { $0.label == "Artifact" }?.url,
                 "https://claude.ai/code/artifact/11111111-2222-3333-4444-555555555555")
    }

    test("linksFromText: capture stops at glued annotations") {
        let links = linksFromText("HERD_PR: https://github.com/o/r/pull/7（メモ付き）")
        expectEq(links.first?.url, "https://github.com/o/r/pull/7", "full-width paren not swallowed")
    }

    test("linksFromText: fallback anchors artifact URLs on the UUID") {
        let text = "公開しました → https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee（favicon 🐏 固定）"
        let links = linksFromText(text)
        expectEq(links.count, 1)
        expectEq(links.first?.url, "https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    test("linksFromText: dedupes by URL, last PR wins") {
        let text = """
        https://github.com/o/r/pull/1
        https://github.com/o/r/pull/2
        https://github.com/o/r/pull/2
        """
        let links = linksFromText(text)
        expectEq(links.map { $0.url }, ["https://github.com/o/r/pull/2"], "fallback PR takes the last match only")
    }

    test("toolResultText") {
        expectEq(toolResultText("plain"), "plain")
        expectEq(toolResultText([["type": "text", "text": "a"], ["type": "text", "text": "b"]]), "a\nb")
        expectEq(toolResultText(nil), "")
        expectEq(toolResultText(42), "")
    }

    test("linksFromTranscriptSlice: assistant text and Artifact results qualify") {
        let slice = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"PRです https://github.com/o/r/pull/42"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Artifact","id":"tu1","input":{"favicon":"🐏","description":"design doc"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"Published /tmp/x.html at https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}"#,
        ].joined(separator: "\n")
        let links = linksFromTranscriptSlice(slice)
        expectEq(links.count, 2)
        expectEq(links.first { $0.label == "PR" }?.url, "https://github.com/o/r/pull/42")
        let artifact = links.first { $0.label == "Artifact" }
        expectEq(artifact?.url, "https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        expectEq(artifact?.favicon, "🐏", "favicon paired via tool_use_id")
        expectEq(artifact?.title, "design doc", "description paired via tool_use_id")
    }

    test("linksFromTranscriptSlice: URLs the agent was merely shown are skipped") {
        let slice = [
            // A read/fetch tool_result echoing a URL (no "Published … at" shape, no markers).
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":"doc says: Published widely. see https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nend"}]}}"#,
            // A plain user prompt containing a URL.
            #"{"type":"user","message":{"content":[{"type":"text","text":"読んで https://github.com/o/r/pull/5"}]}}"#,
        ].joined(separator: "\n")
        expectEq(linksFromTranscriptSlice(slice).count, 0)
    }

    test("linksFromTranscriptSlice: HERD markers in tool_results are NOT trusted") {
        // A tool_result is text the agent merely READ (a file, a grep hit) — reading Shepherd's own
        // test fixtures put dummy HERD markers into a real session's transcript and produced a 404
        // Artifact link on the card (2026-07-08). Only the agent's own speech may carry markers.
        let slice = [
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"HERD_PR: https://github.com/o/r/pull/8"}]}}"#,
            // The real-world shape: sed/Read output of a test fixture file.
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"HERD_ARTIFACT: https://claude.ai/code/artifact/11111111-2222-3333-4444-555555555555\nsome noise"}]}}"#,
        ].joined(separator: "\n")
        expectEq(linksFromTranscriptSlice(slice).count, 0)
    }

    test("linksFromTranscriptSlice: HERD markers in assistant text still qualify") {
        let slice = #"{"type":"assistant","message":{"content":[{"type":"text","text":"HERD_PR: https://github.com/o/r/pull/8"}]}}"#
        expectEq(linksFromTranscriptSlice(slice).first?.url, "https://github.com/o/r/pull/8")
    }

    test("linksFromTranscriptSlice: fenced code blocks in assistant text are quotes, not speech") {
        // Explaining this very extractor, the agent quoted a fixture marker inside a ``` block —
        // that produced a fake 404 Artifact link on the session's own card (2026-07-08).
        let quoted = "こういう行が書いてあります：\\n```\\nHERD_ARTIFACT: https://claude.ai/code/artifact/11111111-2222-3333-4444-555555555555\\n```\\n以上"
        let slice = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(quoted)\"}]}}"
        expectEq(linksFromTranscriptSlice(slice).count, 0)
        // …but a marker in plain prose around a fence still counts.
        let mixed = "```\\nnoise\\n```\\nHERD_PR: https://github.com/o/r/pull/9"
        let slice2 = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(mixed)\"}]}}"
        expectEq(linksFromTranscriptSlice(slice2).first?.url, "https://github.com/o/r/pull/9")
    }

    test("linksFromTranscriptSlice: 'Published … at' counts only from the Artifact tool's own result") {
        // A read/sed tool_result of a file that happens to contain the literal shape (Shepherd's
        // own test fixtures) must not qualify — only a result paired to an Artifact tool_use does.
        let unpaired = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bash1","content":"Published /tmp/x.html at https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}"#
        expectEq(linksFromTranscriptSlice(unpaired).count, 0)
    }

    test("linksFromTranscriptSlice: redeploy enriches the earlier bare link") {
        let slice = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Artifact","id":"tu2","input":{"favicon":"🧩","description":"v2"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":"Published /tmp/x.html at https://claude.ai/code/artifact/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}"#,
        ].joined(separator: "\n")
        let links = linksFromTranscriptSlice(slice)
        expectEq(links.count, 1, "same URL upserts, not duplicates")
        expectEq(links.first?.favicon, "🧩")
        expectEq(links.first?.title, "v2")
    }

    test("cleanUserPrompt") {
        expectNil(cleanUserPrompt(nil))
        expectNil(cleanUserPrompt("  "))
        expectNil(cleanUserPrompt("<task-notification>done</task-notification>"), "machine message")
        expectNil(cleanUserPrompt("<command-name>/foo</command-name>"), "slash-command wrapper")
        expectNil(cleanUserPrompt("Caveat: the messages below were generated"), "caveat wrapper")
        expectEq(cleanUserPrompt("複数行の\n指示です"), "複数行の 指示です", "newlines squashed")
        let long = String(repeating: "a", count: 130)
        expectEq(cleanUserPrompt(long)?.count, 120, "truncated to 120 chars")
    }

    test("contextWindow: substring map, [1m] suffix, override, adaptive escalation") {
        expectEq(contextWindow(model: "claude-haiku-4-5-20251001"), 200_000)
        expectEq(contextWindow(model: "claude-sonnet-5"), 200_000)
        expectEq(contextWindow(model: "claude-fable-5"), 1_000_000, "fable measured at 435k on this machine")
        expectEq(contextWindow(model: "claude-opus-4-8"), 1_000_000, "opus-4-8 measured at 948k")
        expectEq(contextWindow(model: "claude-opus-4-7"), 1_000_000, "opus-4-7 measured at 676k")
        expectEq(contextWindow(model: "claude-sonnet-5[1m]"), 1_000_000, "an explicit [1m] tag always wins")
        expectEq(contextWindow(model: nil), 200_000)
        expectEq(contextWindow(model: "claude-sonnet-5", observedTotal: 250_000), 1_000_000,
                 "observed usage above 200k disproves the 200k window")
        expectEq(contextWindow(model: "claude-sonnet-5", observedTotal: 190_000), 200_000)
        contextLimitOverrides = ["fable": 200_000]
        expectEq(contextWindow(model: "claude-fable-5"), 200_000, "defaults override beats the built-in map")
        contextLimitOverrides = [:]
    }

    test("readTranscriptContext: model + context % from the last usage") {
        let cwd = "/tmp/proj-ctx"
        writeTranscript(cwd: cwd, sessionId: "ctx-1", lines: [
            #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":50000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}}"#,
            #"{"type":"user","message":{"content":"no usage here"}}"#,
        ])
        let (model, pct, advisor) = readTranscriptContext(cwd: cwd, sessionId: "ctx-1")
        expectEq(model?.name, "FABLE", "latest assistant message wins")
        expectEq(pct, Double(160_000) / 1_000_000.0, "fable-5 divides by its 1M window, not 200k")
        expectNil(advisor, "no advisorModel field → no advisor")
        writeTranscript(cwd: cwd, sessionId: "ctx-2", lines: [
            #"{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ])
        expectEq(readTranscriptContext(cwd: cwd, sessionId: "ctx-2").pct, 0.5, "200k models keep the 200k window")
        let missing = readTranscriptContext(cwd: cwd, sessionId: "nope")
        expectNil(missing.model)
        expectNil(missing.pct)
        expectNil(missing.advisor)
    }

    test("readTranscriptContext: advisorModel (line-level field) becomes the advisor badge") {
        // Advisor-paired sessions stamp every assistant line with a top-level "advisorModel"
        // (measured 2026-07-15, `claude -p --advisor opus`). Same field appears in subagent
        // transcripts (the session setting propagates down).
        let cwd = "/tmp/proj-ctx"
        writeTranscript(cwd: cwd, sessionId: "ctx-adv", lines: [
            #"{"type":"assistant","advisorModel":"claude-opus-4-8","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ])
        let r = readTranscriptContext(cwd: cwd, sessionId: "ctx-adv")
        expectEq(r.model?.name, "SONNET", "main model is still the message.model")
        expectEq(r.advisor?.name, "OPUS", "advisorModel resolves through the same model map")
    }

    test("readTranscriptContext: sidechain (subagent) usage is ignored") {
        let cwd = "/tmp/proj-ctx"
        writeTranscript(cwd: cwd, sessionId: "ctx-3", lines: [
            #"{"type":"assistant","message":{"model":"claude-fable-5","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":190000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ])
        let r = readTranscriptContext(cwd: cwd, sessionId: "ctx-3")
        expectEq(r.model?.name, "FABLE", "a trailing subagent line must not override the main chain")
        expectEq(r.pct, 0.1, "100k of fable's 1M window, not the subagent's usage")
    }

    test("readTranscriptContext: a subagent's OWN transcript keeps its sidechain lines") {
        // Every assistant record in agent-<id>.jsonl carries isSidechain:true (measured
        // 2026-07-11), so the main-chain filter above must not apply when the transcript being
        // read IS the subagent's — or its card never gets a model chip or context gauge.
        let cwd = "/tmp/proj-ctx"
        let key = "parent-1/subagents/agent-abc123"
        writeTranscript(cwd: cwd, sessionId: key, lines: [
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ])
        let r = readTranscriptContext(cwd: cwd, sessionId: key)
        expectEq(r.model?.name, "HAIKU", "the agent's own model reaches its card")
        expectEq(r.pct, 0.5, "and so does its own context usage")
    }

    test("extractLinksFromTranscript: incremental scan merges new links") {
        let cwd = "/tmp/proj-inc"
        let sid = "inc-1"
        writeTranscript(cwd: cwd, sessionId: sid, lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"https://github.com/o/r/pull/1"}]}}"#,
        ])
        expectEq(extractLinksFromTranscript(cwd: cwd, sessionId: sid).map { $0.url },
                 ["https://github.com/o/r/pull/1"])
        // Append a new deliverable; the next call must read only the delta yet keep the old link.
        let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
        let path = (dir as NSString).appendingPathComponent("\(sid).jsonl")
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write((#"{"type":"assistant","message":{"content":[{"type":"text","text":"HERD_PR: https://github.com/o/r/pull/2"}]}}"# + "\n").data(using: .utf8)!)
        try! fh.close()
        let merged = extractLinksFromTranscript(cwd: cwd, sessionId: sid).map { $0.url }
        expectEq(Set(merged), Set(["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"]))
        expect(transcriptLinksCache[sid] != nil, "offset cached for the next delta read")
    }

    test("readTranscriptAITitle: last ai-title line wins") {
        let cwd = "/tmp/proj-ai-title"
        writeTranscript(cwd: cwd, sessionId: "t-1", lines: [
            #"{"type":"ai-title","aiTitle":"最初のタイトル","sessionId":"t-1"}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"次の質問"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Zellijペインタイトル表示の問題を検討","sessionId":"t-1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"調べます"}]}}"#,
        ])
        expectEq(readTranscriptAITitle(cwd: cwd, sessionId: "t-1"), "Zellijペインタイトル表示の問題を検討")
    }

    test("readTranscriptAITitle: nil without ai-title lines / missing file / blank title") {
        let cwd = "/tmp/proj-ai-title"
        writeTranscript(cwd: cwd, sessionId: "t-2", lines: [
            #"{"type":"user","message":{"content":[{"type":"text","text":"質問だけ"}]}}"#,
        ])
        expectNil(readTranscriptAITitle(cwd: cwd, sessionId: "t-2"), "no ai-title lines")
        expectNil(readTranscriptAITitle(cwd: cwd, sessionId: "gone"), "missing transcript")
        expectNil(readTranscriptAITitle(cwd: "", sessionId: "t-2"), "empty cwd")
        writeTranscript(cwd: cwd, sessionId: "t-3", lines: [
            #"{"type":"ai-title","aiTitle":"生きてるタイトル","sessionId":"t-3"}"#,
            #"{"type":"ai-title","aiTitle":"  ","sessionId":"t-3"}"#,
        ])
        expectEq(readTranscriptAITitle(cwd: cwd, sessionId: "t-3"), "生きてるタイトル",
                 "blank ai-title is skipped, earlier one survives")
    }

    test("lastUserPromptFromTranscript: skips tool turns and machine messages") {
        let cwd = "/tmp/proj-prompt"
        writeTranscript(cwd: cwd, sessionId: "p-1", lines: [
            #"{"type":"user","message":{"content":[{"type":"text","text":"本物の指示です"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"やります"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"tool output"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>noise</system-reminder>"}]}}"#,
        ])
        expectEq(lastUserPromptFromTranscript(cwd: cwd, sessionId: "p-1"), "本物の指示です")
    }

    test("lastAssistantTextFromTranscript: latest non-empty assistant text") {
        let cwd = "/tmp/proj-assist"
        writeTranscript(cwd: cwd, sessionId: "a-1", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"古い返答"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"最新の返答です"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{}}]}}"#,
        ])
        expectEq(lastAssistantTextFromTranscript(cwd: cwd, sessionId: "a-1"), "最新の返答です",
                 "tool-only turns are skipped")
    }

    test("blockedResolved: a still-open prompt stays blocked; an answered or Ctrl+C'd one is resolved") {
        let cwd = "/tmp/proj-blocked"
        let question = #"{"type":"assistant","message":{"content":[{"type":"text","text":"どちらにしますか"},{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{}}]}}"#
        // Genuinely blocked: the question tool_use is the last main-chain record.
        writeTranscript(cwd: cwd, sessionId: "open", lines: [
            #"{"type":"user","message":{"content":"実装して"}}"#,
            question,
        ])
        expect(!blockedResolved(cwd: cwd, sessionId: "open"), "an unanswered prompt is a real block")
        // Ctrl+C: an interrupt (user role) follows the question — exactly the reported case.
        writeTranscript(cwd: cwd, sessionId: "cancelled", lines: [
            question,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":""}]}}"#,
            #"{"type":"user","message":{"content":"[Request interrupted by user for tool use]"}}"#,
            #"{"type":"system","content":"warning"}"#,
        ])
        expect(blockedResolved(cwd: cwd, sessionId: "cancelled"),
               "a user turn after the question (interrupt/answer) means it's resolved — a trailing system line doesn't keep it blocked")
        // Answered normally: a later assistant turn is fine too; the user tool_result already resolved it.
        writeTranscript(cwd: cwd, sessionId: "answered", lines: [
            question,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"案A"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"了解、案Aで進めます"}]}}"#,
        ])
        expect(blockedResolved(cwd: cwd, sessionId: "answered"), "an answered prompt is resolved")
        // Sidechain (subagent) question must not count — the main chain isn't blocked by it.
        writeTranscript(cwd: cwd, sessionId: "side", lines: [
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"s1","input":{}}]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":""}]}}"#,
        ])
        expect(!blockedResolved(cwd: cwd, sessionId: "side"), "a sidechain question isn't a main-chain block")
        expect(!blockedResolved(cwd: cwd, sessionId: "missing"), "no transcript → don't override (stay blocked)")
    }

    test("blockedPending: an open question is the positive block signal for a status-less (VS Code extension) session") {
        let cwd = "/tmp/proj-pending"
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{}}]}}"#
        // VS Code extension sessions record the AskUserQuestion in the transcript but never write a
        // registry status, so the pending question (nothing after it) is the only blocked signal.
        writeTranscript(cwd: cwd, sessionId: "pending", lines: [
            #"{"type":"user","message":{"content":"実装して"}}"#,
            question,
        ])
        expect(blockedPending(cwd: cwd, sessionId: "pending"), "an unanswered question is a pending block")
        // Answered → not pending (a user tool_result follows the question).
        writeTranscript(cwd: cwd, sessionId: "answered", lines: [
            question,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"案A"}]}}"#,
        ])
        expect(!blockedPending(cwd: cwd, sessionId: "answered"), "an answered question is not pending")
        // A plain tool_use (a Bash awaiting a permission decision, or mid-execution) must NOT read as a
        // pending block — it's indistinguishable from a tool that is simply running.
        writeTranscript(cwd: cwd, sessionId: "working", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"b1","input":{"command":"curl x"}}]}}"#,
        ])
        expect(!blockedPending(cwd: cwd, sessionId: "working"), "a non-question tool_use is not a pending block")
        // A sidechain (subagent) question isn't the main chain's block.
        writeTranscript(cwd: cwd, sessionId: "side", lines: [
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"s1","input":{}}]}}"#,
        ])
        expect(!blockedPending(cwd: cwd, sessionId: "side"), "a sidechain question isn't a main-chain block")
        expect(!blockedPending(cwd: cwd, sessionId: "missing"), "no transcript → nothing pending")
        // ExitPlanMode (plan approval) is the other pending-block tool.
        writeTranscript(cwd: cwd, sessionId: "plan", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ExitPlanMode","id":"p1","input":{"plan":"やること"}}]}}"#,
        ])
        expect(blockedPending(cwd: cwd, sessionId: "plan"), "a pending plan approval is a pending block")
    }

    test("transcriptTurnActive: working vs idle from the tail, for a status-less (VS Code extension) session") {
        let cwd = "/tmp/proj-turn"
        // Finished: the newest main-chain assistant record's stop_reason is end_turn; trailing meta
        // rows (ai-title / last-prompt) that Claude Code appends after the turn must be skipped.
        writeTranscript(cwd: cwd, sessionId: "idle", lines: [
            #"{"type":"user","message":{"content":"やって"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}"#,
            #"{"type":"ai-title","aiTitle":"t"}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "idle"), false, "an end_turn record is idle (meta rows ignored)")
        // Finished even when the last content block is `thinking`, not text — end_turn is the edge, so
        // this no longer misreads as working (the bug the stop_reason switch fixes).
        writeTranscript(cwd: cwd, sessionId: "idle-thinking", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"…"}],"stop_reason":"end_turn"}}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "idle-thinking"), false, "end_turn is idle even if the last block is a thinking block")
        // A synthetic API-error record has no stop_reason but is a finished turn — must NOT read as
        // working (else a status-less VS Code session that errored would spin forever and never reach
        // the idle→error upgrade). Mirrors transcriptErrored's isApiErrorMessage fixture.
        writeTranscript(cwd: cwd, sessionId: "errored", lines: [
            #"{"type":"user","message":{"content":"やって"}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: overloaded"}]},"isApiErrorMessage":true}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "errored"), false, "an API-error tail is a finished (idle) turn, not working")
        // Working: the turn is mid-flight on a tool_use (a call awaiting its result).
        writeTranscript(cwd: cwd, sessionId: "tool", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"確認します"},{"type":"tool_use","name":"Bash","id":"b1","input":{}}],"stop_reason":"tool_use"}}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "tool"), true, "a tool_use turn (stop_reason != end_turn) is working")
        // Working: the newest main-chain record is a user prompt no assistant turn has answered yet.
        writeTranscript(cwd: cwd, sessionId: "prompt", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"user","message":{"content":"次はこれ"}}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "prompt"), true, "an unanswered user prompt means Claude is working")
        // Working: a tool_result the assistant hasn't continued past yet.
        writeTranscript(cwd: cwd, sessionId: "result", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"b1","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"ok"}]}}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "result"), true, "a tool_result awaiting the next assistant turn is working")
        // Unknown: no transcript, and a transcript with only sidechain (subagent) records.
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "missing"), nil, "no transcript → unknown")
        writeTranscript(cwd: cwd, sessionId: "sideonly", lines: [
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Bash","id":"s1","input":{}}]}}"#,
        ])
        expectEq(transcriptTurnActive(cwd: cwd, sessionId: "sideonly"), nil, "only sidechain records → no main-chain verdict")
    }

    test("tail reads survive a seek that lands mid-character (multibyte UTF-8)") {
        // A transcript is read by seeking back a fixed number of BYTES from the end, which often lands
        // inside a multibyte character. Decoding such a slice strictly yields nil for the whole slice,
        // so the read returns nothing at all — title, model, links and blocked verdict alike.
        let cwd = "/tmp/proj-utf8"
        let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("s.jsonl")

        let filler = #"{"type":"user","message":{"content":"あいうえおかきくけこ"}}"#
        let title = #"{"type":"ai-title","aiTitle":"日本語のタイトル","sessionId":"s"}"#
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{}}]}}"#

        // Grow past the 256KB tail window, then size the file so that (size - 256KB) lands exactly on a
        // continuation byte inside a Japanese character: pad after the body, which only shifts the seek
        // point, never the bytes it points at.
        var body = ""
        while body.utf8.count < 300_000 { body += filler + "\n" }
        let bodyBytes = Array(body.utf8)
        let tail = question + "\n" + title + "\n"
        let minIndex = bodyBytes.count + tail.utf8.count - 262_144   // pad length must not go negative
        guard let splitIndex = (minIndex..<bodyBytes.count).first(where: { bodyBytes[$0] >= 0x80 && bodyBytes[$0] <= 0xBF })
        else { expect(false, "no continuation byte to split on"); return }

        let padding = String(repeating: "x", count: splitIndex + 262_144 - bodyBytes.count - tail.utf8.count)
        let data = Data((body + padding + tail).utf8)
        let seekByte = data[data.count - 262_144]
        expect(seekByte >= 0x80 && seekByte <= 0xBF,
               "fixture actually splits a character (byte 0x\(String(seekByte, radix: 16)))")
        try! data.write(to: URL(fileURLWithPath: path))

        expectEq(transcriptAITitle(cwd: cwd, sessionId: "s"), "日本語のタイトル",
                 "the ai-title is 60 bytes from EOF — a split at the far end of the window must not lose it")
        expect(!blockedResolved(cwd: cwd, sessionId: "s"),
               "the same slice feeds blockedResolved: an unanswered question must still read as blocked")
    }

    test("blockedResolved: the verdict is cached on the transcript itself, and an answer invalidates it") {
        let cwd = "/tmp/proj-blocked-cache"
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{}}]}}"#
        writeTranscript(cwd: cwd, sessionId: "s", lines: [question])
        expect(!blockedResolved(cwd: cwd, sessionId: "s"), "still waiting")
        expect(!blockedResolved(cwd: cwd, sessionId: "s"), "asking again must not change the answer")

        // The user answers, so the transcript grows: a cached "not resolved" must not survive that.
        writeTranscript(cwd: cwd, sessionId: "s", lines: [
            question,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"案A"}]}}"#,
        ])
        expect(blockedResolved(cwd: cwd, sessionId: "s"),
               "the cache keys on the file's size+mtime, not on the session id alone")
    }

    test("firstPromptFromSessionsIndex") {
        let cwd = "/tmp/proj-index"
        let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let index = #"{"entries":[{"sessionId":"s1","firstPrompt":"最初の指示"},{"sessionId":"s2","firstPrompt":""}]}"#
        try! index.write(toFile: (dir as NSString).appendingPathComponent("sessions-index.json"),
                         atomically: true, encoding: .utf8)
        expectEq(firstPromptFromSessionsIndex(cwd: cwd, sessionId: "s1"), "最初の指示")
        expectNil(firstPromptFromSessionsIndex(cwd: cwd, sessionId: "s2"), "empty firstPrompt")
        expectNil(firstPromptFromSessionsIndex(cwd: cwd, sessionId: "s3"), "unknown session")
    }

    test("transcriptMtime") {
        let cwd = "/tmp/proj-mtime"
        writeTranscript(cwd: cwd, sessionId: "m-1", lines: ["{}"])
        expect(transcriptMtime(cwd: cwd, sessionId: "m-1") != nil, "mtime for an existing transcript")
        expectNil(transcriptMtime(cwd: cwd, sessionId: "gone"))
        expectNil(transcriptMtime(cwd: "", sessionId: "m-1"), "empty cwd")
    }

    test("subagentsFromTranscript: agent files give type and state, no hook needed") {
        let cwd = "/tmp/proj-subagents"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        // The lead's transcript carries an idle_notification user record every time a teammate
        // ends a turn (party-game, 2026-07-14) — the only durable "this teammate is idle" fact.
        func idleRecord(from: String, at: Date) -> String {
            let inner = #"{\"type\":\"idle_notification\",\"from\":\"\#(from)\",\"timestamp\":\"\#(iso.string(from: at))\",\"idleReason\":\"available\"}"#
            return #"{"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\n<teammate-message teammate_id=\"\#(from)\" color=\"blue\">\n\#(inner)\n</teammate-message>\n\nThis came from another Claude session."}}"#
        }
        writeTranscript(cwd: cwd, sessionId: "subs", lines: [
            "{}",
            idleRecord(from: "impl-mind", at: now.addingTimeInterval(-50)),
            idleRecord(from: "impl-redo", at: now.addingTimeInterval(-300)),
            idleRecord(from: "impl-cut", at: now.addingTimeInterval(-50)),
        ])
        let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
        let subagents = ((dir as NSString).appendingPathComponent("subs") as NSString).appendingPathComponent("subagents")
        try! FileManager.default.createDirectory(atPath: subagents, withIntermediateDirectories: true)
        func write(_ name: String, _ body: String, mtime: Date? = nil) {
            let path = (subagents as NSString).appendingPathComponent(name)
            try! body.write(toFile: path, atomically: true, encoding: .utf8)
            if let mtime {
                try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
            }
        }
        // Plain subagents: finished = the newest assistant turn ends with a TEXT block. stop_reason
        // is unreliable across agent kinds (end_turn / stop_sequence / null — measured 2026-07-10),
        // so the last block type is the signal: a tool_use tail is mid-call, a text tail is done.
        write("agent-aaa.meta.json", #"{"agentType":"general-purpose","toolUseId":"toolu_1"}"#)
        write("agent-aaa.jsonl", #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"できました"}]}}"#)
        write("agent-bbb.meta.json", #"{"agentType":"Explore","name":"lineage-probe","description":"検証用teammate","worktreePath":"/repo/.claude/worktrees/agent-bbb","worktreeBranch":"worktree-agent-bbb","spawnDepth":1,"model":"haiku"}"#)
        write("agent-bbb.jsonl", #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"./test.sh"}}]}}"#)
        write("agent-ccc.meta.json", "{}")   // no agentType, and no jsonl at all
        // Teammates (taskKind in_process_teammate): a text tail is NOT proof of being done — a
        // narration line ("now I'll write the file") followed by minutes of tool-call generation
        // looks identical (party-game, 2026-07-14). The lead transcript's idle_notification is the
        // authority: idle iff the newest notification is fresher than the teammate's jsonl.
        let teammateTail = [
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"実装完了しました"}]}}"#,
        ].joined(separator: "\n")
        // ddd: notification (now-50s) is fresher than the jsonl (now-100s) → idle.
        write("agent-ddd.meta.json", #"{"agentType":"general-purpose","name":"impl-mind","taskKind":"in_process_teammate"}"#)
        write("agent-ddd.jsonl", teammateTail, mtime: now.addingTimeInterval(-100))
        // eee: no notification at all → still working (the mid-generation narration case).
        write("agent-eee.meta.json", #"{"agentType":"general-purpose","name":"impl-quiet","taskKind":"in_process_teammate"}"#)
        write("agent-eee.jsonl", teammateTail, mtime: now.addingTimeInterval(-100))
        // fff: notification (now-300s) is OLDER than the jsonl (now-100s) → re-activated, working.
        write("agent-fff.meta.json", #"{"agentType":"general-purpose","name":"impl-redo","taskKind":"in_process_teammate"}"#)
        write("agent-fff.jsonl", teammateTail, mtime: now.addingTimeInterval(-100))
        // ggg: no notification but the jsonl went silent for over 30 min → idle (backstop for a
        // killed teammate whose notification never made it into the lead transcript).
        write("agent-ggg.meta.json", #"{"agentType":"general-purpose","name":"impl-gone","taskKind":"in_process_teammate"}"#)
        write("agent-ggg.jsonl", teammateTail, mtime: now.addingTimeInterval(-7200))
        // hhh: a tool_use tail but the notification is fresher than the jsonl → the turn was cut
        // short (interrupt); the notification wins → idle.
        write("agent-hhh.meta.json", #"{"agentType":"general-purpose","name":"impl-cut","taskKind":"in_process_teammate"}"#)
        write("agent-hhh.jsonl", #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 999"}}]}}"#,
              mtime: now.addingTimeInterval(-100))
        // iii: a tool_use tail, no notification, 2h of silence → the backstop must fire here too
        // (a teammate killed MID tool-call is the common kill shape — review 2026-07-14).
        write("agent-iii.meta.json", #"{"agentType":"general-purpose","name":"impl-dead","taskKind":"in_process_teammate"}"#)
        write("agent-iii.jsonl", #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 999"}}]}}"#,
              mtime: now.addingTimeInterval(-7200))
        // jjj: a plain subagent whose FINAL record is bigger than 16KB (an Explore closing report —
        // genome 2026-07-16 measured 17–25KB). A tail window smaller than the record starts
        // mid-JSON, parses nothing, and stuck 4 finished agents "working" for 4.5h.
        let bigReport = #"# 調査報告\n"# + String(repeating: "x", count: 20_000)   // \n stays JSON-escaped
        write("agent-jjj.meta.json", #"{"agentType":"Explore","description":"個口表調査"}"#)
        write("agent-jjj.jsonl", [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep x"}}]}}"#,
            #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"\#(bigReport)"}]}}"#,
        ].joined(separator: "\n"))
        // kkk: a plain subagent killed mid tool-call — tool_use tail, 2h of jsonl silence. The
        // 30-min backstop must fire for plain subagents too, not only teammates.
        write("agent-kkk.meta.json", #"{"agentType":"general-purpose","description":"killed probe"}"#)
        write("agent-kkk.jsonl", #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 999"}}]}}"#,
              mtime: now.addingTimeInterval(-7200))
        let agents = subagentsFromTranscript(cwd: cwd, sessionId: "subs")
        expectEq(agents.count, 11)
        expectEq(agents[0].agentId, "aaa", "the id comes from the file name")
        expect(!agents[0].working, "text tail → finished"); expectEq(agents[0].type, "general-purpose")
        expectEq(agents[0].activity, "できました", "finished → its closing words")
        expectNil(agents[0].name, "no name in the meta")
        expect(agents[0].startedAt != nil, "meta mtime seeds the spawn time")
        expect(agents[0].updatedAt != nil, "jsonl mtime is the freshness stamp")
        expect(agents[1].working, "tool_use tail → mid-turn"); expectEq(agents[1].type, "Explore")
        expectEq(agents[1].name, "lineage-probe")
        expectEq(agents[1].model, "haiku",
                 "the spawn-time model from the meta — the chip's source before the first API reply")
        expectNil(agents[0].model, "no model key in the meta")
        expectEq(agents[1].activity, "⚙ Bash: ./test.sh", "working → the tool it's mid-call on")
        expectEq(agents[1].worktreePath, "/repo/.claude/worktrees/agent-bbb")
        expect(agents[2].working, "an unreadable agent reads as working — the safe side")
        expectEq(agents[2].type, "agent", "and falls back to a generic type")
        expect(!agents[3].working, "teammate text tail + fresher idle_notification → idle")
        expectEq(agents[3].activity, "実装完了しました")
        expect(agents[4].working, "teammate text tail but NO idle_notification → still mid-turn")
        expect(agents[5].working, "teammate jsonl newer than its last idle_notification → re-activated")
        expect(!agents[6].working, "no notification but 2h silent → idle backstop")
        expect(!agents[7].working, "tool_use tail but fresher notification → interrupted, idle")
        expect(!agents[8].working, "tool_use tail, no notification, 2h silent → backstop fires too")
        expect(!agents[9].working, "a final record bigger than 16KB still reads as finished")
        expectEq(agents[9].activity, "# 調査報告", "and its closing words still surface")
        expect(!agents[10].working, "plain subagent: tool_use tail + 2h silence → idle backstop")
        expectEq(subagentsFromTranscript(cwd: cwd, sessionId: "none").count, 0, "no subagents dir")
    }

    test("teammateWorking: notification freshness vs jsonl activity") {
        let now = Date(timeIntervalSince1970: 1_783_970_000)
        func at(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }
        expect(!teammateWorking(idleAt: at(-50), jsonlMtime: at(-100), now: now),
               "notification fresher than the jsonl → idle")
        expect(!teammateWorking(idleAt: at(-100), jsonlMtime: at(-99), now: now),
               "mtime up to 2s past the notification is turn-end flush jitter, not new work")
        expect(teammateWorking(idleAt: at(-300), jsonlMtime: at(-100), now: now),
               "jsonl written after the notification → re-activated")
        expect(teammateWorking(idleAt: nil, jsonlMtime: at(-100), now: now),
               "no notification yet → mid-turn")
        expect(!teammateWorking(idleAt: nil, jsonlMtime: at(-1801), now: now),
               "30 min of silence → idle even without a notification")
        expect(teammateWorking(idleAt: at(-50), jsonlMtime: nil, now: now),
               "unreadable jsonl → working, the safe side")
    }

    test("teammateIdleTimes: incremental scan of the lead transcript") {
        let cwd = "/tmp/proj-idle-times"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let t1 = Date(timeIntervalSince1970: 1_783_960_000)
        let t2 = Date(timeIntervalSince1970: 1_783_961_000)
        func idleRecord(from: String, at: Date) -> String {
            #"{"type":"user","message":{"role":"user","content":"<teammate-message teammate_id=\"\#(from)\">\n{\"type\":\"idle_notification\",\"from\":\"\#(from)\",\"timestamp\":\"\#(iso.string(from: at))\",\"idleReason\":\"available\"}\n</teammate-message>"}}"#
        }
        writeTranscript(cwd: cwd, sessionId: "idle-1", lines: [
            idleRecord(from: "worker-a", at: t1),
            // a line that merely MENTIONS idle_notification must not parse as one
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"idle_notification について調査"}]}}"#,
        ])
        var times = teammateIdleTimes(cwd: cwd, sessionId: "idle-1")
        expectEq(times["worker-a"], t1)
        expectNil(times["worker-b"], "no notification yet")
        // Append: a newer notification for a, a first one for b. The second call reads the delta only.
        let path = ((claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd)) as NSString)
            .appendingPathComponent("idle-1.jsonl")
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(("\n" + idleRecord(from: "worker-a", at: t2) + "\n" + idleRecord(from: "worker-b", at: t2)).data(using: .utf8)!)
        try! fh.close()
        times = teammateIdleTimes(cwd: cwd, sessionId: "idle-1")
        expectEq(times["worker-a"], t2, "the newest notification wins")
        expectEq(times["worker-b"], t2, "appended notifications are picked up")
        expectEq(teammateIdleTimes(cwd: cwd, sessionId: "gone").count, 0, "no transcript → empty")
    }

    test("transcriptTailValue: the newest permission-mode / last-prompt line wins") {
        let cwd = "/tmp/proj-tail-value"
        writeTranscript(cwd: cwd, sessionId: "s", lines: [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"最初の指示","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"お願いします","sessionId":"s"}"#,
        ])
        expectEq(transcriptTailValue(cwd: cwd, sessionId: "s", type: "permission-mode", field: "permissionMode"),
                 "bypassPermissions")
        expectEq(transcriptTailValue(cwd: cwd, sessionId: "s", type: "last-prompt", field: "lastPrompt"),
                 "お願いします")
        expectNil(transcriptTailValue(cwd: cwd, sessionId: "s", type: "ai-title", field: "aiTitle"),
                  "a type the transcript never wrote")
        expectNil(transcriptTailValue(cwd: cwd, sessionId: "gone", type: "last-prompt", field: "lastPrompt"))
    }

    test("transcriptErrored: only a session whose NEWEST main-chain turn is an API error") {
        let cwd = "/tmp/proj-api-error"
        // The real shape (measured 2026-07-10): a synthetic assistant record flagged isApiErrorMessage.
        let apiError = #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: Response stalled mid-stream."}]},"isApiErrorMessage":true}"#
        let ok = #"{"type":"assistant","message":{"content":[{"type":"text","text":"できました"}]}}"#
        let userTurn = #"{"type":"user","message":{"content":"続けて"}}"#
        let sidechainError = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"API Error"}]},"isApiErrorMessage":true}"#

        writeTranscript(cwd: cwd, sessionId: "e1", lines: [ok, apiError])
        expect(transcriptErrored(cwd: cwd, sessionId: "e1"), "the last turn died on an API error")

        writeTranscript(cwd: cwd, sessionId: "e2", lines: [apiError, userTurn, ok])
        expect(!transcriptErrored(cwd: cwd, sessionId: "e2"),
               "a recovered error is history — the newer assistant turn proves it")

        writeTranscript(cwd: cwd, sessionId: "e3", lines: [ok, sidechainError])
        expect(!transcriptErrored(cwd: cwd, sessionId: "e3"),
               "a subagent's API error is not the session's state")

        writeTranscript(cwd: cwd, sessionId: "e4", lines: [ok])
        expect(!transcriptErrored(cwd: cwd, sessionId: "e4"), "a clean session")
        expect(!transcriptErrored(cwd: cwd, sessionId: "gone"), "no transcript, no verdict")
        expect(!transcriptErrored(cwd: "", sessionId: "e1"), "empty cwd")
    }

    test("formatBlockedPrompt: AskUserQuestion input renders question + numbered options") {
        let input: [String: Any] = ["questions": [[
            "question": "どの案にしますか？",
            "multiSelect": false,
            "options": [
                ["label": "案A", "description": "最小変更"],
                ["label": "案B"],
            ],
        ] as [String: Any]]]
        let s = formatBlockedPrompt(name: "AskUserQuestion", input: input)
        expectEq(s, "どの案にしますか？\n  1. 案A — 最小変更\n  2. 案B")
        expectNil(formatBlockedPrompt(name: "AskUserQuestion", input: [:]), "no questions → nil")
        expectNil(formatBlockedPrompt(name: "Bash", input: ["command": "ls"]), "unknown tool → nil (caller falls back)")
        let plan = formatBlockedPrompt(name: "ExitPlanMode", input: ["plan": "1. やる"])
        expect(plan?.contains("1. やる") == true, "ExitPlanMode carries the plan text")
    }

    test("blockedPromptFromTranscript: only the NEWEST main-chain assistant record counts") {
        let cwd = "/tmp/proj-blocked-prompt"
        let question = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{"questions":[{"question":"続行しますか？","options":[{"label":"はい"}]}]}}]}}"#
        let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"q9","input":{"questions":[{"question":"サブエージェントの質問","options":[]}]}}]}}"#
        let textTurn = #"{"type":"assistant","message":{"content":[{"type":"text","text":"完了しました"}]}}"#

        writeTranscript(cwd: cwd, sessionId: "p1", lines: [textTurn, question, sidechain])
        let s = blockedPromptFromTranscript(cwd: cwd, sessionId: "p1")
        expectEq(s, "続行しますか？\n  1. はい", "the pending question, skipping the newer sidechain record")

        writeTranscript(cwd: cwd, sessionId: "p2", lines: [question, textTurn])
        expectNil(blockedPromptFromTranscript(cwd: cwd, sessionId: "p2"),
                  "a question buried under a newer assistant turn is not pending — never show a stale question")
    }
}
