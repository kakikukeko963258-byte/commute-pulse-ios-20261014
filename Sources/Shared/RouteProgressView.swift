import SwiftUI

struct RouteProgressView: View {
    let state: DisplayState
    var compact = false
    var stale = false

    private var tint: Color {
        if state.isExpress { return Color(red: 0.94, green: 0.24, blue: 0.28) }
        return state.routeID == "denentoshi"
            ? Color(red: 0.10, green: 0.67, blue: 0.38)
            : Color(red: 0.39, green: 0.68, blue: 0.13)
    }

    private var phaseTitle: String {
        switch state.phase {
        case "riding": return "乗車中"
        case "waiting": return "乗車待ち"
        case "transferring": return "乗換中"
        case "arrived": return "到着"
        default: return "乗車前"
        }
    }

    private var subtitle: String {
        let direction = state.direction + (state.trainKind.isEmpty ? "" : "・" + state.trainKind)
        return state.phase == "riding" ? direction
            : phaseTitle + (direction.isEmpty ? "" : "・" + direction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 12) {
            HStack(spacing: 8) {
                if !state.badge.isEmpty {
                    Text(state.badge).font(.system(size: compact ? 12 : 15, weight: .black))
                        .padding(6).background(tint, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.white).accessibilityLabel("路線記号 " + state.badge)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.routeID == nil ? phaseTitle : state.routeName)
                        .font(.system(size: compact ? 14 : 21, weight: .bold)).lineLimit(1)
                    if !state.direction.isEmpty {
                        Text(subtitle)
                            .font(.system(size: compact ? 9 : 12)).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Text(state.isSimulated ? "シミュレーション" : state.confidence)
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
                    .foregroundStyle(state.isSimulated ? .orange : .secondary)
            }
            if state.stations.count > 1 {
                GeometryReader { proxy in
                    let count = state.stations.count
                    let cellWidth = proxy.size.width / CGFloat(count)
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(0..<(count - 1), id: \.self) { index in
                                segment(index: index)
                                    .frame(width: cellWidth)
                            }
                        }
                        .padding(.horizontal, cellWidth / 2)
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(state.stations) { station in
                                VStack(spacing: compact ? 8 : 10) {
                                    Circle().fill(tint).frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                                    VerticalStationName(name: station.name, compact: compact)
                                }
                                .frame(width: cellWidth)
                            }
                        }
                    }
                }
                .frame(height: compact ? (state.routeID == "denentoshi" ? 61 : 49) : 85)
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let next = state.nextStation {
                    Text((stale ? "最終更新の次駅 " : "次 ") + next)
                        .fontWeight(.semibold)
                } else { Text(phaseTitle) }
                Spacer(minLength: 2)
                if let arrival = state.estimatedArrival {
                    HStack(spacing: 2) {
                        Text("推定").foregroundStyle(.secondary)
                        Text(arrival, style: .time).monospacedDigit()
                    }
                }
            }.font(.system(size: compact ? 10 : 14)).lineLimit(1)
            if !compact || state.routeID == nil || state.isSimulated || stale {
                Text(stale ? "位置の再確認待ち・バーは予定時刻に基づく推定" : state.notice)
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 4)
            }
        }
        .padding(compact ? 12 : 16)
        .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
        .environment(\.locale, Locale(identifier: "ja_JP"))
    }

    @ViewBuilder private func segment(index: Int) -> some View {
        let from = state.stations[index].id
        let to = state.stations[index + 1].id
        if state.isSimulated {
            // A stepped virtual clock must not be mistaken for the device wall clock.
            let value = min(1, max(0, state.overallProgress * Double(state.stations.count - 1) - Double(index)))
            ProgressView(value: value).tint(tint)
        } else if let interval = intervalForSegment(from: from, to: to), interval.upperBound > interval.lowerBound {
            ProgressView(timerInterval: interval, countsDown: false)
                .labelsHidden().tint(tint)
        } else {
            let filled = Double(index + 1) / Double(state.stations.count - 1) <= state.overallProgress
            ProgressView(value: filled ? 1.0 : 0.0).tint(tint)
        }
    }

    private func intervalForSegment(from: String, to: String) -> ClosedRange<Date>? {
        guard let fromIndex = state.stations.firstIndex(where: { $0.id == from }),
              let toIndex = state.stations.firstIndex(where: { $0.id == to }) else { return nil }
        for leg in state.legs {
            guard let a = state.stations.firstIndex(where: { $0.id == leg.fromID }),
                  let b = state.stations.firstIndex(where: { $0.id == leg.toID }),
                  b > a, fromIndex >= a, toIndex <= b, leg.end > leg.start else { continue }
            let duration = leg.end.timeIntervalSince(leg.start)
            let start = leg.start.addingTimeInterval(duration * Double(fromIndex - a) / Double(b - a))
            let end = leg.start.addingTimeInterval(duration * Double(toIndex - a) / Double(b - a))
            return start...end
        }
        return nil
    }
}

private struct VerticalStationName: View {
    let name: String
    let compact: Bool
    private var pieces: [String] {
        name == "高輪GW" ? ["高", "輪", "GW"] : name.map(String.init)
    }
    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, character in
                Text(character).font(.system(size: compact ? 10 : 14, weight: .medium))
                    .fixedSize()
                    .frame(height: compact ? 11 : 17)
            }
        }.accessibilityLabel(name)
    }
}
