import Foundation

// Minimal self-contained test harness (XCTest is not shipped with the Command Line Tools).
// `test` names a group; `expect*` record assertions; the runner in Tests/main.swift exits
// non-zero when anything failed.

var testFailures = 0
var testAssertions = 0
private var currentTest = ""

func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    body()
}

func expect(_ cond: Bool, _ what: String, file: String = #file, line: Int = #line) {
    testAssertions += 1
    if !cond {
        testFailures += 1
        print("FAIL [\(currentTest)] \(what)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func expectEq<T: Equatable>(_ got: T, _ want: T, _ what: String = "", file: String = #file, line: Int = #line) {
    testAssertions += 1
    if got != want {
        testFailures += 1
        print("FAIL [\(currentTest)] \(what): got \(got), want \(want)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func expectNil<T>(_ got: T?, _ what: String = "", file: String = #file, line: Int = #line) {
    testAssertions += 1
    if let got = got {
        testFailures += 1
        print("FAIL [\(currentTest)] \(what): got \(got), want nil  (\((file as NSString).lastPathComponent):\(line))")
    }
}

// Per-run scratch directory for file-based fixtures.
let testTmpDir: String = {
    let dir = NSTemporaryDirectory() + "shepherd-tests-\(getpid())"
    try? FileManager.default.removeItem(atPath: dir)
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

// Write a transcript fixture for (cwd, sessionId) under the overridden claudeProjectsDir.
func writeTranscript(cwd: String, sessionId: String, lines: [String]) {
    let dir = (claudeProjectsDir as NSString).appendingPathComponent(sanitizeCwd(cwd))
    let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    // A subagent transcriptKey ("<parent>/subagents/agent-<id>") puts subdirectories in the
    // session id, so create the file's own parent, not just the project dir.
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// Poll until cond() turns true or the deadline passes (for async cache/notification tests).
func waitUntil(_ timeout: TimeInterval = 2.0, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        usleep(10_000)
    }
    return cond()
}

// Spawn and reap a short-lived process, returning its (now dead) pid.
func deadPid() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! p.run()
    p.waitUntilExit()
    return p.processIdentifier
}
