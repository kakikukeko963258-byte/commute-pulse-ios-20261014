import Foundation

public enum TimetableValidationError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

extension TimetableDataset {
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw TimetableValidationError.invalid(message) }
        }
        try require(schemaVersion == 1, "Unsupported timetable schema")
        try require(TimeZone(identifier: timeZone) != nil, "Invalid timetable time zone")
        try require((0..<1440).contains(serviceDayStartMinute), "Invalid service day boundary")
        try require(Set(stations.map(\.id)).count == stations.count, "Duplicate station IDs")
        try require(Set(routes.map(\.id)).count == routes.count, "Duplicate route IDs")
        try require(Set(services.map(\.id)).count == services.count, "Duplicate service IDs")
        let stationIDs = Set(stations.map(\.id))
        for station in stations { try require(station.coordinate.isValid, "Invalid station coordinate: \(station.id)") }
        for route in routes {
            try require(route.stationIDs.count >= 2, "Route requires two stations: \(route.id)")
            try require(Set(route.stationIDs).isSubset(of: stationIDs), "Unknown route station: \(route.id)")
            try require(Set(route.stationIDs).count == route.stationIDs.count, "Duplicate route station: \(route.id)")
            for (index, segment) in route.segments.enumerated() {
                try require(index + 1 < route.stationIDs.count && segment.fromStationID == route.stationIDs[index]
                            && segment.toStationID == route.stationIDs[index + 1], "Shape segment station order: \(route.id)")
                try require(segment.coordinates.count >= 2 && segment.coordinates.allSatisfy {
                    $0.count == 2 && Coordinate(latitude: $0[0], longitude: $0[1]).isValid
                }, "Invalid shape: \(route.id)")
                try require(!segment.sourceID.isEmpty, "Shape source missing: \(route.id)")
            }
        }
        let clock = TimetableClock(dataset: self)
        for service in services {
            guard let route = route(service.routeID) else { throw TimetableValidationError.invalid("Unknown service route: \(service.id)") }
            try require(!service.dayTypes.isEmpty && !service.stops.isEmpty, "Missing service days/stops: \(service.id)")
            try require(!service.sourceIDs.isEmpty, "Service source missing: \(service.id)")
            let ordered = service.direction == .forward ? route.stationIDs : Array(route.stationIDs.reversed())
            var previousIndex = -1
            var previousDeparture = -1
            for stop in service.stops {
                guard let index = ordered.firstIndex(of: stop.stationID) else { throw TimetableValidationError.invalid("Unknown stop: \(service.id)") }
                try require(index > previousIndex, "Non-monotonic station order: \(service.id)")
                try require(stop.departureMinute >= 0 && stop.departureMinute < 2880
                            && stop.departureMinute >= previousDeparture, "Non-monotonic service time: \(service.id)")
                if let arrival = stop.arrivalMinute {
                    try require(arrival >= previousDeparture && arrival <= stop.departureMinute, "Invalid arrival: \(service.id)")
                }
                if stop.departurePublished == false {
                    try require(stop.arrivalMinute != nil, "Terminal proxy has no published arrival: \(service.id)")
                }
                previousIndex = index; previousDeparture = stop.departureMinute
            }
            for value in [service.validFrom, service.validTo].compactMap({ $0 }) + (service.includeDates ?? []) + (service.excludeDates ?? []) {
                try require(clock.parseDate(value) != nil, "Invalid service validity date: \(service.id)")
            }
            if let start = service.validFrom, let end = service.validTo {
                try require(start <= end, "Reversed service validity: \(service.id)")
            }
        }
        for value in holidays.dates { try require(clock.parseDate(value) != nil, "Invalid holiday date") }
        try require((holidays.coveredFrom == nil) == (holidays.coveredTo == nil), "Incomplete holiday coverage")
        if let start = holidays.coveredFrom, let end = holidays.coveredTo {
            try require(clock.parseDate(start) != nil && clock.parseDate(end) != nil && start <= end, "Invalid holiday coverage")
        }
    }
}

public struct TimetableClock: Sendable {
    private let timeZone: TimeZone
    private let holidays: Set<String>
    private let boundaryMinute: Int
    private let holidayCoverageFrom: String?
    private let holidayCoverageTo: String?
    public init(dataset: TimetableDataset) {
        timeZone = TimeZone(identifier: dataset.timeZone) ?? TimeZone(secondsFromGMT: 9 * 3600)!
        holidays = Set(dataset.holidays.dates); boundaryMinute = dataset.serviceDayStartMinute
        holidayCoverageFrom = dataset.holidays.coveredFrom; holidayCoverageTo = dataset.holidays.coveredTo
    }
    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }
    public func dateKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    public func parseDate(_ value: String) -> Date? {
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, value.count == 10 else { return nil }
        let components = DateComponents(timeZone: timeZone, year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components), dateKey(date) == value else { return nil }
        return date
    }
    public func serviceDate(containing date: Date) -> Date {
        let midnight = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return minute < boundaryMinute ? calendar.date(byAdding: .day, value: -1, to: midnight)! : midnight
    }
    /// Both dates are required: operators may encode post-midnight departures as 00:xx or 24:xx.
    public func possibleServiceDates(for date: Date) -> [Date] {
        let current = calendar.startOfDay(for: date)
        let previous = calendar.date(byAdding: .day, value: -1, to: current)!
        return [previous, current]
    }
    public func date(serviceDate: Date, minute: Int) -> Date {
        calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: serviceDate))!
    }
    public func holidayCoverageKnown(on serviceDate: Date) -> Bool {
        guard let start = holidayCoverageFrom, let end = holidayCoverageTo else { return false }
        let key = dateKey(serviceDate)
        return key >= start && key <= end
    }
    public func dayType(on serviceDate: Date) -> TimetableDayType? {
        guard holidayCoverageKnown(on: serviceDate) else { return nil }
        let weekday = calendar.component(.weekday, from: serviceDate)
        return weekday == 1 || weekday == 7 || holidays.contains(dateKey(serviceDate)) ? .weekendHoliday : .weekday
    }
    public func operates(_ service: TimetableService, on serviceDate: Date) -> Bool {
        let key = dateKey(serviceDate)
        if let start = service.validFrom, key < start { return false }
        if let end = service.validTo, key > end { return false }
        if service.excludeDates?.contains(key) == true { return false }
        if let operatingDates = service.includeDates, !operatingDates.isEmpty { return operatingDates.contains(key) }
        guard let type = dayType(on: serviceDate) else { return false }
        return service.dayTypes.contains(type)
    }
}
