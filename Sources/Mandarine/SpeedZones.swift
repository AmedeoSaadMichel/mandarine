import Foundation

/// Times refer to the original video, never to the retimed output.
struct SpeedZone: Equatable, Identifiable {
    let id: UUID
    var start: Double
    var end: Double
    var factor: Double

    init(id: UUID = UUID(), start: Double, end: Double, factor: Double) {
        self.id = id; self.start = start; self.end = end; self.factor = factor
    }
}

enum SpeedPlan {
    static let maxZones = 64
    struct Segment: Equatable {
        let start: Double
        let end: Double
        let factor: Double
        var outputDuration: Double { (end - start) / factor }
    }

    static func segments(duration: Double, zones: [SpeedZone]) throws -> [Segment] {
        guard duration.isFinite, duration > 0 else { throw ToolError.invalid("Invalid video duration.") }
        guard zones.count <= maxZones else { throw ToolError.invalid("You can create at most \(maxZones) zones.") }
        var result: [Segment] = [], cursor = 0.0
        for zone in zones.sorted(by: { $0.start < $1.start }) {
            guard zone.start.isFinite, zone.end.isFinite, zone.factor.isFinite,
                  zone.start >= 0, zone.end <= duration, zone.end - zone.start >= TrimRange.minLength - 0.000001,
                  SpeedMath.range.contains(zone.factor) else {
                throw ToolError.invalid("Each zone must be at least 0.1 seconds long, stay within the video and use a speed between 0.25× and 4×.")
            }
            guard zone.start >= cursor else { throw ToolError.invalid("Speed zones cannot overlap.") }
            if zone.start > cursor { result.append(Segment(start: cursor, end: zone.start, factor: 1)) }
            result.append(Segment(start: zone.start, end: zone.end, factor: zone.factor))
            cursor = zone.end
        }
        if cursor < duration { result.append(Segment(start: cursor, end: duration, factor: 1)) }
        return result
    }

    static func rate(at time: Double, zones: [SpeedZone]) -> Double {
        zones.first { time >= $0.start && time < $0.end }?.factor ?? 1
    }
}
