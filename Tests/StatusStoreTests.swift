import Foundation

func runStatusStoreTests() {
    test("pidAlive") {
        expect(pidAlive(getpid()), "own pid is alive")
        expect(!pidAlive(deadPid()), "a reaped child is dead (ESRCH)")
    }

    test("lastMessageFor: first line only, cached by updated_at stamp") {
        claudeProjectsDir = testTmpDir + "/projects"
        let cwd = "/tmp/proj-lastmsg"
        writeTranscript(cwd: cwd, sessionId: "lm-1", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"  一行目です  \n二行目"}]}}"#,
        ])
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        expectEq(lastMessageFor(cwd: cwd, sessionId: "lm-1", updatedAt: stamp), "一行目です",
                 "first non-empty line, trimmed")
        // Same stamp → served from cache even though the transcript changed.
        writeTranscript(cwd: cwd, sessionId: "lm-1", lines: [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"新しい返答"}]}}"#,
        ])
        expectEq(lastMessageFor(cwd: cwd, sessionId: "lm-1", updatedAt: stamp), "一行目です", "cache hit on same stamp")
        expectEq(lastMessageFor(cwd: cwd, sessionId: "lm-1", updatedAt: Date()), "新しい返答", "new stamp re-reads")
    }
}
