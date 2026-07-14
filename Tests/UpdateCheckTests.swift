import Foundation

// UpdateCheck — pure logic: semver-ish comparison and the GitHub releases/latest payload parse.

func runUpdateCheckTests() {
    test("isUpdateAvailable: newer patch / equal / older") {
        expect(isUpdateAvailable(latest: "v0.0.4", current: "0.0.3"), "0.0.4 > 0.0.3")
        expect(!isUpdateAvailable(latest: "v0.0.3", current: "0.0.3"), "equal is not an update")
        expect(!isUpdateAvailable(latest: "v0.0.2", current: "0.0.3"), "older is not an update")
    }

    test("isUpdateAvailable: numeric compare, not lexicographic") {
        expect(isUpdateAvailable(latest: "v0.0.10", current: "0.0.9"), "0.0.10 > 0.0.9 numerically")
        expect(isUpdateAvailable(latest: "v0.10.0", current: "0.9.9"), "0.10.0 > 0.9.9")
        expect(!isUpdateAvailable(latest: "v1.9.0", current: "1.10.0"), "1.9 < 1.10")
    }

    test("isUpdateAvailable: component count mismatch pads with zero") {
        expect(isUpdateAvailable(latest: "v1.0", current: "0.9.9"), "1.0 > 0.9.9")
        expect(!isUpdateAvailable(latest: "v1.0", current: "1.0.0"), "1.0 == 1.0.0")
        expect(isUpdateAvailable(latest: "v1.0.1", current: "1.0"), "1.0.1 > 1.0")
    }

    test("isUpdateAvailable: v prefix optional on both sides") {
        expect(isUpdateAvailable(latest: "0.0.4", current: "v0.0.3"), "bare latest / prefixed current")
    }

    test("isUpdateAvailable: garbage never claims an update") {
        expect(!isUpdateAvailable(latest: "", current: "0.0.3"), "empty latest")
        expect(!isUpdateAvailable(latest: "v0.0.4", current: ""), "empty current — can't compare, stay quiet")
        expect(!isUpdateAvailable(latest: "abc", current: "0.0.3"), "non-numeric latest")
        expect(!isUpdateAvailable(latest: "v0.0.x", current: "0.0.3"), "non-numeric component")
    }

    test("parseLatestRelease: happy path") {
        let json = #"{"tag_name":"v0.0.4","html_url":"https://github.com/sadayuki-matsuno/shepherd/releases/tag/v0.0.4","draft":false,"prerelease":false}"#
        let rel = parseLatestRelease(json.data(using: .utf8)!)
        expectEq(rel?.tag ?? "", "v0.0.4", "tag")
        expectEq(rel?.url ?? "", "https://github.com/sadayuki-matsuno/shepherd/releases/tag/v0.0.4", "url")
    }

    test("parseLatestRelease: drafts and prereleases are not updates") {
        let draft = #"{"tag_name":"v0.0.5","html_url":"https://x","draft":true,"prerelease":false}"#
        expectNil(parseLatestRelease(draft.data(using: .utf8)!), "draft")
        let pre = #"{"tag_name":"v0.0.5","html_url":"https://x","draft":false,"prerelease":true}"#
        expectNil(parseLatestRelease(pre.data(using: .utf8)!), "prerelease")
    }

    test("parseLatestRelease: malformed payloads return nil") {
        expectNil(parseLatestRelease(Data()), "empty body")
        expectNil(parseLatestRelease("not json".data(using: .utf8)!), "not json")
        expectNil(parseLatestRelease(#"{"html_url":"https://x"}"#.data(using: .utf8)!), "missing tag_name")
        // A missing html_url still yields the release — the UI falls back to the releases page.
        let noURL = parseLatestRelease(#"{"tag_name":"v0.0.4"}"#.data(using: .utf8)!)
        expectEq(noURL?.tag ?? "", "v0.0.4", "tag without url")
        expectEq(noURL?.url ?? "", "https://github.com/sadayuki-matsuno/shepherd/releases", "url falls back to the releases page")
    }
}
