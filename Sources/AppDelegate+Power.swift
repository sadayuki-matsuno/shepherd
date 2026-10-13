import AppKit
import IOKit.pwr_mgt

// 稼働中のセッションがある間は Mac をアイドルスリープさせない（IOKit 電源アサーション）。
// 判定は keepAwakeCount（Models.swift・テスト済み）。refresh 完了ごとに呼ばれ、必要状態が変わった
// ときだけ取得・解放する。件数の変化は名前の書き換えだけで済ませる（`pmset -g assertions` に出る名前）。
// プロセス終了時はカーネルが自動で解放するので、終了処理は持たない。
extension AppDelegate {
    func updateSleepAssertions(rows: [AgentRow]) {
        // fixture モード（demo 盤面・SHEPHERD_DUMP）は架空の working 行で実機の電源を握らない。
        let count = routineFixtureMode ? 0 : keepAwakeCount(rows)
        let name = "Shepherd: \(count) session\(count == 1 ? "" : "s") working"
        let renamed = name != sleepAssertionName
        sleepAssertionName = name
        sleepAssertionID = syncAssertion(sleepAssertionID, type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                                         active: preventSleepWhileWorking && count > 0, name: name, renamed: renamed)
        displaySleepAssertionID = syncAssertion(displaySleepAssertionID, type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                                active: preventDisplaySleepWhileWorking && count > 0, name: name, renamed: renamed)
    }

    private func syncAssertion(_ id: IOPMAssertionID?, type: String, active: Bool, name: String, renamed: Bool) -> IOPMAssertionID? {
        if let id = id {
            guard active else { IOPMAssertionRelease(id); return nil }
            if renamed { IOPMAssertionSetProperty(id, kIOPMAssertionNameKey as CFString, name as CFString) }
            return id
        }
        guard active else { return nil }
        var newId = IOPMAssertionID(0)
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             name as CFString, &newId) == kIOReturnSuccess
        return ok ? newId : nil
    }

    @objc func togglePreventSleep() {
        preventSleepWhileWorking.toggle()
        defaults.set(preventSleepWhileWorking, forKey: "preventSleepWhileWorking")
        updateSleepAssertions(rows: lastRows ?? [])
    }

    @objc func togglePreventDisplaySleep() {
        preventDisplaySleepWhileWorking.toggle()
        defaults.set(preventDisplaySleepWhileWorking, forKey: "preventDisplaySleepWhileWorking")
        updateSleepAssertions(rows: lastRows ?? [])
    }
}
