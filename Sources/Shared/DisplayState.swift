import Foundation
import ActivityKit

struct DisplayStation: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
}

struct TimedLeg: Codable, Hashable, Sendable {
    var fromID: String
    var toID: String
    var start: Date
    var end: Date
}

/// Small, versioned presentation payload, independent of sensor processing.
struct DisplayState: Codable, Hashable, Sendable {
    var version = 1
    var routeID: String?
    var routeName: String
    var badge: String
    var trainKind: String
    var phase: String
    var direction: String
    var stations: [DisplayStation]
    var nextStation: String?
    var estimatedArrival: Date?
    var confidence: String
    var publishedAt: Date
    var isSimulated: Bool
    var overallProgress: Double
    var legs: [TimedLeg]
    var notice: String

    static func empty(at date: Date = .now, notice: String = "アプリで通学計測を開始してください") -> Self {
        Self(routeID: nil, routeName: "乗車前", badge: "", trainKind: "",
             phase: "idle", direction: "", stations: [], nextStation: nil,
             estimatedArrival: nil, confidence: "未判定", publishedAt: date,
             isSimulated: false, overallProgress: 0, legs: [], notice: notice)
    }

    var isExpress: Bool { trainKind.contains("急行") }
    var staleDate: Date {
        estimatedArrival ?? publishedAt.addingTimeInterval(5 * 60)
    }
}

struct ScheduledDisplay: Codable, Sendable {
    var date: Date
    var state: DisplayState
}

struct SnapshotEnvelope: Codable, Sendable {
    var version = 1
    var current: DisplayState
    var timeline: [ScheduledDisplay]
    var validUntil: Date
}

struct CommuteAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var display: DisplayState
    }
    var sessionID: UUID
}
