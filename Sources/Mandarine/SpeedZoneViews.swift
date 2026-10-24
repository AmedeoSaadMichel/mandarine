import SwiftUI

struct SpeedZonesCard: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        SidebarCard(title: "Zones (\(session.speedZones.count))") {
            ForEach(Array(session.speedZones.enumerated()), id: \.element.id) { index, zone in
                HStack(spacing: 8) {
                    Button { session.selectSpeedZone(zone.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Zone \(index + 1) · \(SpeedMath.label(zone.factor))").font(.callout.bold())
                            Text("\(TrimRange.format(zone.start)) – \(TrimRange.format(zone.end))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(session.selectedSpeedZone == zone.id ? CitrusEditor.mint.opacity(0.14) : CitrusEditor.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(session.selectedSpeedZone == zone.id ? CitrusEditor.mint : .clear))
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(session.selectedSpeedZone == zone.id ? .isSelected : [])
                    Button { session.removeSpeedZone(zone.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete zone \(index + 1)")
                        .accessibilityLabel("Delete zone \(index + 1)")
                }
            }
            Button { session.addSpeedZone() } label: { Label("Add zone", systemImage: "plus") }
                .disabled(!player.ready || session.speedZones.count >= SpeedPlan.maxZones)
                .help("Adds a free zone or splits the selected zone at the playhead or midpoint")
            if let zone = session.currentSpeedZone {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 8) {
                        TimeField(title: "Start", value: zone.start) { text in
                            guard let time = Tools.parseTime(text) else { return false }
                            return session.updateSpeedZone(zone.id, start: time)
                        }
                        Button("Here") { session.updateSpeedZone(zone.id, start: player.playhead) }
                            .help("Set start to the current position")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TimeField(title: "End", value: zone.end) { text in
                            guard let time = Tools.parseTime(text) else { return false }
                            return session.updateSpeedZone(zone.id, end: time)
                        }
                        Button("Here") { session.updateSpeedZone(zone.id, end: player.playhead) }
                            .help("Set end to the current position")
                    }
                    Text("Drag the timeline handles to adjust this zone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .id(zone.id)
            } else {
                Text("Add or select a zone, then choose its timing and speed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.speedZonesError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Distinct, non-overlapping native buttons mark the intervals on the original time scale.
struct SpeedZoneOverview: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        GeometryReader { geo in
            let duration = max(player.range.duration, 0.001)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.12))
                ForEach(Array(session.speedZones.enumerated()), id: \.element.id) { index, zone in
                    Button { session.selectSpeedZone(zone.id) } label: {
                        Text(SpeedMath.label(zone.factor)).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: max(CGFloat((zone.end - zone.start) / duration) * geo.size.width - 2, 1), height: 28)
                            .background(session.selectedSpeedZone == zone.id ? CitrusEditor.mint : CitrusEditor.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(session.selectedSpeedZone == zone.id ? WheelCitrus.ink : WheelCitrus.cream)
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zone \(index + 1), \(TrimRange.format(zone.start)) – \(TrimRange.format(zone.end)), \(SpeedMath.label(zone.factor))")
                    .help("Select zone \(index + 1)")
                    .offset(x: CGFloat(zone.start / duration) * geo.size.width)
                }
            }
        }
        .frame(height: 28)
        .disabled(!player.ready)
    }
}
