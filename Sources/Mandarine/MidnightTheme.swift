import SwiftUI

/// Shared Midnight v2 tokens. Kept local to the wheel and Redact during the rollout.
enum Midnight {
    static let background = Color(red: 0.067, green: 0.055, blue: 0.106)
    static let panel = Color(red: 0.129, green: 0.106, blue: 0.176)
    static let segment = Color(red: 0.208, green: 0.153, blue: 0.243)
    static let border = Color(red: 0.39, green: 0.28, blue: 0.39)
    static let orange = Color(red: 1, green: 0.678, blue: 0.4)
    static let cream = Color(red: 0.941, green: 0.898, blue: 0.847)
    static let ink = Color(red: 0.22, green: 0.133, blue: 0.224)
    static let muted = Color(red: 0.69, green: 0.59, blue: 0.74)
    static let leaf = Color(red: 0.722, green: 0.851, blue: 0.729)
}

/// Original vector mark: no raster assets or external fonts needed at runtime.
struct MandarineMark: View {
    var body: some View {
        Canvas { context, size in
            let k = min(size.width / 60, size.height / 60)
            context.scaleBy(x: k, y: k)
            context.fill(Path(ellipseIn: CGRect(x: 8, y: 19, width: 44, height: 36)), with: .color(Midnight.orange))
            var leaf = Path()
            leaf.move(to: CGPoint(x: 29, y: 21))
            leaf.addQuadCurve(to: CGPoint(x: 52, y: 10), control: CGPoint(x: 32, y: 3))
            leaf.addQuadCurve(to: CGPoint(x: 29, y: 21), control: CGPoint(x: 48, y: 25))
            context.fill(leaf, with: .color(Midnight.leaf))
            var face = Path()
            for x: CGFloat in [18, 34] {
                face.move(to: CGPoint(x: x, y: 35))
                face.addQuadCurve(to: CGPoint(x: x + 8, y: 35), control: CGPoint(x: x + 4, y: 41))
            }
            face.move(to: CGPoint(x: 27, y: 45))
            face.addQuadCurve(to: CGPoint(x: 34, y: 45), control: CGPoint(x: 30.5, y: 49))
            context.stroke(face, with: .color(Midnight.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Decorative only: input stays on the original, separate 64-point cells.
struct WheelSector: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 7
        let inner = min(rect.width, rect.height) * 0.22
        let step = 360.0 / Double(max(count, 1))
        let gap = min(2, step * 0.08)
        let start = (Double(index) * step - 90 - step / 2 + gap / 2) * .pi / 180
        let end = (Double(index) * step - 90 + step / 2 - gap / 2) * .pi / 180
        let corner = min(6.0, Double(inner) * (end - start) * 0.12)
        let outerTrim = corner / Double(outer)
        let innerTrim = corner / Double(inner)
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle)))
        }
        var p = Path()
        p.move(to: point(outer, start + outerTrim))
        p.addArc(center: center, radius: outer, startAngle: .radians(start + outerTrim),
                 endAngle: .radians(end - outerTrim), clockwise: false)
        p.addQuadCurve(to: point(outer - corner, end), control: point(outer, end))
        p.addLine(to: point(inner + corner, end))
        p.addQuadCurve(to: point(inner, end - innerTrim), control: point(inner, end))
        p.addArc(center: center, radius: inner, startAngle: .radians(end - innerTrim),
                 endAngle: .radians(start + innerTrim), clockwise: true)
        p.addQuadCurve(to: point(inner + corner, start), control: point(inner, start))
        p.addLine(to: point(outer - corner, start))
        p.addQuadCurve(to: point(outer, start + outerTrim), control: point(outer, start))
        p.closeSubpath()
        return p
    }
}

/// Compact Citrus tokens are isolated so the editor appearance does not change.
enum WheelCitrus {
    static let background = Color(red: 25 / 255, green: 17 / 255, blue: 35 / 255)
    static let flesh = Color(red: 201 / 255, green: 130 / 255, blue: 76 / 255)
    static let selected = Color(red: 1, green: 170 / 255, blue: 85 / 255)
    static let membrane = Color(red: 233 / 255, green: 182 / 255, blue: 127 / 255)
    static let cream = Color(red: 1, green: 239 / 255, blue: 185 / 255)
    static let ink = Color(red: 52 / 255, green: 34 / 255, blue: 54 / 255)
}

/// All fruit texture is decorative; the native drop cells keep their original bounds.
struct WheelCitrusTexture: View {
    let count: Int
    let active: Int?

    var body: some View {
        Canvas { context, size in
            guard count > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 12
            let step = 2 * Double.pi / Double(count)
            for index in 0..<count {
                let angle = Double(index) * step - .pi / 2
                let half = step * 0.34
                var rim = Path()
                rim.addArc(center: center, radius: radius, startAngle: .radians(angle - half),
                           endAngle: .radians(angle + half), clockwise: false)
                context.stroke(rim, with: .color(WheelCitrus.cream.opacity(active == index ? 0.65 : 0.34)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
                for fraction in [-0.7, -0.35, 0, 0.35, 0.7] {
                    let a = angle + half * fraction
                    let r = radius - 5
                    let location = CGPoint(x: center.x + r * CGFloat(cos(a)),
                                           y: center.y + r * CGFloat(sin(a)))
                    var cell = context
                    cell.translateBy(x: location.x, y: location.y)
                    cell.rotate(by: .radians(a))
                    cell.fill(Path(ellipseIn: CGRect(x: -2.3, y: -0.8, width: 4.6, height: 1.6)),
                              with: .color(WheelCitrus.cream.opacity(active == index ? 0.45 : 0.22)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WheelCitrusMark: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 60, y: size.height / 60)
            context.fill(Path(ellipseIn: CGRect(x: 8, y: 15, width: 44, height: 40)), with: .color(WheelCitrus.selected))
            var leaf = Path()
            leaf.move(to: CGPoint(x: 30, y: 16))
            leaf.addQuadCurve(to: CGPoint(x: 49, y: 6), control: CGPoint(x: 33, y: 0))
            leaf.addQuadCurve(to: CGPoint(x: 30, y: 16), control: CGPoint(x: 46, y: 19))
            context.fill(leaf, with: .color(Color(red: 137 / 255, green: 225 / 255, blue: 180 / 255)))
            for point in [CGPoint(x: 21, y: 33), CGPoint(x: 39, y: 33), CGPoint(x: 30, y: 23)] {
                let eye = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 5, width: 8, height: 10))
                context.fill(eye, with: .color(WheelCitrus.cream))
                context.stroke(eye, with: .color(WheelCitrus.ink), lineWidth: 1)
                var pupil = Path()
                pupil.move(to: CGPoint(x: point.x, y: point.y - 2.5))
                pupil.addLine(to: CGPoint(x: point.x, y: point.y + 2.5))
                context.stroke(pupil, with: .color(WheelCitrus.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 26, y: 44))
            smile.addQuadCurve(to: CGPoint(x: 35, y: 44), control: CGPoint(x: 30.5, y: 50))
            context.stroke(smile, with: .color(WheelCitrus.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
