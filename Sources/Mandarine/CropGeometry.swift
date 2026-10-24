import CoreGraphics
import Foundation

/// A crop box in whole pixels, origin at the top-left.
struct PixelRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// Pure maths behind the crop fields: converts between the normalised box the picker draws and the
/// pixel values the fields show, and keeps every edit inside the image.
enum CropGeometry {
    enum Field { case x, y, width, height }

    static func pixels(_ r: CGRect, in size: CGSize) -> PixelRect {
        let w = max(Int(size.width.rounded()), 1), h = max(Int(size.height.rounded()), 1)
        let x = min(max(Int((r.minX * size.width).rounded()), 0), w - 1)
        let y = min(max(Int((r.minY * size.height).rounded()), 0), h - 1)
        let pw = min(max(Int((r.width * size.width).rounded()), 1), w - x)
        let ph = min(max(Int((r.height * size.height).rounded()), 1), h - y)
        return PixelRect(x: x, y: y, width: pw, height: ph)
    }

    static func normalized(_ p: PixelRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: CGFloat(p.x) / size.width, y: CGFloat(p.y) / size.height,
                      width: CGFloat(p.width) / size.width, height: CGFloat(p.height) / size.height)
    }

    /// Applies a typed value. Width and height resize from the top-left corner and only shift the box when needed
    /// to stay inside; with `aspect` (width / height) the other side follows. X and Y move the box.
    static func edit(_ box: PixelRect, field: Field, value: Int, size: CGSize, aspect: Double?) -> PixelRect {
        let W = max(Int(size.width.rounded()), 1), H = max(Int(size.height.rounded()), 1)
        var p = box
        switch field {
        case .x: p.x = min(max(value, 0), W - p.width)
        case .y: p.y = min(max(value, 0), H - p.height)
        case .width:
            p.width = min(max(value, 1), W)
            if let a = aspect, a > 0 { p.height = min(max(Int((Double(p.width) / a).rounded()), 1), H) }
            fit(&p, W, H, aspect: aspect, driver: .width)
        case .height:
            p.height = min(max(value, 1), H)
            if let a = aspect, a > 0 { p.width = min(max(Int((Double(p.height) * a).rounded()), 1), W) }
            fit(&p, W, H, aspect: aspect, driver: .height)
        }
        return p
    }

    /// Slides the box back inside the image; with an aspect ratio it shrinks instead of overflowing.
    private static func fit(_ p: inout PixelRect, _ W: Int, _ H: Int, aspect: Double?, driver: Field) {
        if p.x + p.width > W { p.x = max(W - p.width, 0) }
        if p.y + p.height > H { p.y = max(H - p.height, 0) }
        guard let a = aspect, a > 0 else { return }
        if p.x + p.width > W || p.y + p.height > H {
            p.width = min(p.width, W - p.x); p.height = min(p.height, H - p.y)
        }
        if driver == .width, p.y + p.height > H { p.height = H - p.y; p.width = max(Int((Double(p.height) * a).rounded()), 1) }
        if driver == .height, p.x + p.width > W { p.width = W - p.x; p.height = max(Int((Double(p.width) / a).rounded()), 1) }
    }

    static func centered(_ box: PixelRect, in size: CGSize) -> PixelRect {
        var p = box
        p.x = max((Int(size.width.rounded()) - box.width) / 2, 0)
        p.y = max((Int(size.height.rounded()) - box.height) / 2, 0)
        return p
    }

    /// H.264 needs even dimensions.
    static func even(_ v: Int) -> Int { max(v - v % 2, 2) }

    /// Output size of a video crop. `sameAsCrop` keeps the box size; otherwise the typed width and height are used
    /// (the other follows the box ratio when `keepRatio`).
    static func outputSize(crop: PixelRect, sameAsCrop: Bool, width: Int?, height: Int?, keepRatio: Bool) -> (Int, Int) {
        if sameAsCrop { return (even(crop.width), even(crop.height)) }
        let ratio = Double(crop.width) / Double(max(crop.height, 1))
        var w = width ?? crop.width, h = height ?? crop.height
        if keepRatio {
            if let width, height == nil { h = Int((Double(width) / ratio).rounded()) }
            else if let height, width == nil { w = Int((Double(height) * ratio).rounded()) }
            else if width != nil { h = Int((Double(w) / ratio).rounded()) }
        }
        return (even(max(w, 2)), even(max(h, 2)))
    }

    /// New height after typing a width (or the reverse) while the ratio is locked.
    static func linked(_ typed: Int, ratio: Double, typedIsWidth: Bool) -> Int {
        max(Int((typedIsWidth ? Double(typed) / ratio : Double(typed) * ratio).rounded()), 1)
    }
}
