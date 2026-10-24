import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Image engine: pure CGImage → CGImage transforms plus load/save helpers.
enum ImageOps {
    static let writableExts: Set<String> = ["jpg", "png", "heic", "tiff", "gif", "bmp"]

    // MARK: Loading and saving

    struct Loaded {
        let image: CGImage
        /// Metadata worth keeping (EXIF, GPS, TIFF…) without orientation or pixel dimensions.
        let properties: [CFString: Any]
    }

    /// Loads the first frame with the EXIF orientation applied to the pixels.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> Loaded {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100 * 1024 * 1024 else {
            throw ConversionError(message: "Image is too large (100 MB limit).")
        }
        if Category.normalized(url.pathExtension) == "svg" { return try loadSVG(url, maxPixel: maxPixel) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ConversionError(message: "Unable to read image: \(url.lastPathComponent)")
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0, w <= 40_000_000 / h else {
            throw ConversionError(message: "Image is too large (40 megapixel limit).")
        }
        let limit = maxPixel ?? max(w, h, 1)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConversionError(message: "Unable to read pixels from \(url.lastPathComponent)")
        }
        return Loaded(image: image, properties: cleaned(props))
    }

    /// Vector images are rendered at up to `maxPixel` (default 1024) on the longest side, keeping transparency.
    static func loadSVG(_ url: URL, maxPixel: Int?) throws -> Loaded {
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
            throw ConversionError(message: "Unable to read SVG: \(url.lastPathComponent)")
        }
        guard img.size.width.isFinite, img.size.height.isFinite else { throw ConversionError(message: "Invalid SVG dimensions.") }
        let target = Double(maxPixel ?? 1024)
        guard target > 0, target <= 6324 else { throw ConversionError(message: "SVG dimensions exceed the 40 megapixel limit.") }
        let k = target / Double(max(img.size.width, img.size.height))
        let w = max(Int((Double(img.size.width) * k).rounded()), 1), h = max(Int((Double(img.size.height) * k).rounded()), 1)
        let ctx = context(w, h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw ConversionError(message: "Unable to render SVG: \(url.lastPathComponent)") }
        return Loaded(image: image, properties: [:])
    }

    static func cleaned(_ props: [CFString: Any]) -> [CFString: Any] {
        var p = props
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation,
                    kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyHasAlpha, kCGImagePropertyFileSize] {
            p[key] = nil
        }
        for dictKey in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary] {
            if var d = p[dictKey] as? [CFString: Any] {
                d[kCGImagePropertyTIFFOrientation] = nil
                d[kCGImagePropertyExifPixelXDimension] = nil
                d[kCGImagePropertyExifPixelYDimension] = nil
                p[dictKey] = d
            }
        }
        return p
    }

    /// Extension to save into: the source's own when ImageIO can write it, PNG otherwise.
    static func outputExt(for url: URL) -> String {
        let e = Category.normalized(url.pathExtension)
        return writableExts.contains(e) ? e : "png"
    }

    static func type(for ext: String) -> UTType {
        switch ext {
        case "jpg": return .jpeg
        case "heic": return .heic
        case "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return .png
        }
    }

    static func write(_ image: CGImage, to out: URL, ext: String, quality: Double = 0.9, properties: [CFString: Any]? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type(for: ext).identifier as CFString, 1, nil) else {
            throw ConversionError(message: "Unsupported output format: .\(ext)")
        }
        var props = properties ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError(message: "Unable to write image: \(out.lastPathComponent)") }
    }

    /// Pixel size as displayed (EXIF orientation applied), read from the header only.
    static func orientedSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else {
            if Category.normalized(url.pathExtension) == "svg", let i = try? loadSVG(url, maxPixel: nil) { return CGSize(width: i.image.width, height: i.image.height) }
            return nil
        }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: Contexts

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static let ciContext = CIContext()

    // MARK: Alpha

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Formats without transparency (JPEG, BMP) would turn transparent pixels black: flatten onto white.
    static func flattenOnWhite(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        let ctx = context(image.width, image.height)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: Resize

    enum ResizeMode { case maxDimension(Int, allowUpscale: Bool), percent(Double), exact(Int, Int, keepAspect: Bool) }

    static func targetSize(_ w: Int, _ h: Int, _ mode: ResizeMode) -> (Int, Int) {
        switch mode {
        case .maxDimension(let m, let up):
            let longest = max(w, h)
            if longest <= m && !up { return (w, h) }
            let k = Double(m) / Double(longest)
            return (max(Int((Double(w) * k).rounded()), 1), max(Int((Double(h) * k).rounded()), 1))
        case .percent(let p):
            return (max(Int((Double(w) * p / 100).rounded()), 1), max(Int((Double(h) * p / 100).rounded()), 1))
        case .exact(let tw, let th, let keep):
            if !keep { return (max(tw, 1), max(th, 1)) }
            let k = min(Double(tw) / Double(w), Double(th) / Double(h))
            return (max(Int((Double(w) * k).rounded()), 1), max(Int((Double(h) * k).rounded()), 1))
        }
    }

    static func resize(_ image: CGImage, _ mode: ResizeMode) -> CGImage {
        let (tw, th) = targetSize(image.width, image.height, mode)
        if tw == image.width && th == image.height { return image }
        let ctx = context(tw, th)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }

    // MARK: Rotate / flip

    /// `quarterTurns` clockwise (0–3).
    static func rotate(_ image: CGImage, quarterTurns: Int, flipH: Bool, flipV: Bool) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        let w = image.width, h = image.height
        let (ow, oh) = turns % 2 == 1 ? (h, w) : (w, h)
        let ctx = context(ow, oh)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)            // CG rotates counter-clockwise for positive angles
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

    // MARK: Crop

    /// `rect` is normalised 0…1 from the top-left.
    static func pixelRect(_ rect: CGRect, in image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let x = max(0, min(rect.minX, 1)) * w, y = max(0, min(rect.minY, 1)) * h
        let r = CGRect(x: x, y: y, width: min(rect.width * w, w - x), height: min(rect.height * h, h - y))
        return r.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let r = pixelRect(rect, in: image)
        guard r.width >= 1, r.height >= 1, let out = image.cropping(to: r) else {
            throw ToolError.invalid("The crop area is empty.")
        }
        return out
    }

    // MARK: Redact

    enum RedactStyle: String { case black, pixelate, blur }

    static func redact(_ image: CGImage, rects: [CGRect], style: RedactStyle, strength: Double) throws -> CGImage {
        guard !rects.isEmpty else { throw ToolError.invalid("Draw at least one redaction area.") }
        let w = image.width, h = image.height
        let ctx = context(w, h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for rect in rects {
            let top = pixelRect(rect, in: image)
            guard top.width >= 1, top.height >= 1 else { continue }
            let target = CGRect(x: top.minX, y: CGFloat(h) - top.maxY, width: top.width, height: top.height)
            switch style {
            case .black:
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(target)
            case .pixelate:
                guard let region = image.cropping(to: top) else { continue }
                let block = max(Int(strength), 2)
                let tiny = context(max(Int(top.width) / block, 1), max(Int(top.height) / block, 1))
                tiny.interpolationQuality = .medium
                tiny.draw(region, in: CGRect(x: 0, y: 0, width: tiny.width, height: tiny.height))
                guard let small = tiny.makeImage() else { continue }
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.draw(small, in: target)
                ctx.restoreGState()
            case .blur:
                guard let region = image.cropping(to: top) else { continue }
                let ci = CIImage(cgImage: region)
                let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: max(strength, 1)).cropped(to: ci.extent)
                guard let out = ciContext.createCGImage(blurred, from: ci.extent) else { continue }
                ctx.draw(out, in: target)
            }
        }
        return ctx.makeImage() ?? image
    }

    // MARK: Photo editing

    static let filterChoices: [Choice] = [
        Choice(id: "none", label: "None"), Choice(id: "mono", label: "Black and white"), Choice(id: "noir", label: "Noir"),
        Choice(id: "sepia", label: "Sepia"), Choice(id: "fade", label: "Fade"), Choice(id: "chrome", label: "Chrome"),
        Choice(id: "instant", label: "Instant"),
    ]

    struct Edit {
        var brightness = 0.0      // -0.5 … 0.5
        var contrast = 1.0        // 0.5 … 1.5
        var saturation = 1.0      // 0 … 2
        var exposure = 0.0        // -2 … 2 EV
        var sharpness = 0.0       // 0 … 2
        var filter = "none"

        var isIdentity: Bool { brightness == 0 && contrast == 1 && saturation == 1 && exposure == 0 && sharpness == 0 && filter == "none" }
    }

    static func edit(_ image: CGImage, _ e: Edit) -> CGImage {
        if e.isIdentity { return image }
        var ci = CIImage(cgImage: image)
        let extent = ci.extent
        if e.exposure != 0 {
            let f = CIFilter(name: "CIExposureAdjust")!
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(e.exposure, forKey: kCIInputEVKey)
            ci = f.outputImage ?? ci
        }
        if e.brightness != 0 || e.contrast != 1 || e.saturation != 1 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(e.brightness, forKey: kCIInputBrightnessKey)
            f.setValue(e.contrast, forKey: kCIInputContrastKey)
            f.setValue(e.saturation, forKey: kCIInputSaturationKey)
            ci = f.outputImage ?? ci
        }
        if e.sharpness > 0 {
            let f = CIFilter(name: "CISharpenLuminance")!
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(e.sharpness, forKey: kCIInputSharpnessKey)
            ci = f.outputImage ?? ci
        }
        let named: [String: String] = ["mono": "CIPhotoEffectMono", "noir": "CIPhotoEffectNoir", "fade": "CIPhotoEffectFade",
                                       "chrome": "CIPhotoEffectChrome", "instant": "CIPhotoEffectInstant"]
        if e.filter == "sepia" {
            let f = CIFilter(name: "CISepiaTone")!
            f.setValue(ci, forKey: kCIInputImageKey); f.setValue(1.0, forKey: kCIInputIntensityKey)
            ci = f.outputImage ?? ci
        } else if let name = named[e.filter], let f = CIFilter(name: name) {
            f.setValue(ci, forKey: kCIInputImageKey)
            ci = f.outputImage ?? ci
        }
        return ciContext.createCGImage(ci, from: extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }

    // MARK: Background / frame

    static let aspectChoices: [Choice] = [
        Choice(id: "original", label: "Original"), Choice(id: "1:1", label: "1:1"), Choice(id: "4:3", label: "4:3"),
        Choice(id: "3:2", label: "3:2"), Choice(id: "16:9", label: "16:9"), Choice(id: "9:16", label: "9:16"),
    ]

    static func aspectValue(_ id: String) -> Double? {
        let parts = id.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : nil
    }

    struct Frame {
        var paddingPercent = 10.0
        var color = NSColor.white
        var aspect = "original"
        var cornerPercent = 0.0
        var shadow = false
    }

    static func frame(_ image: CGImage, _ f: Frame) -> CGImage {
        let w = Double(image.width), h = Double(image.height)
        let pad = max(w, h) * f.paddingPercent / 100
        var cw = w + pad * 2, ch = h + pad * 2
        if let a = aspectValue(f.aspect) {
            if cw / ch < a { cw = ch * a } else { ch = cw / a }
        }
        let ctx = context(Int(cw.rounded()), Int(ch.rounded()))
        ctx.setFillColor(f.color.usingColorSpace(.sRGB)?.cgColor ?? f.color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let rect = CGRect(x: (Double(ctx.width) - w) / 2, y: (Double(ctx.height) - h) / 2, width: w, height: h)
        ctx.interpolationQuality = .high
        if f.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.15), blur: pad * 0.35, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(w, h) * f.cornerPercent / 100, cornerHeight: min(w, h) * f.cornerPercent / 100, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if f.cornerPercent > 0 {
            let r = min(w, h) * f.cornerPercent / 100
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
        }
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        return ctx.makeImage() ?? image
    }

    // MARK: Collage

    struct Collage {
        var columns = 2
        var cell = 600
        var spacing = 12
        var color = NSColor.white
        var fill = true
    }

    static func collage(_ images: [CGImage], _ c: Collage) throws -> CGImage {
        guard !images.isEmpty else { throw ToolError.invalid("No images for the collage.") }
        let cols = max(1, min(c.columns, images.count))
        let rows = (images.count + cols - 1) / cols
        let cell = max(c.cell, 16), gap = max(c.spacing, 0)
        let W = cols * cell + (cols + 1) * gap, H = rows * cell + (rows + 1) * gap
        let ctx = context(W, H)
        ctx.setFillColor(c.color.usingColorSpace(.sRGB)?.cgColor ?? c.color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        for (i, img) in images.enumerated() {
            let col = i % cols, row = i / cols
            let x = gap + col * (cell + gap)
            let yTop = gap + row * (cell + gap)
            let box = CGRect(x: x, y: H - yTop - cell, width: cell, height: cell)
            let iw = Double(img.width), ih = Double(img.height)
            let k = c.fill ? max(Double(cell) / iw, Double(cell) / ih) : min(Double(cell) / iw, Double(cell) / ih)
            let dw = iw * k, dh = ih * k
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.draw(img, in: CGRect(x: box.midX - dw / 2, y: box.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    // MARK: PDF from images

    static let pageSizes: [Choice] = [
        Choice(id: "fit", label: "Same as image"), Choice(id: "a4", label: "A4"), Choice(id: "letter", label: "Letter"),
    ]

    static func writePDF(_ images: [CGImage], to out: URL, pageSize: String, margin: Double) throws {
        guard !images.isEmpty else { throw ToolError.invalid("No images to add to the PDF.") }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ConversionError(message: "Unable to create PDF") }
        for img in images {
            var page: CGRect
            switch pageSize {
            case "a4": page = CGRect(x: 0, y: 0, width: 595, height: 842)
            case "letter": page = CGRect(x: 0, y: 0, width: 612, height: 792)
            default: page = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            }
            let m = pageSize == "fit" ? 0 : margin
            if pageSize != "fit", img.width > img.height { page = CGRect(x: 0, y: 0, width: page.height, height: page.width) }  // landscape pages
            var mediaBox = page
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            let avail = page.insetBy(dx: m, dy: m)
            let k = min(avail.width / CGFloat(img.width), avail.height / CGFloat(img.height))
            let dw = CGFloat(img.width) * k, dh = CGFloat(img.height) * k
            ctx.draw(img, in: CGRect(x: page.midX - dw / 2, y: page.midY - dh / 2, width: dw, height: dh))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
