import ActivityKit
import Foundation

@MainActor final class LiveActivityClient {
    private var activity: Activity<CommuteAttributes>?
    private(set) var status = "未開始"
    var onStatus: ((String) -> Void)?

    func start(display: DisplayState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            report("Live Activityが許可されていません。設定を確認してください。"); return
        }
        if activity != nil { update(display: display); return }
        // Reattach an existing activity after a process restart.
        if let existing = Activity<CommuteAttributes>.activities.first {
            activity = existing
            update(display: display)
            report("既存Activityへ再接続・ロック画面への表示は実機で確認してください")
            return
        }
        do {
            let content = ActivityContent(state: CommuteAttributes.ContentState(display: display),
                                          staleDate: display.staleDate)
            activity = try Activity.request(attributes: CommuteAttributes(sessionID: UUID()),
                                            content: content, pushType: nil)
            report("開始要求成功・ロック画面への実表示は未確認")
        } catch { report("開始要求失敗: \(error.localizedDescription)") }
    }

    func update(display: DisplayState) {
        guard let activity else { return }
        let state = CommuteAttributes.ContentState(display: display)
        guard let data = try? JSONEncoder().encode(state), data.count < 3_900 else {
            report("Activityデータが上限に近いため更新を見送りました"); return
        }
        Task {
            await activity.update(ActivityContent(state: state, staleDate: display.staleDate))
        }
    }

    func end(display: DisplayState) {
        guard let current = activity else { return }
        activity = nil
        Task {
            await current.end(ActivityContent(state: CommuteAttributes.ContentState(display: display),
                                              staleDate: nil), dismissalPolicy: .immediate)
        }
        report("終了要求を送信")
    }

    private func report(_ message: String) { status = message; onStatus?(message) }
}
