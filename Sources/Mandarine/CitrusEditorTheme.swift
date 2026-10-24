import AppKit
import CoreText
import SwiftUI

/// The chrome is decorative; every tool keeps its session, stage and native controls.
enum CitrusEditor {
    static let background = WheelCitrus.background
    static let panel = Color(red: 33 / 255, green: 23 / 255, blue: 44 / 255)
    static let surface = Color(red: 43 / 255, green: 30 / 255, blue: 56 / 255)
    static let border = Color(red: 89 / 255, green: 65 / 255, blue: 109 / 255)
    static let mint = Color(red: 137 / 255, green: 225 / 255, blue: 180 / 255)
    static let coral = Color(red: 1, green: 122 / 255, blue: 155 / 255)
    static let yellow = Color(red: 1, green: 225 / 255, blue: 103 / 255)
    static let muted = Color(red: 190 / 255, green: 165 / 255, blue: 211 / 255)
    static let resources = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Mandarine_Mandarine.bundle")) } ?? Bundle.module
    static let terrain = resources.url(forResource: "mandarin-cosmic-footer", withExtension: "png", subdirectory: "Resources").flatMap(NSImage.init(contentsOf:))
    private static let registerFont: Void = {
        if let url = resources.url(forResource: "LilitaOne-Regular", withExtension: "ttf", subdirectory: "Resources") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func heading(_ size: CGFloat) -> Font {
        _ = registerFont
        return .custom("LilitaOne", size: size)
    }
}

struct CitrusEditorHeader: View {
    @ObservedObject var session: ToolSession

    var body: some View {
        HStack(spacing: 10) {
            WheelCitrusMark().frame(width: 34, height: 34)
            Text("Mandarine").font(CitrusEditor.heading(27)).foregroundStyle(WheelCitrus.cream)
            Text(session.fileLabel).font(.callout).foregroundStyle(CitrusEditor.muted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = session.sourceSize {
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.caption.monospacedDigit()).foregroundStyle(CitrusEditor.muted)
            }
            if let player = session.trimPlayer {
                Text(TrimRange.format(player.range.duration)).font(.caption.monospacedDigit())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(CitrusEditor.surface, in: Capsule())
            }
            CitrusHeaderPlanet().frame(width: 66, height: 46)
        }
        .padding(.horizontal, 20).frame(height: 68)
        .background(CitrusEditor.background)
    }
}

private struct CitrusHeaderPlanet: View {
    var body: some View {
        Canvas { c, _ in
            c.rotate(by: .degrees(-15))
            let ring = Path(ellipseIn: CGRect(x: 0, y: 24, width: 57, height: 16))
            c.stroke(ring, with: .color(CitrusEditor.mint), lineWidth: 3)
            c.fill(Path(ellipseIn: CGRect(x: 15, y: 15, width: 30, height: 30)), with: .color(CitrusEditor.yellow))
            var front = Path()
            front.move(to: CGPoint(x: 2, y: 34))
            front.addQuadCurve(to: CGPoint(x: 56, y: 28), control: CGPoint(x: 28, y: 41))
            c.stroke(front, with: .color(CitrusEditor.muted), lineWidth: 2)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CitrusFooterArt: View {
    var body: some View {
        GeometryReader { geometry in
            if let image = CitrusEditor.terrain {
                Image(nsImage: image).resizable()
                    .frame(width: geometry.size.width, height: 164)
                    .offset(y: -74)
            }
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CitrusFooterButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(primary ? CitrusEditor.heading(16) : .system(size: 13, weight: .medium))
            .foregroundStyle(primary && enabled ? WheelCitrus.ink : WheelCitrus.cream.opacity(enabled ? 1 : 0.45))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(primary && enabled ? CitrusEditor.yellow : CitrusEditor.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary && enabled ? .clear : CitrusEditor.border))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
