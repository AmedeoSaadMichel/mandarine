import AppKit
import SwiftUI

extension Modifier {
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    /// Only a fresh press of one supported modifier is a wheel gesture.
    static func pressed(in event: NSEvent) -> Modifier? {
        guard event.type == .flagsChanged else { return nil }
        let key: Modifier?
        switch event.keyCode {
        case 56, 60: key = .shift
        case 55, 54: key = .command
        case 59, 62: key = .control
        case 58, 61: key = .option
        default: key = nil
        }
        guard let key else { return nil }
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        return flags == key.flag ? key : nil
    }
}

struct ModifierShortcutRow: View {
    let title: String
    @Binding var modifier: Modifier
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                ModifierRecorder(modifier: $modifier, label: title)
                    .frame(width: 205, height: 40)
            }
            if modifier == .control {
                Label("Start dragging the file first, then press ⌃ Control while holding the mouse button. Pressing Control before clicking opens the macOS context menu.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(CitrusEditor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModifierRecorder: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var modifier: Modifier
    let label: String
    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton() }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.isEnabled = isEnabled
        button.modifier = modifier
        button.shortcutLabel = label
        button.onRecord = { modifier = $0 }
        button.refresh()
    }
}

/// Records in the focused control only, so normal typing elsewhere is unaffected.
final class ShortcutRecorderButton: NSButton {
    var modifier: Modifier = .shift
    var shortcutLabel = "Wheel shortcut"
    var onRecord: ((Modifier) -> Void)?
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        target = self
        action = #selector(beginRecording)
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func beginRecording() {
        guard isEnabled, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refresh()
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        guard let pressed = Modifier.pressed(in: event) else { return }
        modifier = pressed
        isRecording = false
        refresh()
        onRecord?(pressed)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { isRecording = false; refresh(); return }
        if event.keyCode == 48 { isRecording = false; refresh(); super.keyDown(with: event); return }
        if !isRecording, event.keyCode == 49 || event.keyCode == 36 { beginRecording(); return }
        if isRecording { NSSound.beep(); return }
        super.keyDown(with: event)
    }

    func refresh() {
        title = isRecording ? "Press a modifier…" : "\(modifier.symbol)  \(modifier.label)"
        toolTip = "Click, then press Shift, Command, Control or Option. Escape cancels."
        setAccessibilityLabel(shortcutLabel)
        setAccessibilityValue(isRecording ? "Press a modifier. Escape cancels." : "\(modifier.label), \(modifier.symbol)")
        setAccessibilityHelp(toolTip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        (isRecording ? ShelfCitrus.selected : ShelfCitrus.surface).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        shape.fill()
        (isRecording || focused ? ShelfCitrus.mint : ShelfCitrus.border).setStroke()
        shape.lineWidth = focused ? 2 : 1
        shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isRecording ? 12 : 15, weight: .medium),
            .foregroundColor: (isRecording ? ShelfCitrus.mint : ShelfCitrus.cream).withAlphaComponent(isEnabled ? 1 : 0.45),
            .paragraphStyle: paragraph
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 8, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height), withAttributes: attributes)
    }
}
