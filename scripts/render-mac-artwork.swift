import AppKit
import Darwin
import ImageIO

struct ArtworkError: Error, CustomStringConvertible {
    let description: String
}

let characterNames = ["chiikawa", "hachiware", "usagi", "momonga"]
let backgroundSize = NSSize(width: 720, height: 480)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: 1
    )
}

let cream = color(0xFFF9EF)
let ink = color(0x53494A)
let pink = color(0xF8DDE4)
let blue = color(0xDCECF3)
let butter = color(0xF7E9BD)

// Artwork coordinates share Finder's top-left origin, not AppKit's bottom-left origin.
func rectangle(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat,
               canvasHeight: CGFloat = 480) -> NSRect {
    NSRect(x: x, y: canvasHeight - top - height, width: width, height: height)
}

func loadFirstFrame(name: String, root: URL) throws -> CGImage {
    let url = root.appendingPathComponent("assets/\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ArtworkError(description: "Cannot read sprite atlas: \(url.path)")
    }

    let frameBounds: CGRect
    if name == "momonga" {
        guard atlas.width == 1536, atlas.height == 1024 else {
            throw ArtworkError(description: "Momonga atlas must be 1536 × 1024: \(url.path)")
        }
        frameBounds = CGRect(x: 0, y: 0, width: atlas.width / 4, height: 400)
    } else {
        guard atlas.width >= 512, atlas.height >= 480,
              atlas.width % 8 == 0, atlas.height % 6 == 0 else {
            throw ArtworkError(description: "Sprite atlas must contain an 8 × 6 frame grid: \(url.path)")
        }
        frameBounds = CGRect(x: 0, y: 0, width: atlas.width / 8, height: atlas.height / 6)
    }
    guard let frame = atlas.cropping(to: frameBounds) else {
        throw ArtworkError(description: "Cannot crop first sprite frame: \(url.path)")
    }
    return frame
}

func bitmapContext(width: Int, height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw ArtworkError(description: "Cannot allocate \(width) × \(height) artwork bitmap")
    }
    return context
}

func bitmapRepresentation(context: CGContext, size: NSSize) throws -> NSBitmapImageRep {
    guard let image = context.makeImage() else {
        throw ArtworkError(description: "Cannot finish artwork bitmap")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = size
    return bitmap
}

func text(_ content: String, in bounds: NSRect, size: CGFloat,
          weight: NSFont.Weight = .regular, tint: NSColor = ink) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: tint,
        .paragraphStyle: paragraph
    ]
    (content as NSString).draw(in: bounds, withAttributes: attributes)
}

func drawSprite(_ image: CGImage, in bounds: NSRect, context: CGContext) {
    let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    let fitted = NSRect(
        x: (bounds.midX - width / 2).rounded(),
        y: (bounds.midY - height / 2).rounded(),
        width: width, height: height
    )
    context.saveGState()
    context.interpolationQuality = .none
    context.setShouldAntialias(false)
    context.draw(image, in: fitted)
    context.restoreGState()
}

func drawPlate(centerX: CGFloat, tint: NSColor) {
    let bounds = rectangle(centerX - 104, 174, 208, 166)
    let plate = NSBezierPath(roundedRect: bounds, xRadius: 30, yRadius: 30)
    tint.withAlphaComponent(0.48).setFill()
    plate.fill()
    ink.withAlphaComponent(0.07).setStroke()
    plate.lineWidth = 1
    plate.stroke()
}

func renderBackground(sprites: [CGImage], scale: Int) throws -> NSBitmapImageRep {
    let context = try bitmapContext(width: 720 * scale, height: 480 * scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    cream.setFill()
    NSRect(origin: .zero, size: backgroundSize).fill()

    let badgeBounds = rectangle(235, 25, 250, 23)
    let badge = NSBezierPath(roundedRect: badgeBounds, xRadius: 11.5, yRadius: 11.5)
    butter.withAlphaComponent(0.7).setFill()
    badge.fill()
    text("A LITTLE COMPANY FOR YOUR DESKTOP", in: rectangle(235, 30, 250, 15),
         size: 9, weight: .semibold)
    text("Chiikawa Pet", in: rectangle(60, 58, 600, 44), size: 33, weight: .semibold)
    text("Drag ChiikawaPet to Applications to install.",
         in: rectangle(55, 109, 610, 24), size: 16, weight: .medium)
    text("ChiikawaPet을 Applications 폴더로 드래그해 설치하세요.",
         in: rectangle(55, 136, 610, 22), size: 13, tint: ink.withAlphaComponent(0.78))

    // Finder supplies the icons and labels; the plates reserve both areas without painting duplicates.
    drawPlate(centerX: 190, tint: pink)
    drawPlate(centerX: 530, tint: blue)

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 330, y: 480 - 238))
    arrow.line(to: NSPoint(x: 389, y: 480 - 238))
    arrow.move(to: NSPoint(x: 376, y: 480 - 225))
    arrow.line(to: NSPoint(x: 389, y: 480 - 238))
    arrow.line(to: NSPoint(x: 376, y: 480 - 251))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    ink.withAlphaComponent(0.48).setStroke()
    arrow.stroke()

    for index in sprites.indices {
        let bounds = rectangle(258 + CGFloat(index) * 52, 352, 48, 50)
        drawSprite(sprites[index], in: bounds, context: context)
    }
    text("After copying, open ChiikawaPet from Applications.",
         in: rectangle(55, 419, 610, 20), size: 12, weight: .medium)
    text("복사가 끝나면 Applications 폴더에서 ChiikawaPet을 실행하세요.",
         in: rectangle(55, 441, 610, 18), size: 11, tint: ink.withAlphaComponent(0.72))

    return try bitmapRepresentation(context: context, size: backgroundSize)
}

func renderIcon(sprite: CGImage, pointSize: Int, scale: Int) throws -> NSBitmapImageRep {
    let pixels = pointSize * scale
    let context = try bitmapContext(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let drawingScale = CGFloat(pixels) / 1024
    context.scaleBy(x: drawingScale, y: drawingScale)

    let tileBounds = rectangle(80, 80, 864, 864, canvasHeight: 1024)
    let tile = NSBezierPath(roundedRect: tileBounds, xRadius: 190, yRadius: 190)
    cream.setFill()
    tile.fill()
    color(0xEADDD4).setStroke()
    tile.lineWidth = 8
    tile.stroke()

    if pointSize <= 32 {
        // Tiny Finder/menu icons need the original face pixels, rather than a miniature full body.
        let faceBounds = CGRect(x: sprite.width / 8, y: sprite.height / 5,
                                width: sprite.width * 3 / 4, height: sprite.height / 2)
        guard let face = sprite.cropping(to: faceBounds) else {
            throw ArtworkError(description: "Cannot crop Chiikawa face for small app icons")
        }
        let bounds = rectangle(152, 212, 720, 600, canvasHeight: 1024)
        drawSprite(face, in: bounds, context: context)
    } else {
        let bounds = rectangle(128, -48, 768, 960, canvasHeight: 1024)
        drawSprite(sprite, in: bounds, context: context)
    }
    let logicalSize = NSSize(width: pointSize, height: pointSize)
    return try bitmapRepresentation(context: context, size: logicalSize)
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw ArtworkError(description: "Cannot encode PNG: \(url.path)")
    }
    try data.write(to: url, options: .atomic)
}

func main() throws {
    guard CommandLine.arguments.count == 3 else {
        throw ArtworkError(description: "Usage: swift scripts/render-mac-artwork.swift <repo-root> <output-dir>")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    var sprites: [CGImage] = []
    for name in characterNames {
        let frame = try loadFirstFrame(name: name, root: root)
        sprites.append(frame)
    }

    let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for pointSize in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let icon = try renderIcon(sprite: sprites[0], pointSize: pointSize, scale: scale)
            let suffix = scale == 2 ? "@2x" : ""
            let url = iconset.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png")
            try writePNG(icon, to: url)
        }
    }

    let standard = try renderBackground(sprites: sprites, scale: 1)
    let retina = try renderBackground(sprites: sprites, scale: 2)
    guard let tiff = NSBitmapImageRep.representationOfImageReps(
        in: [standard, retina], using: .tiff, properties: [:]
    ) else {
        throw ArtworkError(description: "Cannot encode multi-resolution DMG background TIFF")
    }
    let tiffURL = output.appendingPathComponent("dmg-background.tiff")
    try tiff.write(to: tiffURL, options: .atomic)
    let previewURL = output.appendingPathComponent("dmg-background.png")
    try writePNG(standard, to: previewURL)
}

do {
    try main()
} catch {
    let message = Data("render-mac-artwork: \(error)\n".utf8)
    FileHandle.standardError.write(message)
    exit(EXIT_FAILURE)
}
