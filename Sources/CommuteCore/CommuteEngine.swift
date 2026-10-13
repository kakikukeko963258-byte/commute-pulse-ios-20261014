import Foundation

public struct InferenceConfiguration: Sendable {
    public var maximumHorizontalAccuracy = 180.0
    public var maximumTrackDistance = 160.0
    public var stationRadius = 110.0
    public var minimumRailSpeed = 4.0
    public var staleObservationSeconds = 150.0
    public var maximumPredictionSeconds = 45.0 * 60
    public var ambiguityMargin = 0.13
    public init() {}
}

/// Sensor-neutral inference: real Core Location/Core Motion inputs and debug observations enter here.
/// A candidate is a timetable hypothesis, never a delay feed or a claim that a car is a train.
public struct CommuteEngine: Sendable {
    public let timetable: TimetableDataset
    public var configuration: InferenceConfiguration
    private let clock: TimetableClock
    private var lastObservation: TravelObservation?
    private var lastGoodObservation: TravelObservation?
    private var routeMatch: RailGeometry.Match?
    private var inferredDirection: TravelDirection?
    private var stationHistory: [StationVisit] = []
    private var activeCandidates: [ServiceMatch] = []
    private var ridingEvidence = false
    private var pedestrianSamples = 0
    private var transferTime: Date?
    private var lastSnapshot: ProgressSnapshot

    private struct StationVisit: Sendable {
        var stationID: String
        var routeID: String
        var date: Date
    }
    private struct ServiceMatch: Sendable {
        var service: TimetableService
        var serviceDate: Date
        var score: Double
        var stops: [TimetableStop]
        var observationOffset: TimeInterval = 0
    }
    private struct Projection {
        var from: TimetableStop
        var to: TimetableStop?
        var start: Date?
        var end: Date?
        var progress: Double
        var isBeforeDeparture: Bool
        var isComplete: Bool
    }

    public init(timetable: TimetableDataset, configuration: InferenceConfiguration = InferenceConfiguration()) {
        self.timetable = timetable; self.configuration = configuration; self.clock = TimetableClock(dataset: timetable)
        self.lastSnapshot = .empty(at: Date())
    }

    @discardableResult
    public mutating func ingest(_ observation: TravelObservation) -> ProgressSnapshot {
        // Late callbacks must not rewind the station history or a displayed timer.
        if let previous = lastObservation, observation.timestamp < previous.timestamp {
            return advance(to: previous.timestamp)
        }
        if let previous = lastObservation, previous.simulated != observation.simulated {
            reset(at: observation.timestamp)
        }
        lastObservation = observation
        guard let coordinate = observation.coordinate, coordinate.isValid,
              let accuracy = observation.horizontalAccuracy, accuracy.isFinite, accuracy >= 0,
              accuracy <= configuration.maximumHorizontalAccuracy else {
            return advance(to: observation.timestamp)
        }
        let previousObservation = lastGoodObservation
        let previousMatch = routeMatch
        let scoredMatches = timetable.routes.compactMap { route -> (RailGeometry.Match, Double)? in
            guard let match = RailGeometry.match(coordinate, to: route), match.distanceFromTrack <= configuration.maximumTrackDistance else { return nil }
            let continuityBonus = route.id == previousMatch?.routeID ? 0.10 : 0
            let uniqueStationBonus = nearestStation(coordinate, on: route).map { station -> Double in
                timetable.routes.filter { $0.stationIDs.contains(station.id) }.count == 1 ? 0.08 : 0
            } ?? 0
            return (match, 1 - match.distanceFromTrack / configuration.maximumTrackDistance + continuityBonus + uniqueStationBonus)
        }.sorted { $0.1 > $1.1 }

        guard let best = scoredMatches.first else {
            lastGoodObservation = observation
            // Walking away from the terminal is arrival; otherwise no rail inference survives off-track GPS.
            if lastSnapshot.phase != .arrived {
                routeMatch = nil; inferredDirection = nil; activeCandidates = []; ridingEvidence = false
            }
            return advance(to: observation.timestamp)
        }
        if scoredMatches.count > 1, best.1 - scoredMatches[1].1 < 0.06,
           previousMatch == nil, nearestStation(coordinate, on: timetable.route(best.0.routeID)!)?.id == "shibuya" {
            // Both lines occupy Shibuya: position there alone cannot identify the boarded line.
            var uncertain = ProgressSnapshot.empty(at: observation.timestamp)
            uncertain.phase = .waiting; uncertain.currentStationID = "shibuya"
            uncertain.notice = "渋谷で路線・進行方向を確認中"
            uncertain.latestObservationTime = observation.timestamp; uncertain.isSimulated = observation.simulated
            lastSnapshot = uncertain; lastGoodObservation = observation
            return uncertain
        }
        routeMatch = best.0
        if previousMatch?.routeID != best.0.routeID {
            if previousMatch != nil { transferTime = observation.timestamp }
            inferredDirection = nil; activeCandidates = []; ridingEvidence = false
        }
        lastGoodObservation = observation
        let route = timetable.route(best.0.routeID)!
        if let direction = direction(observation: observation, match: best.0,
                                     previousObservation: previousObservation, previousMatch: previousMatch) {
            inferredDirection = direction
        }
        let station = nearestStation(coordinate, on: route)
        let stationIsNew = station.map { stationHistory.last?.stationID != $0.id || stationHistory.last?.routeID != route.id } ?? false
        if let station, stationIsNew {
            stationHistory.append(StationVisit(stationID: station.id, routeID: route.id, date: observation.timestamp))
            stationHistory = Array(stationHistory.suffix(12))
        }
        if inferredDirection == nil { inferredDirection = historyDirection(on: route) }
        activeCandidates = matchServices(route: route, match: best.0, observation: observation, stationID: station?.id)
        if let station, stationIsNew, accuracy <= 80,
           RailGeometry.distance(coordinate, stationCoordinate(station, on: route)) <= 70 {
            activeCandidates = activeCandidates.map { candidate in
                guard let stop = candidate.stops.first(where: { $0.stationID == station.id && $0.stopKind == .stop }) else { return candidate }
                let scheduledArrival = clock.date(serviceDate: candidate.serviceDate, minute: stop.displayArrivalMinute)
                let difference = observation.timestamp.timeIntervalSince(scheduledArrival)
                // At an observed intermediate station, recover from missed origins without inventing an official arrival.
                // This is a local prediction offset, never a reported railway delay.
                guard candidate.stops.first?.stationID != station.id, abs(difference) <= 180 else { return candidate }
                var anchored = candidate; anchored.observationOffset = difference
                return anchored
            }
        }
        // Course, actual track proximity, motion and schedule support each other. Automotive alone contributes no boarding decision.
        let speed = validSpeed(observation.speedMetersPerSecond)
        let hasMovement = speed >= configuration.minimumRailSpeed && inferredDirection != nil
        let alignedVisits = stationHistory.filter { $0.routeID == route.id && observation.timestamp.timeIntervalSince($0.date) < 1800 }
        let hasPassage = Set(alignedVisits.map(\.stationID)).count >= 2 && inferredDirection != nil
        let pedestrian = observation.motion == .pedestrian || observation.motion == .cycling
        pedestrianSamples = pedestrian && speed < 3 && station != nil ? pedestrianSamples + 1 : 0
        if pedestrianSamples >= 2 { ridingEvidence = false; transferTime = observation.timestamp }
        if !activeCandidates.isEmpty, best.0.distanceFromTrack <= 90, (hasMovement || hasPassage), !pedestrian {
            ridingEvidence = true; transferTime = nil
        }
        // Arrival observations are re-matched immediately, including the first observation at Ebisu or a later station.
        return advance(to: observation.timestamp)
    }

    @discardableResult
    public mutating func advance(to date: Date) -> ProgressSnapshot {
        let safeDate = max(date, lastObservation?.timestamp ?? date)
        guard let match = routeMatch, let route = timetable.route(match.routeID) else {
            if lastSnapshot.phase == .arrived {
                lastSnapshot.date = safeDate; return lastSnapshot
            }
            var empty = ProgressSnapshot.empty(at: safeDate)
            empty.latestObservationTime = lastGoodObservation?.timestamp
            empty.isSimulated = lastObservation?.simulated ?? false
            if let observation = lastObservation, observation.coordinate == nil || (observation.horizontalAccuracy ?? .infinity) > configuration.maximumHorizontalAccuracy {
                empty.notice = "GPSを取得できません。路線の観測後は予定時刻から進捗を推定します"
            }
            lastSnapshot = empty; return empty
        }
        let age = lastGoodObservation.map { safeDate.timeIntervalSince($0.timestamp) } ?? .infinity
        if age > configuration.maximumPredictionSeconds {
            activeCandidates = []; ridingEvidence = false
        }
        let stillPlausible = activeCandidates.filter {
            guard let last = $0.stops.last else { return false }
            return safeDate <= clock.date(serviceDate: $0.serviceDate, minute: last.departureMinute).addingTimeInterval($0.observationOffset + 300)
        }
        activeCandidates = stillPlausible
        let unique = uniqueCandidate(stillPlausible)
        let projections = stillPlausible.map { ($0, project($0, at: safeDate)) }
        let consensus = consensusProjection(projections)
        let projection = unique.map { project($0, at: safeDate) } ?? consensus
        let candidateDirections = Set(stillPlausible.map { $0.service.direction })
        let direction = inferredDirection ?? (candidateDirections.count == 1 ? candidateDirections.first : nil)
        let orderedIDs = direction == .reverse ? Array(route.stationIDs.reversed()) : route.stationIDs
        let currentStation = projection?.from.stationID ?? stationHistory.last(where: { $0.routeID == route.id })?.stationID
        let nextStation = projection?.to?.stationID
        var phase: TravelPhase = ridingEvidence ? .riding : .waiting
        if let transferTime, safeDate.timeIntervalSince(transferTime) < 300, !ridingEvidence { phase = .transferring }
        if projection?.isComplete == true && ridingEvidence {
            phase = projection?.from.stationID == orderedIDs.last ? .arrived : .transferring
        }
        if stillPlausible.isEmpty, lastSnapshot.phase == .arrived, lastSnapshot.direction == direction,
           age <= configuration.maximumPredictionSeconds { phase = .arrived }
        if projection?.isBeforeDeparture == true && !ridingEvidence { phase = .waiting }
        let directionEvidence = direction != nil
        let matchingVisits = stationHistory.filter { $0.routeID == route.id }
        let observedCount = Set(matchingVisits.map(\.stationID)).count
        var confidence: DataConfidence = .low
        if ridingEvidence && directionEvidence && !stillPlausible.isEmpty {
            confidence = unique != nil && observedCount >= 3 && age < 60
                && (lastGoodObservation?.horizontalAccuracy ?? .infinity) <= 50 ? .high : .medium
        }
        if age > configuration.staleObservationSeconds || unique == nil || lastObservation?.coordinate == nil
            || candidateObservationAccuracy() >= min(configuration.stationRadius, configuration.maximumHorizontalAccuracy) { confidence = .low }
        let skipped = Set(unique?.stops.filter { $0.stopKind == .pass }.map(\.stationID) ?? [])
        let displayStations = orderedIDs.compactMap { id -> StationDisplay? in
            guard let station = timetable.station(id) else { return nil }
            let omitted = unique.map { !$0.stops.contains(where: { $0.stationID == id }) } ?? false
            return StationDisplay(id: id, name: station.displayName, isSkipped: skipped.contains(id) || omitted)
        }
        let start = ridingEvidence ? projection?.start : nil
        let end = ridingEvidence ? projection?.end : nil
        let progress = ridingEvidence ? (projection?.progress ?? 0) : 0
        let fromIndex = orderedIDs.firstIndex(of: currentStation ?? "") ?? 0
        let toIndex = orderedIDs.firstIndex(of: nextStation ?? "") ?? fromIndex
        let overall = orderedIDs.count > 1 ? (Double(fromIndex) + Double(toIndex - fromIndex) * progress) / Double(orderedIDs.count - 1) : 0
        let publicCandidates = stillPlausible.prefix(8).map { candidate -> TrainCandidate in
            let state = project(candidate, at: safeDate)
            return TrainCandidate(id: candidate.service.id + "@" + clock.dateKey(candidate.serviceDate),
                                  serviceID: candidate.service.id, serviceDate: clock.dateKey(candidate.serviceDate),
                                  routeID: candidate.service.routeID, direction: candidate.service.direction,
                                  trainType: candidate.service.trainType, score: candidate.score,
                                  nextStationID: state.to?.stationID, estimatedArrival: state.end,
                                  arrivalIsEstimated: candidate.observationOffset != 0 || (state.to?.isArrivalEstimate ?? true))
        }
        var notice = "予定時刻による推定。リアルタイムの遅延情報ではありません"
        if stillPlausible.isEmpty {
            notice = clock.holidayCoverageKnown(on: clock.serviceDate(containing: safeDate))
                ? "路線付近を観測。照合できる同梱列車がなく進捗を保留中"
                : "祝日データの確認期間外です。明示された運行日の列車がないため推定を保留中"
        } else if unique == nil { notice = "列車候補が複数あります。共通する区間のみ推定表示" }
        if age > configuration.staleObservationSeconds || lastObservation?.coordinate == nil { notice += "・GPS未確認" }
        if direction == nil { notice += "・進行方向を確認中" }
        if phase == .arrived { notice = "対象区間の終点到着を推定。位置情報で確認してください" }
        if phase == .transferring && projection?.isComplete == true {
            notice = "確認できる列車区間の終端。継続運転・乗換を位置情報で確認中"
        }
        lastSnapshot = ProgressSnapshot(date: safeDate, phase: phase, routeID: route.id, routeName: route.name,
                                        routeSymbol: route.symbol, direction: direction, stations: displayStations,
                                        currentStationID: currentStation, nextStationID: nextStation,
                                        progressFromStationID: ridingEvidence ? projection?.from.stationID : nil,
                                        progressToStationID: ridingEvidence ? projection?.to?.stationID : nil,
                                        estimatedArrival: projection?.end, arrivalIsEstimated: (unique?.observationOffset ?? 0) != 0 || (projection?.to?.isArrivalEstimate ?? true),
                                        confidence: confidence, candidates: publicCandidates, chosenServiceID: unique?.service.id,
                                        trainType: unique?.service.trainType, segmentStart: start, segmentEnd: end,
                                        progress: min(1, max(0, progress)), overallProgress: min(1, max(0, overall)),
                                        isSimulated: lastObservation?.simulated ?? false,
                                        latestObservationTime: lastGoodObservation?.timestamp, notice: notice,
                                        isTimeBasedEstimate: true)
        return lastSnapshot
    }

    /// Widget station labels can move at known timetable boundaries. The bar itself uses the system timer interval.
    /// ActivityKit still needs an allowed app update for header text; these future intervals keep rail segments time-linked.
    public func projectedTimeline(until end: Date, maxEntries: Int = 64) -> [DatedSnapshot] {
        guard maxEntries > 0 else { return [] }
        var copy = self
        let start = lastSnapshot.date
        var dates: Set<Date> = [start]
        for match in activeCandidates {
            for stop in match.stops {
                for minute in [stop.displayArrivalMinute, stop.departureMinute] {
                    let date = clock.date(serviceDate: match.serviceDate, minute: minute).addingTimeInterval(match.observationOffset + 1)
                    if date > start && date <= end { dates.insert(date) }
                }
            }
        }
        let staleBoundary = lastGoodObservation?.timestamp.addingTimeInterval(configuration.staleObservationSeconds + 1)
        if let staleBoundary, staleBoundary > start, staleBoundary <= end { dates.insert(staleBoundary) }
        let expiry = lastGoodObservation?.timestamp.addingTimeInterval(configuration.maximumPredictionSeconds + 1)
        if let expiry, expiry > start, expiry <= end { dates.insert(expiry) }
        return dates.sorted().prefix(maxEntries).map { date in DatedSnapshot(date: date, snapshot: copy.advance(to: date)) }
    }

    public mutating func reset(at date: Date = Date()) {
        lastObservation = nil; lastGoodObservation = nil; routeMatch = nil; inferredDirection = nil
        stationHistory = []; activeCandidates = []; ridingEvidence = false; pedestrianSamples = 0; transferTime = nil
        lastSnapshot = .empty(at: date)
    }

    private func validSpeed(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return 0 }
        return value
    }
    private func nearestStation(_ coordinate: Coordinate, on route: RouteDefinition) -> StationDefinition? {
        let closest = route.stationIDs.compactMap { timetable.station($0) }.min {
            RailGeometry.distance(coordinate, stationCoordinate($0, on: route)) < RailGeometry.distance(coordinate, stationCoordinate($1, on: route))
        }
        guard let closest, RailGeometry.distance(coordinate, stationCoordinate(closest, on: route)) <= configuration.stationRadius else { return nil }
        return closest
    }
    private func stationCoordinate(_ station: StationDefinition, on route: RouteDefinition) -> Coordinate {
        let pair = route.segments.first(where: { $0.fromStationID == station.id })?.coordinates.first
            ?? route.segments.first(where: { $0.toStationID == station.id })?.coordinates.last
        guard let pair, pair.count == 2 else { return station.coordinate }
        return Coordinate(latitude: pair[0], longitude: pair[1])
    }
    private func direction(observation: TravelObservation, match: RailGeometry.Match,
                           previousObservation: TravelObservation?, previousMatch: RailGeometry.Match?) -> TravelDirection? {
        if let previousObservation, let previousMatch, previousMatch.routeID == match.routeID,
           observation.timestamp.timeIntervalSince(previousObservation.timestamp) <= 120 {
            let delta = match.distanceAlongRoute - previousMatch.distanceAlongRoute
            let noiseFloor = max(35, (observation.horizontalAccuracy ?? 100) + (previousObservation.horizontalAccuracy ?? 100))
            if abs(delta) > noiseFloor { return delta > 0 ? .forward : .reverse }
        }
        guard validSpeed(observation.speedMetersPerSecond) > 2, let course = observation.courseDegrees,
              course.isFinite, (0..<360).contains(course) else { return nil }
        let difference = RailGeometry.angularDifference(course, match.forwardBearing)
        if difference < 50 { return .forward }
        if difference > 130 { return .reverse }
        return nil
    }
    private func historyDirection(on route: RouteDefinition) -> TravelDirection? {
        let visits = stationHistory.filter { $0.routeID == route.id }
        guard visits.count >= 2, let previous = route.stationIDs.firstIndex(of: visits[visits.count - 2].stationID),
              let current = route.stationIDs.firstIndex(of: visits[visits.count - 1].stationID), current != previous else { return nil }
        return current > previous ? .forward : .reverse
    }

    private func safeStops(_ service: TimetableService, stationID: String?) -> [TimetableStop] {
        let stops = service.stops
        guard service.routeID == "yamanote", service.continuity != .verified,
              let osaki = stops.firstIndex(where: { $0.stationID == "osaki" }), osaki > 0, osaki < stops.count - 1 else { return stops }
        // Unverified Osaki crossings form two separate hypotheses; no train identity carries across the boundary.
        if let stationID, let stationIndex = stops.firstIndex(where: { $0.stationID == stationID }), stationIndex > osaki {
            return Array(stops[osaki...])
        }
        return Array(stops[...osaki])
    }

    private func matchServices(route: RouteDefinition, match: RailGeometry.Match,
                               observation: TravelObservation, stationID: String?) -> [ServiceMatch] {
        var results: [ServiceMatch] = []
        for service in timetable.services where service.routeID == route.id && (inferredDirection == nil || service.direction == inferredDirection) {
            let stops = safeStops(service, stationID: stationID)
            var serviceHypothesis = service
            if stops.count != service.stops.count {
                serviceHypothesis.id += "#boundary-" + (stops.first?.stationID ?? "unknown")
                serviceHypothesis.officialTrainID = nil
            }
            guard stops.filter({ $0.stopKind == .stop }).count >= 2 else { continue }
            for serviceDate in clock.possibleServiceDates(for: observation.timestamp) where clock.operates(service, on: serviceDate) {
                guard let first = stops.first, let last = stops.last else { continue }
                let start = clock.date(serviceDate: serviceDate, minute: first.departureMinute)
                let end = clock.date(serviceDate: serviceDate, minute: last.departureMinute)
                guard observation.timestamp >= start.addingTimeInterval(-600), observation.timestamp <= end.addingTimeInterval(180) else { continue }
                let existingOffset = activeCandidates.first(where: { $0.service.id == serviceHypothesis.id && $0.serviceDate == serviceDate })?.observationOffset ?? 0
                var candidate = ServiceMatch(service: serviceHypothesis, serviceDate: serviceDate, score: 0, stops: stops, observationOffset: existingOffset)
                let projected = project(candidate, at: observation.timestamp)
                guard let fromOffset = match.stationOffsets[projected.from.stationID] else { continue }
                let toOffset = projected.to.flatMap { match.stationOffsets[$0.stationID] } ?? fromOffset
                let expectedOffset = fromOffset + (toOffset - fromOffset) * projected.progress
                let distanceError = abs(expectedOffset - match.distanceAlongRoute)
                let allowedError = max(450, abs(toOffset - fromOffset) * 0.9)
                guard distanceError < allowedError else { continue }
                var score = 0.7 * max(0, 1 - distanceError / allowedError) + 0.15
                if let stationID, let stop = stops.first(where: { $0.stationID == stationID }) {
                    let timeError = abs(observation.timestamp.timeIntervalSince(clock.date(serviceDate: serviceDate, minute: stop.departureMinute)))
                    score += 0.15 * max(0, 1 - timeError / 210)
                }
                if observation.motion == .pedestrian || observation.motion == .cycling { score -= 0.18 }
                if inferredDirection != nil { score += 0.08 }
                // Automotive is deliberately not scored as proof of a train.
                guard score >= 0.40 else { continue }
                candidate.score = min(1, max(0, score)); results.append(candidate)
            }
        }
        return Array(results.sorted {
            abs($0.score - $1.score) > 0.0001 ? $0.score > $1.score : $0.service.id < $1.service.id
        }.prefix(16))
    }

    private func uniqueCandidate(_ candidates: [ServiceMatch]) -> ServiceMatch? {
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 { return first }
        let accuracy = candidateObservationAccuracy()
        // Scores rank timetable agreement, not calibrated probabilities. Coarse GPS cannot resolve train identity
        // when its uncertainty spans a station's proximity region, even if one timetable scores higher.
        guard accuracy < min(configuration.stationRadius, configuration.maximumHorizontalAccuracy) else { return nil }
        let accuracyPenalty = min(0.30, max(0, (accuracy - 50) / 600))
        let observationDate = lastGoodObservation?.timestamp ?? lastSnapshot.date
        let recentStations = Set(stationHistory.filter {
            $0.routeID == routeMatch?.routeID && observationDate.timeIntervalSince($0.date) < 1800
        }.map(\.stationID))
        let sparseHistoryPenalty = accuracy > 50 && recentStations.count < 2 ? 0.04 : 0
        let requiredMargin = configuration.ambiguityMargin + accuracyPenalty + sparseHistoryPenalty
        return first.score - candidates[1].score >= requiredMargin ? first : nil
    }
    private func candidateObservationAccuracy() -> Double {
        let value = lastObservation?.horizontalAccuracy ?? lastGoodObservation?.horizontalAccuracy
            ?? configuration.maximumHorizontalAccuracy
        return value.isFinite && value >= 0 ? value : configuration.maximumHorizontalAccuracy
    }
    private func consensusProjection(_ projections: [(ServiceMatch, Projection)]) -> Projection? {
        guard let first = projections.first, projections.allSatisfy({
            $0.0.service.direction == first.0.service.direction && $0.1.from.stationID == first.1.from.stationID && $0.1.to?.stationID == first.1.to?.stationID
        }) else { return nil }
        // A timer is safe only if all plausible trains agree closely on the same interval.
        if let start = first.1.start, let end = first.1.end {
            guard projections.allSatisfy({ abs(($0.1.start ?? start).timeIntervalSince(start)) <= 30
                && abs(($0.1.end ?? end).timeIntervalSince(end)) <= 30 }) else { return nil }
        }
        return first.1
    }
    private func project(_ candidate: ServiceMatch, at date: Date) -> Projection {
        let stops = candidate.stops.filter { $0.stopKind == .stop }
        let first = stops[0]
        let firstDeparture = clock.date(serviceDate: candidate.serviceDate, minute: first.departureMinute).addingTimeInterval(candidate.observationOffset)
        if date < firstDeparture {
            return Projection(from: first, to: stops.count > 1 ? stops[1] : nil, start: firstDeparture,
                              end: stops.count > 1 ? clock.date(serviceDate: candidate.serviceDate, minute: stops[1].displayArrivalMinute).addingTimeInterval(candidate.observationOffset) : nil,
                              progress: 0, isBeforeDeparture: true, isComplete: false)
        }
        for index in 0..<(stops.count - 1) {
            let from = stops[index], to = stops[index + 1]
            let start = clock.date(serviceDate: candidate.serviceDate, minute: from.departureMinute).addingTimeInterval(candidate.observationOffset)
            let end = clock.date(serviceDate: candidate.serviceDate, minute: to.displayArrivalMinute).addingTimeInterval(candidate.observationOffset)
            let nextDeparture = clock.date(serviceDate: candidate.serviceDate, minute: to.departureMinute).addingTimeInterval(candidate.observationOffset)
            if date < nextDeparture {
                if date >= end {
                    // During a published dwell, the train has reached `to`: the next leg starts at its departure.
                    if index + 2 < stops.count {
                        let following = stops[index + 2]
                        return Projection(from: to, to: following, start: nextDeparture,
                                          end: clock.date(serviceDate: candidate.serviceDate, minute: following.displayArrivalMinute).addingTimeInterval(candidate.observationOffset),
                                          progress: 0, isBeforeDeparture: false, isComplete: false)
                    }
                    return Projection(from: to, to: nil, start: nil, end: nil, progress: 1, isBeforeDeparture: false, isComplete: true)
                }
                let duration = end.timeIntervalSince(start)
                let fraction = duration > 0 ? date.timeIntervalSince(start) / duration : 1
                return Projection(from: from, to: to, start: start, end: end,
                                  progress: min(1, max(0, fraction)), isBeforeDeparture: false, isComplete: false)
            }
        }
        let last = stops[stops.count - 1]
        return Projection(from: last, to: nil, start: nil, end: nil, progress: 1, isBeforeDeparture: false, isComplete: true)
    }
}
