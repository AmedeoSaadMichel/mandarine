import AppKit

/// Decides when the wheel should appear while the user drags files.
///
/// It is driven by polling global state (mouse buttons, drag pasteboard, modifier flags), which macOS
/// exposes without any privacy permission, unlike global keyboard event monitors.
final class DragModifierDetector {
    enum Action: Equatable {
        case show(WheelKind, [URL])
        case shelf
        case hide
    }

    private let wheelFor: (Modifier) -> WheelKind?
    private var mouseWasDown = false
    private var baselineCount = 0
    private var files: [URL] = []
    private var held: Modifier?
    private enum Target { case wheel(WheelKind), shelf }
    private var armed: Target?
    private let shelfEnabled: () -> Bool
    private let shelfModifier: () -> Modifier
    private func target(for modifier: Modifier) -> Target? {
        if let wheel = wheelFor(modifier) { return .wheel(wheel) }
        return modifier == shelfModifier() && shelfEnabled() ? .shelf : nil
    }
    private var idleChangeCount: Int?
    private var consumedChangeCount: Int?

    init(shelfEnabled: @escaping () -> Bool = { false }, shelfModifier: @escaping () -> Modifier = { .option }, wheelFor: @escaping (Modifier) -> WheelKind?) {
        self.wheelFor = wheelFor
        self.shelfEnabled = shelfEnabled
        self.shelfModifier = shelfModifier
    }

    /// One poll. `readFiles` is only called when the drag pasteboard changed after the mouse went down.
    func update(mouseDown: Bool, dragChangeCount: Int, flags: NSEvent.ModifierFlags, readFiles: () -> [URL]) -> Action? {
        let pressed = Modifier.allCases.filter { flags.intersection(.deviceIndependentFlagsMask).contains($0.flag) }

        if mouseDown && !mouseWasDown {
            mouseWasDown = true
            baselineCount = max(idleChangeCount ?? dragChangeCount, consumedChangeCount ?? Int.min)
            files = []
            armed = nil
            // Remembered so that merely holding it is not seen as a new press; it still opens
            // its wheel once a file drag actually starts (see below).
            held = pressed.count == 1 ? pressed[0] : nil
            if baselineCount == dragChangeCount { return nil }
        }
        if !mouseDown {
            idleChangeCount = dragChangeCount
            defer { mouseWasDown = false; files = []; armed = nil; held = nil }
            return mouseWasDown ? .hide : nil
        }

        if files.isEmpty, dragChangeCount != baselineCount {
            baselineCount = dragChangeCount
            files = readFiles()
            consumedChangeCount = dragChangeCount
            // Holding the modifier while the drag starts counts too: "hold shift and drag".
            if !files.isEmpty, pressed.count == 1, let kind = target(for: pressed[0]) {
                armed = kind
                held = pressed[0]
            }
        }

        if pressed.count == 1 {
            if held != pressed[0] {
                held = pressed[0]
                if let kind = target(for: pressed[0]) { armed = kind }
            }
        } else {
            held = nil
        }

        // Shows as soon as there are both files being dragged and a tapped modifier,
        // whichever of the two came first.
        if let kind = armed, !files.isEmpty {
            armed = nil
            switch kind {
            case .wheel(let wheel): return .show(wheel, files)
            case .shelf: return .shelf
            }
        }
        return nil
    }
}
