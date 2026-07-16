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

    test("parseUsage: limits windows") {
        let json: [String: Any] = [
            "limits": [
                ["kind": "session", "group": "session", "percent": 8, "severity": "normal",
                 "resets_at": "2026-07-16T13:50:00Z", "is_active": true],
                ["kind": "weekly_all", "group": "weekly", "percent": 2, "severity": "normal",
                 "resets_at": "2026-07-23T08:00:00Z", "is_active": false],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 3, "severity": "normal",
                 "resets_at": "2026-07-23T08:00:00Z",
                 "scope": ["model": ["display_name": "Fable"]]],
            ],
        ]
        let snap = parseUsage(json)
        expectEq(snap.windows.count, 3)
        expectEq(snap.windows[0].key, "session")
        expectEq(snap.windows[1].key, "weekly")
        expectEq(snap.windows[2].key, "Fable")
        expectNil(snap.error)
    }

    test("parseUsage: flat fallback when limits absent") {
        let json: [String: Any] = [
            "five_hour": ["utilization": 22.0, "resets_at": "2026-07-16T13:50:00Z"],
            "seven_day": ["utilization": 5.0, "resets_at": "2026-07-23T08:00:00Z"],
        ]
        let snap = parseUsage(json)
        expectEq(snap.windows.count, 2)
        expectEq(snap.windows[0].key, "session")
        expectEq(snap.windows[1].key, "weekly")
    }

    test("parseUsage: spend disabled — used $0.00 comes through, balance stays nil") {
        let json: [String: Any] = [
            "limits": [],
            "spend": [
                "used": ["amount_minor": 0, "currency": "USD", "exponent": 2],
                "limit": NSNull(), "percent": 0, "severity": "normal",
                "enabled": false, "cap": NSNull(), "balance": NSNull(),
            ],
        ]
        guard let credit = parseUsage(json).credit else { return expect(false, "credit parsed") }
        expect(!credit.enabled, "enabled=false")
        expectEq(credit.usedText, "$0.00")
        expectNil(credit.balanceText, "null balance → no text")
        expectNil(credit.limitText)
        expectNil(credit.remainingText)
    }

    test("parseUsage: spend enabled (monthly extra usage, 2026-07-16 live shape)") {
        // Real shape from a Max account with extra usage on: `limit` is the monthly cap in money,
        // `balance` stays null, `cap` is a NESTED {money, credits} object (not a money object).
        let json: [String: Any] = [
            "limits": [],
            "spend": [
                "used": ["amount_minor": 5659, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 20000, "currency": "USD", "exponent": 2],
                "cap": ["money": NSNull(), "credits": ["amount_minor": 20000, "exponent": 2]],
                "balance": NSNull(),
                "percent": 28, "severity": "normal", "enabled": true,
            ],
        ]
        guard let credit = parseUsage(json).credit else { return expect(false, "credit parsed") }
        expect(credit.enabled, "enabled=true")
        expectEq(credit.usedText, "$56.59")
        expectEq(credit.limitText, "$200.00")
        expectNil(credit.balanceText, "balance null even when enabled")
        expectEq(credit.remainingText, "$143.41", "remaining computed as limit - used")
        expectEq(credit.percent.map { Int($0) }, 28)
        expectEq(credit.severity, "normal")
    }

    test("parseUsage: spend with a prepaid balance keeps the API's own number") {
        let json: [String: Any] = [
            "limits": [],
            "spend": [
                "used": ["amount_minor": 540, "currency": "USD", "exponent": 2],
                "balance": ["amount_minor": 660, "currency": "USD", "exponent": 2],
                "percent": 45, "severity": "warning", "enabled": true,
            ],
        ]
        guard let credit = parseUsage(json).credit else { return expect(false, "credit parsed") }
        expectEq(credit.balanceText, "$6.60")
        expectNil(credit.limitText)
        expectNil(credit.remainingText, "no limit → nothing to subtract from")
    }

    test("parseUsage: remaining not computed across mismatched currencies") {
        let json: [String: Any] = [
            "limits": [],
            "spend": [
                "used": ["amount_minor": 540, "currency": "EUR", "exponent": 2],
                "limit": ["amount_minor": 20000, "currency": "USD", "exponent": 2],
                "enabled": true,
            ],
        ]
        expectNil(parseUsage(json).credit?.remainingText)
    }

    test("parseUsage: no spend object → no credit") {
        expectNil(parseUsage(["limits": []]).credit)
    }

    test("parseUsage: spend carries the numeric used amount for delta detection") {
        let json: [String: Any] = [
            "limits": [],
            "spend": [
                "used": ["amount_minor": 5659, "currency": "USD", "exponent": 2],
                "enabled": true,
            ],
        ]
        expectEq(parseUsage(json).credit?.usedMinor, 5659)
        expectNil(parseUsage(["limits": [], "spend": ["used": NSNull(), "enabled": true]]).credit?.usedMinor,
                  "null used → no numeric")
    }

    test("creditBurnActive: spend delta is the direct proof") {
        let credit = CreditInfo(enabled: true, usedText: "$56.59", limitText: nil, balanceText: nil,
                                remainingText: nil, percent: 28, severity: "normal", usedMinor: 5659)
        let calm = [UsageWindow(key: "session", label: "5h", percent: 42, resetsAt: nil, severity: "normal")]
        expect(creditBurnActive(prevUsedMinor: 5000, credit: credit, windows: calm, anyWorking: false),
               "used grew since last snapshot → burning, even with no visible working row")
        expect(!creditBurnActive(prevUsedMinor: 5659, credit: credit, windows: calm, anyWorking: true),
               "used unchanged, windows calm → not burning")
        expect(!creditBurnActive(prevUsedMinor: nil, credit: credit, windows: calm, anyWorking: true),
               "no previous snapshot → delta can't fire")
        expect(!creditBurnActive(prevUsedMinor: 6000, credit: credit, windows: calm, anyWorking: true),
               "used went DOWN (monthly rollover) → not burning")
    }

    test("creditBurnActive: an exhausted window burns only while something works") {
        let credit = CreditInfo(enabled: true, usedText: "$0.00", limitText: nil, balanceText: nil,
                                remainingText: nil, percent: 0, severity: "normal", usedMinor: 0)
        let capped = [UsageWindow(key: "session", label: "5h", percent: 100, resetsAt: nil, severity: "critical")]
        expect(creditBurnActive(prevUsedMinor: 0, credit: credit, windows: capped, anyWorking: true),
               "window exhausted + extra usage on + a working session → burning")
        expect(!creditBurnActive(prevUsedMinor: 0, credit: credit, windows: capped, anyWorking: false),
               "capped but idle board → not burning (a capped window persists until reset)")
        let disabled = CreditInfo(enabled: false, usedText: "$0.00", limitText: nil, balanceText: nil,
                                  remainingText: nil, percent: 0, severity: "normal", usedMinor: 0)
        expect(!creditBurnActive(prevUsedMinor: 0, credit: disabled, windows: capped, anyWorking: true),
               "extra usage off → nothing bills to credits even at 100%")
        expect(!creditBurnActive(prevUsedMinor: 0, credit: nil, windows: capped, anyWorking: true),
               "no spend block at all → false")
    }

    test("moneyText: shapes and currencies") {
        expectEq(moneyText(["amount_minor": 540, "currency": "USD", "exponent": 2]), "$5.40")
        expectEq(moneyText(["amount_minor": 1200, "currency": "EUR", "exponent": 2]), "EUR 12.00",
                 "non-USD keeps the code as prefix")
        expectEq(moneyText(["amount_minor": 5, "currency": "USD", "exponent": 0]), "$5",
                 "exponent 0 → no decimals")
        expectEq(moneyText(["amount_minor": 7, "currency": "USD"]), "$0.07",
                 "missing exponent defaults to 2")
        expectNil(moneyText(NSNull()))
        expectNil(moneyText(nil))
        expectNil(moneyText("garbage"))
        expectNil(moneyText([String: Any]()), "no amount_minor")
    }

    test("planTierDisplay: rate_limit_tier → chip text") {
        expectEq(planTierDisplay("default_claude_max_20x"), "MAX 20X")
        expectEq(planTierDisplay("default_claude_max_5x"), "MAX 5X")
        expectEq(planTierDisplay("default_claude_pro"), "PRO")
        expectEq(planTierDisplay("raven"), "RAVEN", "unknown tier shown as-is, uppercased")
        expectNil(planTierDisplay(nil))
        expectNil(planTierDisplay(""))
        expectNil(planTierDisplay("default"), "bare 'default' carries no plan info")
    }

    test("agoText: seconds / minutes / hours (either locale)") {
        expect(["32秒前", "32s ago"].contains(agoText(32)), "seconds: \(agoText(32))")
        expect(["0秒前", "0s ago"].contains(agoText(-5)), "negative clamps to 0")
        expect(["3分前", "3m ago"].contains(agoText(3 * 60 + 20)), "minutes: \(agoText(200))")
        expect(["2時間前", "2h ago"].contains(agoText(2 * 3600 + 90)), "hours")
    }
}
