import Foundation

func runClaudeUsageTests() {
    test("parseUsageISODate") {
        expect(parseUsageISODate("2026-07-07T01:00:00.123Z") != nil, "fractional seconds")
        expect(parseUsageISODate("2026-07-07T01:00:00Z") != nil, "whole seconds")
        expectEq(parseUsageISODate("2026-07-07T01:00:00.000Z"), parseUsageISODate("2026-07-07T01:00:00Z"),
                 "both forms hit the same instant")
        expectNil(parseUsageISODate(nil))
        expectNil(parseUsageISODate(""))
        expectNil(parseUsageISODate("garbage"))
    }
}
