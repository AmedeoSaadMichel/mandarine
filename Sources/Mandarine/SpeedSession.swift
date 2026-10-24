import Foundation

@MainActor
extension ToolSession {
    var speedUsesZones: Bool { values.bool("useZones") }
    var speedZones: [SpeedZone] { values.speedZones() }
    var currentSpeedZone: SpeedZone? { speedZones.first { $0.id == selectedSpeedZone } }
    var speedFactor: Double { speedUsesZones ? (currentSpeedZone?.factor ?? 1) : values.number("speed", default: 1) }

    var speedZonesError: String? {
        guard let p = trimPlayer, p.ready else { return nil }
        do { _ = try SpeedPlan.segments(duration: p.range.duration, zones: speedZones); return nil }
        catch { return error.localizedDescription }
    }

    var speedOutputDuration: Double {
        let duration = trimPlayer?.range.duration ?? 0
        if !speedUsesZones { return SpeedMath.newLength(duration: duration, factor: speedFactor) }
        return (try? SpeedPlan.segments(duration: duration, zones: speedZones).reduce(0) { $0 + $1.outputDuration }) ?? duration
    }

    func initializeSpeedTimeline() {
        guard let p = trimPlayer, p.ready, speedZones.isEmpty else { return }
        let zone = SpeedZone(start: 0, end: p.range.duration, factor: values.number("speed", default: 1))
        values["useZones"] = .bool(true)
        values["speedZones"] = .speedZones([zone])
        selectSpeedZone(zone.id)
        valuesChanged()
    }

    func setSpeedZonesEnabled(_ enabled: Bool) {
        values["useZones"] = .bool(enabled)
        selectSpeedZone(enabled ? speedZones.first?.id : nil)
        valuesChanged()
    }

    func selectSpeedZone(_ id: UUID?) {
        selectedSpeedZone = speedZones.contains { $0.id == id } ? id : nil
        syncSpeedRange()
    }

    private func syncSpeedRange() {
        guard let p = trimPlayer else { return }
        syncingSpeedRange = true
        defer { syncingSpeedRange = false }
        p.resetSelection()
        if speedUsesZones, let zone = currentSpeedZone {
            p.setStart(zone.start); p.setEnd(zone.end)
        }
    }

    func addSpeedZone() {
        guard let p = trimPlayer, p.ready else { return }
        guard speedZones.count < SpeedPlan.maxZones else { errorMessage = "You can create at most \(SpeedPlan.maxZones) zones."; return }
        let duration = p.range.duration
        var gaps: [(Double, Double)] = [], cursor = 0.0
        for zone in speedZones.sorted(by: { $0.start < $1.start }) {
            if zone.start - cursor >= TrimRange.minLength { gaps.append((cursor, zone.start)) }
            cursor = zone.end
        }
        if duration - cursor >= TrimRange.minLength { gaps.append((cursor, duration)) }
        guard let gap = gaps.first(where: { p.playhead >= $0.0 && p.playhead < $0.1 })
                ?? gaps.first(where: { $0.0 >= p.playhead }) ?? gaps.first else {
            // With a full timeline, subdivide the selected interval to make room.
            guard let selected = currentSpeedZone,
                  selected.end - selected.start >= 2 * TrimRange.minLength else {
                errorMessage = "The selected zone is too short to split."; return
            }
            let cut = p.playhead >= selected.start + TrimRange.minLength && p.playhead <= selected.end - TrimRange.minLength
                ? p.playhead : (selected.start + selected.end) / 2
            var zones = speedZones
            guard let index = zones.firstIndex(where: { $0.id == selected.id }) else { return }
            zones[index].end = cut
            let zone = SpeedZone(start: cut, end: selected.end, factor: selected.factor)
            zones.insert(zone, at: index + 1)
            values["speedZones"] = .speedZones(zones)
            selectedSpeedZone = zone.id
            syncSpeedRange(); valuesChanged()
            return
        }
        let start = p.playhead >= gap.0 && gap.1 - p.playhead >= TrimRange.minLength ? p.playhead : gap.0
        let zone = SpeedZone(start: start, end: min(start + max(duration / 4, 1), gap.1), factor: 1)
        values["speedZones"] = .speedZones(speedZones + [zone])
        selectedSpeedZone = zone.id
        syncSpeedRange(); valuesChanged()
    }

    @discardableResult
    func updateSpeedZone(_ id: UUID, start: Double? = nil, end: Double? = nil, factor: Double? = nil, sync: Bool = true) -> Bool {
        var zones = speedZones
        guard let i = zones.firstIndex(where: { $0.id == id }), let p = trimPlayer else { return false }
        if let start { zones[i].start = start }
        if let end { zones[i].end = end }
        if let factor { zones[i].factor = factor }
        do { _ = try SpeedPlan.segments(duration: p.range.duration, zones: zones) }
        catch { errorMessage = error.localizedDescription; return false }
        values["speedZones"] = .speedZones(zones)
        if sync { syncSpeedRange() }
        valuesChanged()
        return true
    }

    func removeSpeedZone(_ id: UUID) {
        values["speedZones"] = .speedZones(speedZones.filter { $0.id != id })
        if selectedSpeedZone == id { selectSpeedZone(speedZones.first?.id) }
        valuesChanged()
    }

    func speedRangeChanged(_ range: TrimRange) {
        guard speedUsesZones, !syncingSpeedRange, let id = selectedSpeedZone else { return }
        if !updateSpeedZone(id, start: range.start, end: range.end, sync: false) { syncSpeedRange() }
    }

    func setSpeedFactor(_ factor: Double) {
        let v = (SpeedMath.clamp(factor) / 0.05).rounded() * 0.05
        if speedUsesZones, let id = selectedSpeedZone { updateSpeedZone(id, factor: v) }
        else { values["speed"] = .number(v); valuesChanged() }
    }
}
