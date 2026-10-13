import Foundation
import CommuteCore

enum DebugScenario: String, CaseIterable, Identifiable {
    case missedOrigin = "出発駅を検出しない"
    case intermediateRecovery = "途中駅でGPS復帰"
    case reverse = "田町から高輪GW方面"
    case midnight = "日付またぎ"
    case express = "急行・通過駅"
    case gpsMissing = "GPS欠落"
    case ambiguous = "複数候補"
    case road = "automotiveだけの道路移動"
    var id: String { rawValue }
}

/// Synthetic observations enter exactly the same engine as CLLocation callbacks.
/// Timetable facts are never generated or overwritten by this code.
enum DebugPlayback {
    static func observations(for scenario: DebugScenario, dataset: TimetableDataset) -> [TravelObservation] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: dataset.timeZone) ?? .current
        var day = calendar.startOfDay(for: .now)
        let eligible = dataset.services.filter {
            $0.stops.count >= 2
                && (scenario == .express ? $0.routeID == "denentoshi" && $0.trainType == .express : $0.routeID == "yamanote")
                && (scenario == .reverse ? $0.direction == .reverse && $0.stops.first?.stationID == "tamachi" : $0.direction == .forward)
                && ([.missedOrigin, .intermediateRecovery, .gpsMissing, .ambiguous].contains(scenario)
                    ? $0.stops.first?.stationID == "shibuya" : true)
                && (scenario == .midnight ? ($0.stops.last?.departureMinute ?? 0) >= 1440 : true)
        }
        guard let service = eligible.sorted(by: {
            let a = abs(($0.stops.first?.departureMinute ?? 0) - 510)
            let b = abs(($1.stops.first?.departureMinute ?? 0) - 510)
            return a == b ? $0.id < $1.id : a < b
        }).first else { return [] }
        // Pick a matching calendar day rather than applying weekday data to a holiday.
        var matchedDay = false
        let timetableClock = TimetableClock(dataset: dataset)
        for _ in 0..<14 {
            if timetableClock.operates(service, on: day) {
                matchedDay = true; break
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        guard matchedDay else { return [] }
        let route = dataset.route(service.routeID)
        var output: [TravelObservation] = []
        let stops = service.stops
        for (index, stop) in stops.enumerated() {
            guard let station = dataset.station(stop.stationID) else { continue }
            let time = day.addingTimeInterval(Double(stop.departureMinute * 60))
            let skip = (scenario == .missedOrigin || scenario == .intermediateRecovery) && index == 0
            if !skip {
                let missing = scenario == .gpsMissing && index > 0
                let railCoordinate = coordinate(at: station, route: route)
                let coordinate = scenario == .road
                    ? Coordinate(latitude: station.latitude + 0.012, longitude: station.longitude + 0.008)
                    : railCoordinate
                output.append(TravelObservation(timestamp: time.addingTimeInterval(-15),
                    coordinate: missing ? nil : coordinate, horizontalAccuracy: missing ? nil : 18,
                    speedMetersPerSecond: 1.0, motion: .automotive, simulated: true))
            }
            guard index + 1 < stops.count, let destination = dataset.station(stops[index + 1].stationID) else { continue }
            let end = day.addingTimeInterval(Double(stops[index + 1].displayArrivalMinute * 60))
            guard end > time else { continue }
            for fraction in [0.25, 0.65] {
                let middle = interpolate(from: station, to: destination, route: route, fraction: fraction)
                let omit = (scenario == .gpsMissing && !(index == 0 && fraction == 0.25))
                    || (scenario == .intermediateRecovery && index == 0)
                if skip && scenario == .missedOrigin { continue }
                output.append(TravelObservation(timestamp: time.addingTimeInterval(end.timeIntervalSince(time) * fraction),
                    coordinate: omit ? nil : scenario == .road
                        ? Coordinate(latitude: middle.latitude + 0.012, longitude: middle.longitude + 0.008) : middle,
                    horizontalAccuracy: omit ? nil : scenario == .ambiguous ? 180 : 20,
                    speedMetersPerSecond: omit ? nil : 14,
                    courseDegrees: bearing(from: station.coordinate, to: destination.coordinate),
                    motion: .automotive, simulated: true))
            }
        }
        if scenario == .ambiguous { return Array(output.prefix(3)) }
        return output.sorted { $0.timestamp < $1.timestamp }
    }

    private static func coordinate(at station: StationDefinition, route: RouteDefinition?) -> Coordinate {
        let point = route?.segments.first(where: { $0.fromStationID == station.id })?.coordinates.first
            ?? route?.segments.first(where: { $0.toStationID == station.id })?.coordinates.last
        guard let point, point.count == 2 else { return station.coordinate }
        return Coordinate(latitude: point[0], longitude: point[1])
    }

    private static func interpolate(from: StationDefinition, to: StationDefinition,
                                    route: RouteDefinition?, fraction: Double) -> Coordinate {
        guard let route, let a = route.stationIDs.firstIndex(of: from.id),
              let b = route.stationIDs.firstIndex(of: to.id), a != b else { return from.coordinate }
        // Express can span several station-to-station shapes. Use all of them.
        let ordered = route.segments[min(a, b)..<max(a, b)].flatMap(\.coordinates)
        let points = a < b ? ordered : Array(ordered.reversed())
        let coordinates = points.map { Coordinate(latitude: $0[0], longitude: $0[1]) }
        let lengths = zip(coordinates, coordinates.dropFirst()).map { left, right in
            RailGeometry.distance(left, right)
        }
        var remaining = lengths.reduce(0, +) * fraction
        for index in lengths.indices {
            if remaining <= lengths[index] {
                let ratio = lengths[index] > 0 ? remaining / lengths[index] : 0
                let start = coordinates[index], end = coordinates[index + 1]
                return Coordinate(latitude: start.latitude + (end.latitude - start.latitude) * ratio,
                                  longitude: start.longitude + (end.longitude - start.longitude) * ratio)
            }
            remaining -= lengths[index]
        }
        return coordinates.last ?? from.coordinate
    }

    private static func bearing(from: Coordinate, to: Coordinate) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let lon = (to.longitude - from.longitude) * .pi / 180
        let value = atan2(sin(lon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon))
        return (value * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
