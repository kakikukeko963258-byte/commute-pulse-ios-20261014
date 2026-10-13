import SwiftUI
import WidgetKit
import ActivityKit

struct CommuteEntry: TimelineEntry {
    var date: Date
    var display: DisplayState
}

struct CommuteProvider: TimelineProvider {
    func placeholder(in context: Context) -> CommuteEntry {
        CommuteEntry(date: .now, display: .empty())
    }
    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        completion(CommuteEntry(date: .now, display: SharedStore.read()?.current ?? .empty()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        guard let envelope = SharedStore.read(recordExtensionReceipt: true) else {
            let notice = "共有データなし・アプリで計測と署名診断を確認してください"
            completion(Timeline(entries: [CommuteEntry(date: .now, display: .empty(notice: notice))],
                                policy: .after(Date.now.addingTimeInterval(15 * 60))))
            return
        }
        if envelope.current.isSimulated {
            completion(Timeline(entries: [CommuteEntry(date: .now, display: envelope.current)], policy: .never))
            return
        }
        guard envelope.validUntil > .now else {
            completion(Timeline(entries: [CommuteEntry(date: .now,
                display: .empty(notice: "推定の期限に到達・アプリで位置を再確認してください"))],
                policy: .after(Date.now.addingTimeInterval(15 * 60))))
            return
        }
        let past = envelope.timeline.filter { $0.date <= .now }.last?.state ?? envelope.current
        var entries = [CommuteEntry(date: .now, display: past)]
        entries += envelope.timeline.filter { $0.date > .now && $0.date < envelope.validUntil }
            .map { CommuteEntry(date: $0.date, display: $0.state) }
        entries.append(CommuteEntry(date: envelope.validUntil,
            display: .empty(at: envelope.validUntil, notice: "推定の期限に到達・アプリで位置を再確認してください")))
        completion(Timeline(entries: entries, policy: .after(envelope.validUntil)))
    }
}

struct CommuteProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: CommuteProvider()) { entry in
            RouteProgressView(state: entry.display)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("通学リアルタイム進捗")
        .description("位置と予定時刻から推定。運行遅延は取得しません。")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct CommuteLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteAttributes.self) { context in
            RouteProgressView(state: context.state.display, compact: true, stale: context.isStale)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.display.routeName)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.display.nextStation.map { "次 " + $0 } ?? "乗車前")
                }
            } compactLeading: {
                Text(context.state.display.badge)
            } compactTrailing: {
                Text(context.state.display.nextStation ?? "待機").font(.caption2)
            } minimal: {
                Text(context.state.display.badge.isEmpty ? "通" : context.state.display.badge)
            }
        }
    }
}

@main struct CommuteWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommuteProgressWidget()
        CommuteLiveActivityWidget()
    }
}
