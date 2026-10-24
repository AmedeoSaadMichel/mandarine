import AppKit
import SwiftUI
import XCTest
@testable import Mandarine

final class MidnightWheelTests: XCTestCase {
    @MainActor
    func testCellHostsKeepTheOriginal64PointBounds() {
        _ = NSApplication.shared
        for selected in [false, true] {
            let host = NSHostingView(rootView: WheelCell(item: WheelItem(title: "Redact", symbol: "eye.slash", run: { _ in }),
                                                       onDrop: { _, _ in }, selected: selected))
            let size = host.fittingSize
            XCTAssertEqual(size.width, 64, accuracy: 0.5)
            XCTAssertEqual(size.height, 64, accuracy: 0.5)
        }
    }

    func testDecorativeSectorsDoNotOverlap() {
        for count in [1, 2, 3, 7, 8, 9, 12, 20] {
            let size = max(300, WheelView.panelSize(for: count))
            let bounds = CGRect(x: 0, y: 0, width: size, height: size)
            let center = CGPoint(x: size / 2, y: size / 2)
            let sectors = (0..<count).map { WheelSector(index: $0, count: count).path(in: bounds) }
            for index in 0..<count {
                let angle = Double(index) * 2 * Double.pi / Double(count) - Double.pi / 2
                // These paths are decoration only. The cell-host test covers native input bounds.
                for radius in [size * 0.22 + 3, size / 2 - WheelView.cell / 2 - 14, size / 2 - 10] {
                    let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                        y: center.y + CGFloat(sin(angle)) * radius)
                    let hits = sectors.indices.filter { sectors[$0].contains(point) }
                    XCTAssertEqual(hits, [index], "\(count) items, sector \(index), radius \(radius)")
                }
            }
        }
    }

    func testDecorativeSectorsLeaveTheCenterAndOutsideClear() {
        let bounds = CGRect(x: 0, y: 0, width: 336, height: 336)
        for count in [1, 3, 8, 12] {
            for index in 0..<count {
                let p = WheelSector(index: index, count: count).path(in: bounds)
                for point in [CGPoint(x: 168, y: 168), CGPoint(x: 180, y: 168), .zero, CGPoint(x: 335, y: 168)] {
                    XCTAssertFalse(p.contains(point), "\(count) items: \(point)")
                }
            }
        }
    }
}
