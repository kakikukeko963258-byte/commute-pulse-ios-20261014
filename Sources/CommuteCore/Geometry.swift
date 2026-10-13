import Foundation

/// Local map matching follows every supplied shape vertex, rather than drawing station-to-station chords.
public enum RailGeometry {
    public struct Match: Sendable, Equatable {
        public var routeID: String
        public var distanceFromTrack: Double
        public var distanceAlongRoute: Double
        public var totalDistance: Double
        public var forwardBearing: Double
        public var stationOffsets: [String: Double]
        public var fraction: Double { totalDistance > 0 ? min(1, max(0, distanceAlongRoute / totalDistance)) : 0 }
    }
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let latitude = (a.latitude + b.latitude) * .pi / 360
        let x = (a.longitude - b.longitude) * .pi / 180 * cos(latitude) * 6_371_000
        let y = (a.latitude - b.latitude) * .pi / 180 * 6_371_000
        return hypot(x, y)
    }
    public static func angularDifference(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
    public static func match(_ coordinate: Coordinate, to route: RouteDefinition) -> Match? {
        guard coordinate.isValid else { return nil }
        var offset = 0.0
        var bestDistance = Double.infinity
        var bestOffset = 0.0
        var bestBearing = 0.0
        var stationOffsets: [String: Double] = [:]
        for segment in route.segments {
            let vertices = segment.coordinates.compactMap { pair -> Coordinate? in
                guard pair.count == 2 else { return nil }
                let value = Coordinate(latitude: pair[0], longitude: pair[1])
                return value.isValid ? value : nil
            }
            guard vertices.count > 1 else { continue }
            stationOffsets[segment.fromStationID] = offset
            for index in 0..<(vertices.count - 1) {
                let a = vertices[index], b = vertices[index + 1]
                let referenceLatitude = coordinate.latitude * .pi / 180
                let ax = (a.longitude - coordinate.longitude) * .pi / 180 * cos(referenceLatitude) * 6_371_000
                let ay = (a.latitude - coordinate.latitude) * .pi / 180 * 6_371_000
                let bx = (b.longitude - coordinate.longitude) * .pi / 180 * cos(referenceLatitude) * 6_371_000
                let by = (b.latitude - coordinate.latitude) * .pi / 180 * 6_371_000
                let dx = bx - ax, dy = by - ay
                let lengthSquared = dx * dx + dy * dy
                guard lengthSquared > 0 else { continue }
                let projection = min(1, max(0, -(ax * dx + ay * dy) / lengthSquared))
                let trackDistance = hypot(ax + projection * dx, ay + projection * dy)
                let length = sqrt(lengthSquared)
                if trackDistance < bestDistance {
                    bestDistance = trackDistance
                    bestOffset = offset + projection * length
                    bestBearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                }
                offset += length
            }
            stationOffsets[segment.toStationID] = offset
        }
        guard bestDistance.isFinite, offset > 0 else { return nil }
        return Match(routeID: route.id, distanceFromTrack: bestDistance, distanceAlongRoute: bestOffset,
                     totalDistance: offset, forwardBearing: bestBearing, stationOffsets: stationOffsets)
    }
}
