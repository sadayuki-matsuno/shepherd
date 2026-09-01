import Foundation

func runCommandsTests() {
    test("runCommand: stdout and exit-code handling") {
        expectEq(runCommand(["/bin/echo", "hello"]), "hello\n")
        expectNil(runCommand(["/bin/sh", "-c", "echo out; exit 1"]), "non-zero exit yields nil")
        expectEq(runCommand(["/bin/sh", "-c", "echo out; exit 1"], ignoreExit: true), "out\n",
                 "ignoreExit keeps the output (the gh pr checks case)")
        expectNil(runCommand(["/no/such/binary"]), "unlaunchable binary yields nil")
        expectNil(runCommand(["/bin/sh", "-c", "echo err >&2; exit 1"]), "stderr is not stdout")
    }

    test("runCommand: cwd is honored") {
        let out = runCommand(["/bin/pwd"], cwd: "/private/tmp")
        expectEq(out?.trimmingCharacters(in: .whitespacesAndNewlines), "/private/tmp")
    }

    test("runCommand: HERDR_* env never reaches children (nested-herdr guard)") {
        setenv("HERDR_UNITTEST_CANARY", "1", 1)
        defer { unsetenv("HERDR_UNITTEST_CANARY") }
        let env = runCommand(["/usr/bin/env"]) ?? ""
        expect(!env.contains("HERDR_UNITTEST_CANARY"), "HERDR_-prefixed vars are stripped")
        expect(env.contains("GH_PROMPT_DISABLED=1"), "gh prompts are disabled")
        expect(env.contains("GH_NO_UPDATE_NOTIFIER=1"), "gh update notifier is disabled")
    }

    test("runCommand: extraEnv is added (the zellij session targeting path)") {
        let env = runCommand(["/usr/bin/env"], extraEnv: ["SHEPHERD_TEST_EXTRA": "yes"]) ?? ""
        expect(env.contains("SHEPHERD_TEST_EXTRA=yes"), "extraEnv reaches the child")
    }

    test("runCommand: timeout kills a hung child and returns nil") {
        let t0 = Date()
        expectNil(runCommand(["/bin/sleep", "30"], timeout: 0.5), "timed-out command yields nil")
        expect(Date().timeIntervalSince(t0) < 5, "returns promptly after the timeout, not when the child would finish")
    }

    test("runCommand: a fast command is unaffected by the timeout") {
        expectEq(runCommand(["/bin/echo", "ok"], timeout: 5), "ok\n")
    }

    test("statusFromRegistry: busy/idle/waiting map onto the board vocabulary") {
        func entry(_ status: String?) -> SessionRegistryEntry {
            SessionRegistryEntry(pid: 1, sessionId: "s", cwd: "/", kind: "interactive", name: nil,
                                 status: status, waitingFor: nil, startedAt: nil, updatedAt: nil)
        }
        expectEq(statusFromRegistry(entry("busy")), "working")
        expectEq(statusFromRegistry(entry("waiting")), "blocked")
        expectEq(statusFromRegistry(entry("idle")), "idle")
        expectEq(statusFromRegistry(entry("shell")), "idle",
                 "the CLI's 4th value: idle, with a `!` shell command being typed")
        expectEq(statusFromRegistry(entry("something-new")), "unknown", "future statuses degrade, not crash")
        expectEq(statusFromRegistry(entry(nil)), "unknown")
    }

    test("readSessionsRegistry: parses live entries, skips dead pids and malformed files") {
        let dir = NSTemporaryDirectory() + "shepherd-test-sessions-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let alive = ProcessInfo.processInfo.processIdentifier   // our own pid is always alive
        func write(_ name: String, _ json: String) {
            try? json.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        write("a.json", #"{"pid":\#(alive),"sessionId":"sess-a","cwd":"/tmp","kind":"interactive","entrypoint":"sdk-cli","name":"shep-1","status":"waiting","waitingFor":"permission prompt","startedAt":1783600000000,"statusUpdatedAt":1783600001000}"#)
        write("dead.json", #"{"pid":99999999,"sessionId":"sess-dead","cwd":"/tmp","kind":"interactive"}"#)
        write("broken.json", "{not json")
        write("nosession.json", #"{"pid":\#(alive)}"#)
        let saved = claudeSessionsDir
        claudeSessionsDir = dir
        defer { claudeSessionsDir = saved }
        let entries = readSessionsRegistry()
        expectEq(entries.count, 1, "only the live, well-formed entry survives")
        expectEq(entries.first?.sessionId, "sess-a")
        expectEq(entries.first?.name, "shep-1")
        expectEq(entries.first?.status, "waiting")
        expectEq(entries.first?.waitingFor, "permission prompt")
        expectEq(entries.first?.entrypoint, "sdk-cli",
                 "entrypoint tells `claude -p` (sdk-cli) from the interactive REPL (cli) — measured 2026-07-11")
        expectEq(entries.first.map { statusFromRegistry($0) }, "blocked")
        expectEq(entries.first?.updatedAt.map { Int($0.timeIntervalSince1970) }, 1783600001,
                 "statusUpdatedAt (ms) outranks updatedAt and converts to seconds")
    }

    test("readSessionsRegistry: scans extra config dirs and points their transcripts at them") {
        let root = NSTemporaryDirectory() + "shepherd-test-config-\(UUID().uuidString)"
        let home = root + "/.claude", other = root + "/.claude-work"
        for d in [home + "/sessions", other + "/sessions"] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let alive = ProcessInfo.processInfo.processIdentifier
        func write(_ dir: String, _ name: String, _ json: String) {
            try? json.write(toFile: dir + "/sessions/" + name, atomically: true, encoding: .utf8)
        }
        write(home, "1.json", #"{"pid":\#(alive),"sessionId":"sess-home","cwd":"/tmp/x","kind":"interactive"}"#)
        write(home, "2.json", #"{"pid":\#(alive),"sessionId":"sess-both","cwd":"/tmp/x","kind":"interactive","name":"from-home"}"#)
        write(other, "3.json", #"{"pid":\#(alive),"sessionId":"sess-other","cwd":"/tmp/y","kind":"interactive"}"#)
        write(other, "4.json", #"{"pid":\#(alive),"sessionId":"sess-both","cwd":"/tmp/x","kind":"interactive","name":"from-other"}"#)
        let savedSessions = claudeSessionsDir, savedProjects = claudeProjectsDir
        claudeSessionsDir = home + "/sessions"
        // sessionProjectsDirs is process-global: leaving an entry behind would redirect transcript
        // resolution for every test that runs after this one.
        defer {
            claudeSessionsDir = savedSessions
            claudeProjectsDir = savedProjects
            projectsDirLock.lock(); sessionProjectsDirs = [:]; projectsDirLock.unlock()
        }

        let entries = readSessionsRegistry(configDirs: [other])
        expectEq(entries.count, 3, "both dirs are scanned, the duplicate session id counted once")
        expectEq(entries.first(where: { $0.sessionId == "sess-other" })?.configDir, other,
                 "an entry is tagged with the config dir it came from")
        expectEq(entries.first(where: { $0.sessionId == "sess-home" })?.configDir, nil,
                 "the default dir's entries stay untagged")
        expectEq(entries.first(where: { $0.sessionId == "sess-both" })?.name, "from-home",
                 "a session id in both registries keeps the DEFAULT dir's entry")

        expectEq(transcriptDir(cwd: "/tmp/y", sessionId: "sess-other"),
                 other + "/projects/-tmp-y",
                 "an extra dir's session reads its transcript out of that dir's projects/")
        expectEq(transcriptDir(cwd: "/tmp/y", sessionId: "sess-other/subagents/agent-9"),
                 other + "/projects/-tmp-y",
                 "and so does its subagent transcript, addressed through the parent session id")
        expectEq(transcriptDir(cwd: "/tmp/x", sessionId: "sess-home"),
                 claudeProjectsDir + "/-tmp-x",
                 "a default-dir session is unaffected")
        expectEq(transcriptDir(cwd: "/tmp/x", sessionId: "sess-both"),
                 claudeProjectsDir + "/-tmp-x",
                 "so is the duplicate the default dir won")

        // Merge, don't replace: scanning only the default dir is the obvious thing for future code
        // to write, and it must not silently re-route an extra dir's sessions to the default
        // projects/ tree (where their transcripts don't exist — every transcript fact would vanish
        // from those cards).
        _ = readSessionsRegistry()
        expectEq(transcriptDir(cwd: "/tmp/y", sessionId: "sess-other"),
                 other + "/projects/-tmp-y",
                 "a default-only rescan leaves routing for sessions it never looked at intact")
    }

    test("configDirsFromPS: collects CLAUDE_CONFIG_DIR values, minus the default") {
        let out = """
        101 claude HOME=/Users/me CLAUDE_CONFIG_DIR=/Users/me/.claude-work TERM_PROGRAM=ghostty
        102 claude CLAUDE_CONFIG_DIR=/Users/me/.claude-work CLAUDECODE=1
        103 claude CLAUDE_CONFIG_DIR=/Users/me/.claude
        104 claude CLAUDE_CONFIG_DIR=/Users/me/.claude-alt
        105 node --inspect FOO=bar
        """
        expectEq(configDirsFromPS(out, home: "/Users/me"),
                 ["/Users/me/.claude-alt", "/Users/me/.claude-work"],
                 "deduped, sorted, and the default config dir dropped (it is already read)")
        expectEq(configDirsFromPS(out, home: "/Users/other"),
                 ["/Users/me/.claude", "/Users/me/.claude-alt", "/Users/me/.claude-work"],
                 "with a different home, ~/.claude is just another dir")
        expectEq(configDirsFromPS("101 claude CLAUDE_CONFIG_DIR=/Users/me/.claude-work/", home: "/Users/me"),
                 ["/Users/me/.claude-work"], "paths are standardized, so a trailing slash is not a second dir")
        expectEq(configDirsFromPS("101 claude CLAUDE_CONFIG_DIR_SUFFIXED=/nope", home: "/Users/me"), [],
                 "a longer variable name is not the one we read")
        expectEq(configDirsFromPS("", home: "/Users/me"), [], "an empty ps dump discovers nothing")
    }

    test("discoveredConfigDirs: a fixture run discovers nothing") {
        // dev/demo-board.sh stages its own sessions/projects dirs; discovery would mix real
        // sessions (customer repo names and all) into a staged capture.
        expectEq(discoveredConfigDirs(env: ["SHEPHERD_SESSIONS_DIR": "/tmp/demo/sessions"]), [])
        expectEq(discoveredConfigDirs(env: ["SHEPHERD_PROJECTS_DIR": "/tmp/demo/projects"]), [])
    }

    test("processEnvironment: reads a live process's env (the attach-follow probe)") {
        // ps prints the env block captured at exec, so assert on vars every process inherits
        // rather than one this test could setenv (which would never reach that block).
        let env = processEnvironment(pid: ProcessInfo.processInfo.processIdentifier)
        expectEq(env["HOME"], NSHomeDirectory(), "our own env comes back verbatim")
        expect(env["PATH"] != nil, "and the other inherited vars are there too")
        // Mixed-case keys are admitted on purpose — __CFBundleIdentifier is how a VSCode-family
        // session names its editor (2026-07-11) — but a key never contains anything beyond
        // letters/digits/underscore, which is what skips `--flag=x` command-line tokens.
        expect(env.keys.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } },
               "keys are letter/digit/underscore tokens — the command line's own words are skipped")
        expectEq(processEnvironment(pid: 999_999), [:], "a dead pid degrades to empty, never crashes")
    }

    test("processEnvironments: one ps call covers many pids; a dead pid can't empty the batch") {
        let me = ProcessInfo.processInfo.processIdentifier
        // `ps` given an unknown pid prints nothing and exits 1, so the dead one must be filtered out
        // before the call — otherwise it would cost every other session its env.
        let envs = processEnvironments(pids: [me, 999_999])
        expectEq(envs.count, 1, "the live pid survives; the `PID TTY …` header never parses as one")
        expectEq(envs[me]?["HOME"], NSHomeDirectory())
        expectEq(processEnvironments(pids: [999_999]), [:], "all-dead degrades to empty")
        expectEq(processEnvironments(pids: []), [:], "no pids, no ps call")
    }

    test("findAttachClient: nothing attached → nil") {
        expectNil(findAttachClient(short: "deadbeef"), "no `claude attach deadbeef` process is running")
        expectNil(findAttachClient(short: ""), "an empty id must never match every line")
    }

    test("parseAccount: a logged-in first-party account yields email + plan") {
        let acct = parseAccount(["loggedIn": true, "email": "a@b.com", "subscriptionType": "max"])
        expectEq(acct?.email, "a@b.com")
        expectEq(acct?.plan, "max")
        expectEq(parseAccount(["loggedIn": true, "email": "a@b.com"])?.plan, nil, "no plan → nil, not crash")
        expectNil(parseAccount(["loggedIn": false, "email": "a@b.com"]), "logged out → nothing to show")
        expectNil(parseAccount(["loggedIn": true, "email": ""]), "an API-key session has no email")
        expectNil(parseAccount([:]), "empty json")
    }

    test("runJSON") {
        expectEq(runJSON(["/bin/echo", #"{"a": 1}"#])?["a"] as? Int, 1)
        expectNil(runJSON(["/bin/echo", "not json"]))
        expectNil(runJSON(["/bin/sh", "-c", "exit 1"]))
    }

    test("zellijLayoutIsSinglePane: one tab + one terminal pane is sendable") {
        // The tab-bar plugin wrapper pane (a container ending in `{`) must not count.
        let layout = """
        layout {
            cwd "/Users/x"
            tab name="work" focus=true {
                pane size=1 borderless=true {
                    plugin location="zellij:tab-bar"
                }
                pane command="claude" focus=true
            }
            new_tab_template {
                pane size=1 borderless=true {
                    plugin location="zellij:tab-bar"
                }
                pane
            }
        }
        """
        expectEq(zellijLayoutIsSinglePane(layout), true)
    }

    test("zellijLayoutIsSinglePane: multiple panes or tabs refuse the send") {
        // Condensed from a real `dump-layout` of a multi-tab session: 2 tabs, container panes,
        // and template sections that also carry tab/pane tokens.
        let multi = """
        layout {
            tab name="shepherd (main)" focus=true hide_floating_panes=true {
                pane size=1 borderless=true {
                    plugin location="zellij:tab-bar"
                }
                pane split_direction="vertical" {
                    pane command="claude" cwd="dotfiles" size="25%" {
                        args "--dangerously-skip-permissions"
                    }
                    pane command="nvim" focus=true size="25%"
                }
            }
            tab name="demo-app (main)" hide_floating_panes=true {
                pane size=1 borderless=true {
                    plugin location="zellij:tab-bar"
                }
                pane
            }
            new_tab_template {
                pane
            }
            swap_tiled_layout name="vertical-even" {
                tab max_panes=2 {
                    pane { pane }
                }
            }
        }
        """
        expectEq(zellijLayoutIsSinglePane(multi), false, "two tabs")

        let twoPanes = """
        layout {
            tab focus=true {
                pane command="claude"
                pane command="nvim"
            }
        }
        """
        expectEq(zellijLayoutIsSinglePane(twoPanes), false, "two leaf panes in one tab")
    }

    test("zellijFocusedPaneId(fromListClients:): the attached client's focused pane") {
        let out = """
        CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND
        1         terminal_13    claude --dangerously-skip-permissions
        """
        expectEq(zellijFocusedPaneId(fromListClients: out), "13",
                 "terminal_ prefix stripped down to the ZELLIJ_PANE_ID env-var form")
        expectNil(zellijFocusedPaneId(fromListClients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"),
                  "header only = nobody attached")
        expectNil(zellijFocusedPaneId(fromListClients: ""))
        expectEq(zellijFocusedPaneId(fromListClients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n2 plugin_5 -"),
                 "plugin_5", "a plugin pane passes through unstripped (never matches a terminal target)")
    }
}
