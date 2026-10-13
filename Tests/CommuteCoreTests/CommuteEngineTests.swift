import XCTest
@testable import CommuteCore

final class CommuteEngineTests: XCTestCase {
    // Synthetic observations and timetables are test fixtures; they are not bundled railway data.
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let stationIDs = ["shibuya", "ebisu", "meguro", "gotanda", "osaki", "shinagawa", "takanawa_gateway", "tamachi"]

    private func dataset(duplicate: Bool = false, continuity: ContinuityEvidence = .verified,
                         reverse: Bool = false, firstMinute: Int = 480,
                         dayTypes: [TimetableDayType] = [.weekday, .weekendHoliday]) -> TimetableDataset {
        let stations = stationIDs.enumerated().map { index, id in
            StationDefinition(id: id, name: id, displayName: id == "takanawa_gateway" ? "高輪GW" : id,
                              latitude: 35.6 + Double(index) * 0.005, longitude: 139.7)
        }
        let segments = (0..<(stationIDs.count - 1)).map { index in
            RouteSegment(fromStationID: stationIDs[index], toStationID: stationIDs[index + 1],
                         coordinates: [[stations[index].latitude, 139.7], [stations[index].latitude + 0.0025, 139.7002],
                                       [stations[index + 1].latitude, 139.7]], sourceID: "test-shape")
        }
        let route = RouteDefinition(id: "yamanote", symbol: "JY", name: "山手線", stationIDs: stationIDs, segments: segments)
        let order = reverse ? Array(stationIDs.reversed()) : stationIDs
        let stops = order.enumerated().map { TimetableStop(stationID: $0.element, departureMinute: firstMinute + $0.offset * 2) }
        var services = [TimetableService(id: "test-run", routeID: route.id, direction: reverse ? .reverse : .forward,
                                         dayTypes: dayTypes, continuity: continuity, sourceIDs: ["test-official"], stops: stops)]
        if duplicate { var second = services[0]; second.id = "test-run-2"; services.append(second) }
        return TimetableDataset(stations: stations, routes: [route], services: services,
                                holidays: HolidayCalendar(dates: ["2026-10-12"], coveredFrom: "2026-01-01", coveredTo: "2026-12-31"))
    }
    private func observation(_ data: TimetableDataset, stationID: String, at date: Date,
                             speed: Double = 9, course: Double = 0, motion: MotionEvidence = .unknown) -> TravelObservation {
        TravelObservation(timestamp: date, coordinate: data.station(stationID)!.coordinate,
                          horizontalAccuracy: 8, speedMetersPerSecond: speed, courseDegrees: course,
                          motion: motion, simulated: true)
    }

    func testMissedOriginRecoversAtEbisu() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        XCTAssertEqual(state.phase, .riding)
        XCTAssertEqual(state.routeID, "yamanote")
        XCTAssertEqual(state.currentStationID, "ebisu")
        XCTAssertEqual(state.nextStationID, "meguro")
        XCTAssertEqual(state.progressFromStationID, "ebisu")
        XCTAssertNotNil(state.segmentEnd)
        XCTAssertTrue(state.isSimulated)
    }

    func testEveryObservedArrivalReevaluatesAndAnchorsProgress() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        _ = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:03:00+09:00")))
        let next = engine.ingest(observation(data, stationID: "meguro", at: instant("2026-10-14T08:05:00+09:00")))
        XCTAssertEqual(next.currentStationID, "meguro")
        XCTAssertEqual(next.nextStationID, "gotanda")
        XCTAssertEqual(next.estimatedArrival, instant("2026-10-14T08:07:00+09:00"))
        XCTAssertTrue(next.arrivalIsEstimated)
    }

    func testAutomotiveWithoutMovementDoesNotEstablishBoarding() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00"),
                                              speed: 0, motion: .automotive))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.segmentStart)
        XCTAssertNotEqual(state.confidence, .high)
    }

    func testGPSMissingUsesSameTimeIntervalAndLowersConfidence() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        let start = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        let missing = engine.ingest(TravelObservation(timestamp: instant("2026-10-14T08:03:00+09:00"), simulated: true))
        XCTAssertEqual(start.segmentStart, missing.segmentStart)
        XCTAssertEqual(start.segmentEnd, missing.segmentEnd)
        XCTAssertEqual(missing.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(missing.confidence, .low)
        XCTAssertTrue(missing.notice.contains("GPS"))
    }

    func testAmbiguousCandidatesRemainUnselected() {
        let data = dataset(duplicate: true)
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        XCTAssertEqual(state.candidates.count, 2)
        XCTAssertNil(state.chosenServiceID)
        XCTAssertEqual(state.confidence, .low)
        XCTAssertNotNil(state.segmentEnd) // Both candidates agree on this interval.
    }

    func testCoarseGPSDoesNotSelectHigherScoringTrainWithSparseHistory() {
        var data = dataset()
        var laterService = data.services[0]
        laterService.id = "one-minute-later"
        laterService.stops = laterService.stops.map { stop in
            var later = stop; later.departureMinute += 1; return later
        }
        data.services.append(laterService)
        // A point a quarter of the way along the actual first shape, outside either station's radius.
        // The first timetable fits better, but a broad GPS uncertainty cannot establish its identity.
        let coordinate = Coordinate(latitude: 35.60125, longitude: 139.7001)
        let date = instant("2026-10-14T08:00:30+09:00")
        let precise = TravelObservation(timestamp: date, coordinate: coordinate, horizontalAccuracy: 8,
                                        speedMetersPerSecond: 9, courseDegrees: 0, simulated: true)
        var preciseEngine = CommuteEngine(timetable: data)
        let preciseState = preciseEngine.ingest(precise)
        XCTAssertEqual(preciseState.candidates.count, 2)
        XCTAssertGreaterThan(preciseState.candidates[0].score - preciseState.candidates[1].score, 0.13)
        XCTAssertEqual(preciseState.chosenServiceID, "test-run")
        XCTAssertNotNil(preciseState.segmentEnd)

        var coarse = precise; coarse.horizontalAccuracy = 180
        var coarseEngine = CommuteEngine(timetable: data)
        let coarseState = coarseEngine.ingest(coarse)
        XCTAssertEqual(coarseState.candidates.count, 2)
        XCTAssertNil(coarseState.chosenServiceID)
        XCTAssertEqual(coarseState.confidence, .low)
        XCTAssertTrue(coarseState.notice.contains("列車候補が複数"))
        XCTAssertNil(coarseState.segmentStart)
        XCTAssertNil(coarseState.segmentEnd) // Their timetable intervals differ by 60 seconds, exceeding consensus tolerance.

        let singleServiceData = dataset()
        var singleServiceEngine = CommuteEngine(timetable: singleServiceData)
        var singleServiceState = ProgressSnapshot.empty(at: date)
        for (stationID, minute) in [("ebisu", "02"), ("meguro", "04"), ("gotanda", "06")] {
            var coarseStation = observation(singleServiceData, stationID: stationID,
                                             at: instant("2026-10-14T08:\(minute):00+09:00"))
            coarseStation.horizontalAccuracy = 180
            singleServiceState = singleServiceEngine.ingest(coarseStation)
        }
        XCTAssertEqual(singleServiceState.candidates.count, 1)
        XCTAssertEqual(singleServiceState.routeID, "yamanote")
        XCTAssertEqual(singleServiceState.phase, .riding)
        XCTAssertEqual(singleServiceState.confidence, .low) // Even three coarse station fixes cannot justify higher confidence.
    }

    func testReverseDirectionReversesStationsAndNextStop() {
        let data = dataset(reverse: true)
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "tamachi", at: instant("2026-10-14T08:00:00+09:00"), course: 180))
        XCTAssertEqual(state.direction, .reverse)
        XCTAssertEqual(state.stations.first?.id, "tamachi")
        XCTAssertEqual(state.stations.last?.id, "shibuya")
        XCTAssertEqual(state.nextStationID, "takanawa_gateway")
        XCTAssertEqual(state.stations[1].name, "高輪GW")
    }

    func testAfterMidnightUsesPreviousServiceDateAndHolidayType() {
        let data = dataset(firstMinute: 1441, dayTypes: [.weekendHoliday])
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-13T00:03:00+09:00")))
        XCTAssertEqual(state.candidates.first?.serviceDate, "2026-10-12")
        XCTAssertEqual(state.nextStationID, "meguro")
        XCTAssertEqual(state.estimatedArrival, instant("2026-10-13T00:05:00+09:00"))
    }

    func testDepartureFallbackIsExplicitlyEstimated() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        XCTAssertTrue(state.arrivalIsEstimated)
        XCTAssertTrue(state.candidates[0].arrivalIsEstimated)
        XCTAssertTrue(state.isTimeBasedEstimate)
    }

    func testPublishedArrivalDwellAlreadyShowsReachedStation() {
        var data = dataset()
        data.services[0].stops[1].arrivalMinute = 481
        data.services[0].stops[1].arrivalEstimated = false
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:01:00+09:00")))
        XCTAssertEqual(state.currentStationID, "ebisu")
        XCTAssertEqual(state.nextStationID, "meguro")
        XCTAssertEqual(state.segmentStart, instant("2026-10-14T08:02:00+09:00"))
        XCTAssertEqual(state.progress, 0)
    }

    func testUnverifiedOsakiCrossingCannotContinueAsSameCandidate() {
        let data = dataset(continuity: .boundary)
        var engine = CommuteEngine(timetable: data)
        _ = engine.ingest(observation(data, stationID: "gotanda", at: instant("2026-10-14T08:06:00+09:00")))
        let atOsaki = engine.advance(to: instant("2026-10-14T08:08:01+09:00"))
        XCTAssertEqual(atOsaki.phase, .transferring)
        XCTAssertEqual(atOsaki.currentStationID, "osaki")
        XCTAssertNil(atOsaki.nextStationID)
        XCTAssertNil(atOsaki.segmentEnd)
    }

    func testFutureWidgetTimelineIncludesEveryStationBoundary() {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        _ = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        let timeline = engine.projectedTimeline(until: instant("2026-10-14T08:16:00+09:00"))
        let fromStations = Set(timeline.compactMap { $0.snapshot.progressFromStationID })
        XCTAssertTrue(fromStations.isSuperset(of: ["ebisu", "meguro", "gotanda", "osaki", "shinagawa", "takanawa_gateway"]))
        XCTAssertEqual(timeline.last?.snapshot.phase, .arrived)
    }

    func testCurvedTrackShapeDoesNotUseStationChord() {
        let route = RouteDefinition(id: "curve", symbol: "X", name: "curve", stationIDs: ["a", "b"],
                                    segments: [RouteSegment(fromStationID: "a", toStationID: "b",
                                                            coordinates: [[35, 139], [35.01, 139.01], [35, 139.02]], sourceID: "test")])
        let onShape = RailGeometry.match(Coordinate(latitude: 35.01, longitude: 139.01), to: route)!
        let onChord = RailGeometry.match(Coordinate(latitude: 35, longitude: 139.01), to: route)!
        XCTAssertLessThan(onShape.distanceFromTrack, 1)
        XCTAssertGreaterThan(onChord.distanceFromTrack, 500)
    }

    func testExpressSkipsIntermediateStation() {
        let stations = [StationDefinition(id: "sangenjaya", name: "三軒茶屋", latitude: 35.6, longitude: 139.7),
                        StationDefinition(id: "ikejiri_ohashi", name: "池尻大橋", latitude: 35.605, longitude: 139.7),
                        StationDefinition(id: "shibuya", name: "渋谷", latitude: 35.61, longitude: 139.7)]
        let route = RouteDefinition(id: "denentoshi", symbol: "DT", name: "田園都市線", stationIDs: stations.map(\.id),
                                    segments: [RouteSegment(fromStationID: "sangenjaya", toStationID: "ikejiri_ohashi", coordinates: [[35.6,139.7],[35.605,139.7]], sourceID: "test"),
                                               RouteSegment(fromStationID: "ikejiri_ohashi", toStationID: "shibuya", coordinates: [[35.605,139.7],[35.61,139.7]], sourceID: "test")])
        let run = TimetableService(id: "express", routeID: route.id, direction: .forward, dayTypes: [.weekday], trainType: .express,
                                   sourceIDs: ["test"], stops: [TimetableStop(stationID: "sangenjaya", departureMinute: 480),
                                                              TimetableStop(stationID: "shibuya", departureMinute: 484)])
        var engine = CommuteEngine(timetable: TimetableDataset(stations: stations, routes: [route], services: [run],
                                                             holidays: HolidayCalendar(dates: [], coveredFrom: "2026-01-01", coveredTo: "2026-12-31")))
        let state = engine.ingest(TravelObservation(timestamp: instant("2026-10-14T08:00:00+09:00"),
                                                   coordinate: stations[0].coordinate, horizontalAccuracy: 8,
                                                   speedMetersPerSecond: 9, courseDegrees: 0, simulated: true))
        XCTAssertEqual(state.trainType, .express)
        XCTAssertTrue(state.stations[1].isSkipped)
        XCTAssertEqual(state.progressToStationID, "shibuya")
        XCTAssertEqual(state.nextStationID, "shibuya")
    }

    func testNoInitialGPSDoesNotInventRoute() {
        var engine = CommuteEngine(timetable: dataset())
        let state = engine.ingest(TravelObservation(timestamp: instant("2026-10-14T08:00:00+09:00")))
        XCTAssertNil(state.routeID)
        XCTAssertEqual(state.confidence, .unavailable)
        XCTAssertNil(state.segmentStart)
    }

    func testDateOverridesAndValidity() {
        let data = dataset(dayTypes: [.weekday])
        let clock = TimetableClock(dataset: data)
        var service = data.services[0]
        service.validFrom = "2026-10-10"; service.validTo = "2026-10-20"
        service.includeDates = ["2026-10-12"]; service.excludeDates = ["2026-10-14"]
        XCTAssertTrue(clock.operates(service, on: clock.parseDate("2026-10-12")!))
        XCTAssertFalse(clock.operates(service, on: clock.parseDate("2026-10-14")!))
        XCTAssertFalse(clock.operates(service, on: clock.parseDate("2026-10-21")!))
    }

    func testUnknownHolidayCoverageDoesNotBecomeWeekday() {
        var data = dataset()
        data.holidays.coveredTo = "2026-10-13"
        let clock = TimetableClock(dataset: data)
        let day = clock.parseDate("2026-10-14")!
        XCTAssertFalse(clock.holidayCoverageKnown(on: day))
        XCTAssertNil(clock.dayType(on: day))
        XCTAssertFalse(clock.operates(data.services[0], on: day))
        data.services[0].includeDates = ["2026-10-14"]
        XCTAssertTrue(clock.operates(data.services[0], on: day))
        var engine = CommuteEngine(timetable: datasetWithExpiredHolidayCoverage())
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertTrue(state.notice.contains("祝日データ"))
    }

    private func datasetWithExpiredHolidayCoverage() -> TimetableDataset {
        var data = dataset(); data.holidays.coveredTo = "2026-10-13"; return data
    }

    func testSnapshotCodableRoundTripPreservesTimerDates() throws {
        let data = dataset()
        var engine = CommuteEngine(timetable: data)
        let state = engine.ingest(observation(data, stationID: "ebisu", at: instant("2026-10-14T08:02:00+09:00")))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ProgressSnapshot.self, from: encoder.encode(state))
        XCTAssertEqual(state, restored)
    }
}
