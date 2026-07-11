import Foundation

func runGitHubFactsTests() {
    // Keep the gitFacts tests hermetic: the real prFetch would spawn gh against the fixture
    // repos (async, after prInfo went stale-while-revalidate). Stub it to "no PR" for the whole
    // suite; the prInfo-specific tests below install their own stubs on top.
    let realPRFetch = prFetch
    prFetch = { _ in (nil, nil, nil) }
    defer { prFetch = realPRFetch }

    test("firstMatchInt") {
        expectEq(firstMatchInt("#(\\d+)", in: "fix #123 and #456"), 123)
        expectNil(firstMatchInt("#(\\d+)", in: "no numbers"))
        expectNil(firstMatchInt("(", in: "broken pattern"), "invalid regex returns nil")
    }

    test("allMatchStrings / lastMatchString") {
        let text = "a https://x.com/1. b https://x.com/2) c"
        let all = allMatchStrings("(https://\\S+)", in: text)
        expectEq(all, ["https://x.com/1", "https://x.com/2"], "in order, trailing punctuation trimmed")
        expectEq(lastMatchString("(https://\\S+)", in: text), "https://x.com/2")
        expectNil(lastMatchString("(zzz)", in: text))
        expectEq(allMatchStrings("https://\\S+", in: text), [], "no capture group yields nothing")
    }

    test("gitFacts: real repo — branch, dirty count, identity") {
        let repo = testTmpDir + "/gitfacts-repo"
        try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) { _ = runCommand([gitBin, "-C", repo] + args) }
        _ = runCommand([gitBin, "init", "-b", "main", repo])
        git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init")

        var f = gitFacts(cwd: repo)
        expectEq(f.branch, "main")
        expectEq(f.changed, 0, "clean tree")
        expectEq(f.repoName, "gitfacts-repo")
        expect(f.isWorktree == false, "main checkout is not a worktree")
        expect(f.repoKey?.hasSuffix("/.git") == true, "repoKey is the common git dir: \(f.repoKey ?? "nil")")

        try! "dirty".write(toFile: repo + "/untracked.txt", atomically: true, encoding: .utf8)
        factsLock.lock(); gitFactsCache.removeAll(); factsLock.unlock()   // git facts are cached ~15s per cwd
        f = gitFacts(cwd: repo)
        expectEq(f.changed, 1, "untracked file counts as a change")
    }

    test("gitFacts: git-derived facts are served from the 15s cache") {
        let repo = testTmpDir + "/gitfacts-repo"           // fixture from the test above (1 untracked)
        factsLock.lock(); gitFactsCache.removeAll(); factsLock.unlock()
        var f = gitFacts(cwd: repo)
        expectEq(f.changed, 1)
        try! "more".write(toFile: repo + "/untracked2.txt", atomically: true, encoding: .utf8)
        f = gitFacts(cwd: repo)
        expectEq(f.changed, 1, "within the TTL the cached dirty count is served (no git run)")
        factsLock.lock(); gitFactsCache.removeAll(); factsLock.unlock()
        f = gitFacts(cwd: repo)
        expectEq(f.changed, 2, "cache dropped → fresh git run sees the new file")
    }

    test("gitFacts: PR facts overlay is live even on a git-cache hit") {
        let repo = testTmpDir + "/gitfacts-repo"
        prLock.lock(); prCache[repo] = (5, nil, "https://g/pr/5", Date()); prLock.unlock()
        var f = gitFacts(cwd: repo)
        expectEq(f.prNo, 5)
        // The PR cache moves (background revalidate) while the git half stays cached — the card
        // must show the new PR facts on the very next refresh, not after the git TTL.
        prLock.lock(); prCache[repo] = (6, nil, "https://g/pr/6", Date()); prLock.unlock()
        f = gitFacts(cwd: repo)
        expectEq(f.prNo, 6, "PR facts come from the live PR cache, not the frozen git snapshot")
        expectEq(f.prUrl, "https://g/pr/6")
        prLock.lock(); prCache.removeAll(); prLock.unlock()
    }

    test("prInfo: miss returns immediately and the fetch lands in the background") {
        let lk = NSLock()
        var calls = 0, changed = 0
        let origFetch = prFetch
        defer { prFetch = origFetch; onPRFactsChanged = nil }
        prFetch = { _ in lk.lock(); calls += 1; lk.unlock(); return (7, .pass, "https://g/pr/7") }
        onPRFactsChanged = { lk.lock(); changed += 1; lk.unlock() }
        prLock.lock(); prCache.removeAll(); prFetching.removeAll(); prLock.unlock()

        let t0 = Date()
        let first = prInfo(cwd: "/tmp/swr-a")
        expect(Date().timeIntervalSince(t0) < 0.2, "no synchronous gh wait on a miss")
        expectNil(first.num, "a miss reports no PR for now")
        expect(waitUntil { prLock.lock(); defer { prLock.unlock() }; return prCache["/tmp/swr-a"]?.num == 7 },
               "background fetch populated the cache")
        expect(waitUntil { lk.lock(); defer { lk.unlock() }; return changed >= 1 },
               "onPRFactsChanged fired for the nil→PR#7 change")
        let second = prInfo(cwd: "/tmp/swr-a")
        expectEq(second.num, 7); expectEq(second.url, "https://g/pr/7")
        lk.lock(); expectEq(calls, 1, "a fresh cache entry doesn't refetch"); lk.unlock()
    }

    test("prInfo: a stale entry is served now and revalidated once in the background") {
        let lk = NSLock()
        var calls = 0
        let gate = DispatchSemaphore(value: 0)
        let origFetch = prFetch
        defer { prFetch = origFetch; onPRFactsChanged = nil; gate.signal() }
        prFetch = { _ in lk.lock(); calls += 1; lk.unlock(); gate.wait(); return (2, .fail, "https://g/pr/2") }
        prLock.lock()
        prCache["/tmp/swr-b"] = (1, nil, "https://g/pr/1", Date(timeIntervalSinceNow: -120))
        prFetching.removeAll()
        prLock.unlock()

        let got = prInfo(cwd: "/tmp/swr-b")
        expectEq(got.num, 1, "the stale value is shown while revalidating")
        _ = prInfo(cwd: "/tmp/swr-b")   // fetch still in flight — must not enqueue a second one
        gate.signal()
        expect(waitUntil { prLock.lock(); defer { prLock.unlock() }; return prCache["/tmp/swr-b"]?.num == 2 },
               "revalidation landed")
        expectEq(prInfo(cwd: "/tmp/swr-b").num, 2)
        lk.lock(); expectEq(calls, 1, "in-flight dedup: one fetch per cwd"); lk.unlock()
    }

    test("gitFacts: linked worktree is detected and shares the repoKey") {
        let repo = testTmpDir + "/gitfacts-repo"           // created by the previous test
        let wt = testTmpDir + "/gitfacts-wt"
        _ = runCommand([gitBin, "-C", repo, "worktree", "add", "-b", "feature", wt])
        let main = gitFacts(cwd: repo)
        let sub = gitFacts(cwd: wt)
        expectEq(sub.branch, "feature")
        expect(sub.isWorktree == true, "linked worktree detected")
        expectEq(sub.repoKey, main.repoKey, "worktrees group under the same repo key")
    }

    test("gitFacts: a non-repo directory yields nothing at all") {
        let plain = testTmpDir + "/not-a-repo"
        try! FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let f = gitFacts(cwd: plain)
        expectNil(f.branch)
        expectNil(f.repoKey)
        expectNil(f.repoName)
        expect(!f.isWorktree, "nothing to be a worktree of")
    }
}
