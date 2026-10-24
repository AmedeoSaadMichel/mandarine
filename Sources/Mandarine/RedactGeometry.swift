import AppKit
import SwiftUI

extension TimedArea {
    func path(in box: CGRect) -> Path {
        switch shape {
        case .rectangle: return Path(box)
        case .ellipse: return Path(ellipseIn: box)
        case .freehand:
            return Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: box.minX + first.x * box.width, y: box.minY + first.y * box.height))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height))
                }
                path.closeSubpath()
            }
        }
    }

    static func freehand(_ points: [CGPoint]) -> TimedArea? {
        guard points.count >= 3 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard box.width > 0.005, box.height > 0.005 else { return nil }
        return TimedArea(rect: box, shape: .freehand, points: points.map {
            CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height)
        })
    }

    func writeMask(size: (width: Int, height: Int), to url: URL) throws {
        guard let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.invalid("Unable to create the area mask.")
        }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.translateBy(x: 0, y: CGFloat(size.height)); ctx.scaleBy(x: 1, y: -1)
        let box = CGRect(x: rect.minX * CGFloat(size.width), y: rect.minY * CGFloat(size.height),
                         width: rect.width * CGFloat(size.width), height: rect.height * CGFloat(size.height))
        ctx.addPath(path(in: box).cgPath)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        guard let image = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ToolError.invalid("Unable to save the mask.")
        }
        try data.write(to: url)
    }
}

@MainActor
extension ToolSession {
    var redactVertices: [CGPoint] {
        guard let i = selectedArea, areas.indices.contains(i), areas[i].shape == .freehand else { return [] }
        let a = areas[i]
        return a.points.map { CGPoint(x: a.rect.minX + $0.x * a.rect.width, y: a.rect.minY + $0.y * a.rect.height) }
    }

    func changeRedactShape(_ shape: RedactShape) {
        redactShape = shape
        selectedRedactPoint = nil
        guard let i = selectedArea, areas.indices.contains(i) else { return }
        var list = areas
        let previous = list[i].shape
        list[i].shape = shape
        if shape == .freehand && list[i].points.count < 3 {
            list[i].points = previous == .ellipse ? (0..<24).map {
                let angle = Double($0) * 2 * Double.pi / 24
                return CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
            } : [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        }
        setAreas(list)
    }

    fileprivate func setRedactVertices(_ points: [CGPoint]) {
        guard let i = selectedArea, areas.indices.contains(i), let geometry = TimedArea.freehand(points) else { return }
        var list = areas
        list[i].rect = geometry.rect
        list[i].points = geometry.points
        setAreas(list)
    }

    func moveRedactPoint(_ index: Int, to point: CGPoint) {
        var points = redactVertices
        guard points.indices.contains(index), point.x.isFinite, point.y.isFinite else { return }
        points[index] = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        setRedactVertices(points)
        selectedRedactPoint = index
    }

    func addRedactPoint() {
        var points = redactVertices
        guard points.count >= 3, points.count < 2048 else { return }
        let i = selectedRedactPoint.flatMap { points.indices.contains($0) ? $0 : nil } ?? 0
        let next = points[(i + 1) % points.count]
        points.insert(CGPoint(x: (points[i].x + next.x) / 2, y: (points[i].y + next.y) / 2), at: i + 1)
        setRedactVertices(points)
        selectedRedactPoint = i + 1
    }

    func deleteRedactPoint() {
        var points = redactVertices
        guard points.count > 3, let i = selectedRedactPoint, points.indices.contains(i) else { return }
        points.remove(at: i)
        setRedactVertices(points)
        selectedRedactPoint = min(i, points.count - 1)
    }
}

/// Nearest closed-contour segment, measured in display pixels.
enum RedactContour {
    static func insertion(at point: CGPoint, vertices: [CGPoint], size: CGSize, tolerance: CGFloat = 9) -> (index: Int, point: CGPoint)? {
        guard vertices.count >= 3, size.width > 0, size.height > 0 else { return nil }
        var best: (Int, CGPoint, CGFloat)?
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            let dx = (b.x - a.x) * size.width, dy = (b.y - a.y) * size.height
            let length = dx * dx + dy * dy
            guard length > 0 else { continue }
            let t = min(max(((point.x - a.x) * size.width * dx + (point.y - a.y) * size.height * dy) / length, 0), 1)
            let projected = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
            let distance = hypot((point.x - projected.x) * size.width, (point.y - projected.y) * size.height)
            // A double click on an existing vertex should not create a duplicate.
            guard hypot((projected.x - a.x) * size.width, (projected.y - a.y) * size.height) > 3,
                  hypot((projected.x - b.x) * size.width, (projected.y - b.y) * size.height) > 3 else { continue }
            if distance <= tolerance && (best == nil || distance < best!.2) { best = (i + 1, projected, distance) }
        }
        return best.map { ($0.0, $0.1) }
    }
}

@MainActor
extension ToolSession {
    @discardableResult
    func insertRedactPoint(at point: CGPoint, displaySize: CGSize) -> Bool {
        var points = redactVertices
        guard points.count < 2048, let insertion = RedactContour.insertion(at: point, vertices: points, size: displaySize) else { return false }
        points.insert(insertion.point, at: insertion.index)
        setRedactVertices(points)
        selectedRedactPoint = insertion.index
        return true
    }
}
