import Foundation

public enum TravelDirection: String, Codable, Sendable, CaseIterable { case forward, reverse }
public enum TravelPhase: String, Codable, Sendable { case idle, waiting, riding, transferring, arrived }
public enum DataConfidence: String, Codable, Sendable { case high, medium, low, unavailable }
public enum TrainType: String, Codable, Sendable { case local, express, semiExpress }
public enum MotionEvidence: String, Codable, Sendable { case unknown, stationary, pedestrian, cycling, automotive }
public enum TimetableDayType: String, Codable, Sendable { case weekday, weekendHoliday }
public enum StopKind: String, Codable, Sendable { case stop, pass }
public enum ContinuityEvidence: String, Codable, Sendable { case verified, boundary }

public struct Coordinate: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct TravelObservation: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var coordinate: Coordinate?
    public var horizontalAccuracy: Double?
    public var speedMetersPerSecond: Double?
    public var courseDegrees: Double?
    public var motion: MotionEvidence
    public var simulated: Bool
    public init(timestamp: Date, coordinate: Coordinate? = nil, horizontalAccuracy: Double? = nil,
                speedMetersPerSecond: Double? = nil, courseDegrees: Double? = nil,
                motion: MotionEvidence = .unknown, simulated: Bool = false) {
        self.timestamp = timestamp; self.coordinate = coordinate; self.horizontalAccuracy = horizontalAccuracy
        self.speedMetersPerSecond = speedMetersPerSecond; self.courseDegrees = courseDegrees
        self.motion = motion; self.simulated = simulated
    }
}

public struct StationDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var displayName: String
    public var latitude: Double
    public var longitude: Double
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public init(id: String, name: String, displayName: String? = nil, latitude: Double, longitude: Double) {
        self.id = id; self.name = name; self.displayName = displayName ?? name
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct RouteSegment: Codable, Sendable, Equatable {
    public var fromStationID: String
    public var toStationID: String
    /// Latitude, longitude pairs in the route's forward direction.
    public var coordinates: [[Double]]
    public var sourceID: String
    public init(fromStationID: String, toStationID: String, coordinates: [[Double]], sourceID: String) {
        self.fromStationID = fromStationID; self.toStationID = toStationID
        self.coordinates = coordinates; self.sourceID = sourceID
    }
}

public struct RouteDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var symbol: String
    public var name: String
    public var stationIDs: [String]
    public var segments: [RouteSegment]
    public init(id: String, symbol: String, name: String, stationIDs: [String], segments: [RouteSegment]) {
        self.id = id; self.symbol = symbol; self.name = name; self.stationIDs = stationIDs; self.segments = segments
    }
}

public struct TimetableStop: Codable, Sendable, Equatable {
    public var stationID: String
    public var departureMinute: Int
    public var arrivalMinute: Int?
    public var arrivalEstimated: Bool
    public var stopKind: StopKind
    /// False for a terminal's published arrival stored as the terminal time; no departure is asserted.
    public var departurePublished: Bool?
    public init(stationID: String, departureMinute: Int, arrivalMinute: Int? = nil,
                arrivalEstimated: Bool = true, stopKind: StopKind = .stop, departurePublished: Bool? = true) {
        self.stationID = stationID; self.departureMinute = departureMinute; self.arrivalMinute = arrivalMinute
        self.arrivalEstimated = arrivalEstimated; self.stopKind = stopKind
        self.departurePublished = departurePublished
    }
    public var displayArrivalMinute: Int { arrivalMinute ?? departureMinute }
    public var isArrivalEstimate: Bool { arrivalEstimated || arrivalMinute == nil }
}

public struct TimetableService: Codable, Sendable, Equatable {
    public var id: String
    public var routeID: String
    public var direction: TravelDirection
    public var dayTypes: [TimetableDayType]
    public var trainType: TrainType
    public var officialTrainID: String?
    public var continuity: ContinuityEvidence
    public var validFrom: String?
    public var validTo: String?
    /// Nonempty explicit operating dates restrict service to these dates; nil/empty uses dayTypes.
    public var includeDates: [String]?
    public var excludeDates: [String]?
    public var sourceIDs: [String]
    public var stops: [TimetableStop]
    public init(id: String, routeID: String, direction: TravelDirection, dayTypes: [TimetableDayType],
                trainType: TrainType = .local, officialTrainID: String? = nil,
                continuity: ContinuityEvidence = .boundary, validFrom: String? = nil, validTo: String? = nil,
                includeDates: [String]? = nil, excludeDates: [String]? = nil,
                sourceIDs: [String] = [], stops: [TimetableStop]) {
        self.id = id; self.routeID = routeID; self.direction = direction; self.dayTypes = dayTypes
        self.trainType = trainType; self.officialTrainID = officialTrainID; self.continuity = continuity
        self.validFrom = validFrom; self.validTo = validTo; self.includeDates = includeDates; self.excludeDates = excludeDates
        self.sourceIDs = sourceIDs; self.stops = stops
    }
}

public struct HolidayCalendar: Codable, Sendable, Equatable {
    public var dates: [String]
    public var coveredFrom: String?
    public var coveredTo: String?
    public init(dates: [String], coveredFrom: String? = nil, coveredTo: String? = nil) {
        self.dates = dates; self.coveredFrom = coveredFrom; self.coveredTo = coveredTo
    }
}

public struct TimetableDataset: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var timeZone: String
    public var serviceDayStartMinute: Int
    public var stations: [StationDefinition]
    public var routes: [RouteDefinition]
    public var services: [TimetableService]
    public var holidays: HolidayCalendar
    public init(schemaVersion: Int = 1, timeZone: String = "Asia/Tokyo", serviceDayStartMinute: Int = 180,
                stations: [StationDefinition], routes: [RouteDefinition], services: [TimetableService],
                holidays: HolidayCalendar = HolidayCalendar(dates: [])) {
        self.schemaVersion = schemaVersion; self.timeZone = timeZone; self.serviceDayStartMinute = serviceDayStartMinute
        self.stations = stations; self.routes = routes; self.services = services; self.holidays = holidays
    }
    public static func load(from data: Data) throws -> TimetableDataset {
        let dataset = try JSONDecoder().decode(TimetableDataset.self, from: data)
        try dataset.validate()
        return dataset
    }
    public func station(_ id: String?) -> StationDefinition? { stations.first { $0.id == id } }
    public func route(_ id: String?) -> RouteDefinition? { routes.first { $0.id == id } }
}

public struct StationDisplay: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isSkipped: Bool
    public init(id: String, name: String, isSkipped: Bool = false) { self.id = id; self.name = name; self.isSkipped = isSkipped }
}

public struct TrainCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var serviceID: String
    public var serviceDate: String
    public var routeID: String
    public var direction: TravelDirection
    public var trainType: TrainType
    public var score: Double
    public var nextStationID: String?
    public var estimatedArrival: Date?
    public var arrivalIsEstimated: Bool
    public init(id: String, serviceID: String, serviceDate: String, routeID: String, direction: TravelDirection, trainType: TrainType, score: Double,
                nextStationID: String?, estimatedArrival: Date?, arrivalIsEstimated: Bool) {
        self.id = id; self.serviceID = serviceID; self.serviceDate = serviceDate; self.trainType = trainType
        self.routeID = routeID; self.direction = direction
        self.score = score; self.nextStationID = nextStationID; self.estimatedArrival = estimatedArrival
        self.arrivalIsEstimated = arrivalIsEstimated
    }
}

public struct ProgressSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    public var phase: TravelPhase
    public var routeID: String?
    public var routeName: String?
    public var routeSymbol: String?
    public var direction: TravelDirection?
    public var stations: [StationDisplay]
    public var currentStationID: String?
    public var nextStationID: String?
    public var progressFromStationID: String?
    public var progressToStationID: String?
    public var estimatedArrival: Date?
    public var arrivalIsEstimated: Bool
    public var confidence: DataConfidence
    public var candidates: [TrainCandidate]
    public var chosenServiceID: String?
    public var trainType: TrainType?
    /// The system timer is applied only between progressFromStationID and progressToStationID.
    public var segmentStart: Date?
    public var segmentEnd: Date?
    public var progress: Double
    public var overallProgress: Double
    public var isSimulated: Bool
    public var latestObservationTime: Date?
    public var notice: String
    public var isTimeBasedEstimate: Bool
    public static func empty(at date: Date = Date()) -> ProgressSnapshot {
        ProgressSnapshot(date: date, phase: .idle, routeID: nil, routeName: nil, routeSymbol: nil,
                         direction: nil, stations: [], currentStationID: nil, nextStationID: nil,
                         progressFromStationID: nil, progressToStationID: nil, estimatedArrival: nil,
                         arrivalIsEstimated: true, confidence: .unavailable, candidates: [], chosenServiceID: nil,
                         trainType: nil, segmentStart: nil, segmentEnd: nil, progress: 0, overallProgress: 0,
                         isSimulated: false, latestObservationTime: nil, notice: "位置を確認すると路線を推定します", isTimeBasedEstimate: true)
    }
    public var directionLabel: String {
        guard let last = stations.last else { return "方向を確認中" }
        return "\(last.name)方面"
    }
}

public struct DatedSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    public var snapshot: ProgressSnapshot
    public init(date: Date, snapshot: ProgressSnapshot) { self.date = date; self.snapshot = snapshot }
}
