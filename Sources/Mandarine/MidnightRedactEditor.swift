import SwiftUI

private struct MidnightSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var midnightSidebar: Bool {
        get { self[MidnightSidebarKey.self] }
        set { self[MidnightSidebarKey.self] = newValue }
    }
}

/// Midnight v2 presentation around the existing session, player, range and export actions.
struct MidnightRedactEditor: View {
    @ObservedObject var session: ToolSession
    @ObservedObject var player: TrimPlayer

    var body: some View {
        ToolShell(session: session) {
            RedactStage(session: session, player: player)
        } side: {
            RedactStyleCard(session: session)
            RedactAreasCard(session: session)
            RedactTimeCard(session: session, player: player)
        }
    }
}


struct RedactStyleCard: View {
    @ObservedObject var session: ToolSession
    private let styles = [("black", "Nero", "rectangle.fill"), ("blur", "Sfoca", "drop.halffull"), ("pixelate", "Pixel", "square.grid.3x3.fill")]

    var body: some View {
        SidebarCard(title: "Style") {
            HStack(spacing: 8) {
                ForEach(styles, id: \.0) { style in
                    let selected = session.values.string("style", default: "black") == style.0
                    Button {
                        session.values["style"] = .text(style.0)
                        session.valuesChanged()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: style.2).font(.system(size: 21))
                            Text(style.1).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(selected ? WheelCitrus.ink : WheelCitrus.cream)
                        .background(selected ? CitrusEditor.mint : CitrusEditor.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? CitrusEditor.mint : CitrusEditor.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.1)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            // Keep the existing parameter, including its range, step, and visibility rules.
            if session.values.string("style", default: "black") != "black",
               let strength = session.params.first(where: { $0.id == "strength" }) {
                ParamRow(session: session, param: strength)
            }
        }
    }
}
