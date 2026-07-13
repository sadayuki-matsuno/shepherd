import Foundation

// Test runner. Build & run via ./test.sh — see that script for what's linked.

runModelsTests()
runTranscriptTests()
runTeamsTests()
runStatusStoreTests()
runGitHubFactsTests()
runCommandsTests()
runClaudeUsageTests()

try? FileManager.default.removeItem(atPath: testTmpDir)

if testFailures == 0 {
    print("OK — \(testAssertions) assertions passed")
    exit(0)
} else {
    print("FAILED — \(testFailures) of \(testAssertions) assertions failed")
    exit(1)
}
