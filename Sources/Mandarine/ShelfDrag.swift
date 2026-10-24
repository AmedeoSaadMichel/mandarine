import AppKit

/// A drop on a shelf is an internal transfer, not an export to another app.
protocol ShelfDragOrigin: AnyObject {
    var internalDropAccepted: (() -> Void)? { get set }
}

enum ShelfDrag {
    static func acceptInternalDrop(from source: Any?) {
        (source as? ShelfDragOrigin)?.internalDropAccepted?()
    }
}
