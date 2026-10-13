import Foundation
import CommuteCore

enum DisplayAdapter {
    static func make(_ snapshot: ProgressSnapshot, dataset: TimetableDataset,
                     future: [DatedSnapshot] = []) -> DisplayState {
        var legs: [TimedLeg] = []
        for s in [snapshot] + future.map(\.snapshot) {
            guard s.routeID == snapshot.routeID, s.direction == snapshot.direction,
                  s.chosenServiceID == snapshot.chosenServiceID,
                  let from = s.progressFromStationID, let to = s.progressToStationID,
                  let start = s.segmentStart, let end = s.segmentEnd, end > start,
                  !legs.contains(where: { $0.fromID == from && $0.toID == to && $0.start == start }) else { continue }
            legs.append(TimedLeg(fromID: from, toID: to, start: start, end: end))
        }
        let type: String
        switch snapshot.trainType {
        case .express: type = "急行"
        case .semiExpress: type = "準急"
        case .local: type = "各駅停車"
        default: type = snapshot.candidates.count > 1 ? "候補複数" : "種別確認中"
        }
        let confidence: String
        switch snapshot.confidence {
        case .high: confidence = "確度 高"
        case .medium: confidence = "確度 中"
        case .low: confidence = "確度 低"
        case .unavailable: confidence = "未判定"
        }
        return DisplayState(routeID: snapshot.routeID, routeName: snapshot.routeName ?? "乗車前",
            badge: snapshot.routeSymbol ?? "", trainKind: type, phase: snapshot.phase.rawValue,
            direction: snapshot.routeID == nil ? "" : snapshot.directionLabel,
            stations: snapshot.stations.map { DisplayStation(id: $0.id, name: $0.name) },
            nextStation: dataset.station(snapshot.nextStationID)?.displayName,
            estimatedArrival: snapshot.estimatedArrival, confidence: confidence,
            publishedAt: snapshot.date, isSimulated: snapshot.isSimulated,
            overallProgress: snapshot.overallProgress, legs: legs, notice: snapshot.notice)
    }
}
