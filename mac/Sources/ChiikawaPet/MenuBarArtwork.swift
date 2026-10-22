import AppKit
import ImageIO

@MainActor
enum MenuBarArtwork {
    static let width: CGFloat = 164
    private static let height: CGFloat = 22
    private static let claudeLogo = loadLogo("claude-logo")
    private static let codexLogo = loadLogo("codex-logo")
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    static func width(for presentation: MenuBarPresentation) -> CGFloat {
        if presentation.metrics.isEmpty && !presentation.bars && !presentation.compact { return width }
        return 26 + CGFloat(presentation.displayedMetrics.count) * (presentation.compact ? 47 : 67)
    }

    static func image(for presentation: MenuBarPresentation, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: NSSize(width: width(for: presentation), height: height))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }
            guard let graphics = NSGraphicsContext.current else { return }
            graphics.imageInterpolation = .none
            let pet = PixelPetView.menuBarImage(character: presentation.character, mood: presentation.mood)
            pet.draw(in: NSRect(x: 0, y: 1, width: 20, height: 20))
            if !presentation.metrics.isEmpty || presentation.bars || presentation.compact {
                var x: CGFloat = 26
                for metric in presentation.displayedMetrics {
                    let metricWidth: CGFloat = presentation.compact ? 47 : 67
                    if !presentation.compact {
                        drawLogo(metric.provider == .claude ? claudeLogo : codexLogo,
                                 in: CGRect(x: x, y: 3, width: 16, height: 16), context: graphics.cgContext)
                    } else {
                        let abbreviation = metric.provider == .claude ? "C" : "X"
                        abbreviation.draw(at: NSPoint(x: x, y: 6), withAttributes: [.font: stackedFont, .foregroundColor: NSColor.labelColor])
                    }
                    let offset: CGFloat = presentation.compact ? 10 : 20
                    if presentation.bars, let percent = metric.percent {
                        let rectangle = NSRect(x: x + offset, y: 7, width: metricWidth - offset - 5, height: 8)
                        NSColor.labelColor.withAlphaComponent(0.2).setFill()
                        NSBezierPath(roundedRect: rectangle, xRadius: 2, yRadius: 2).fill()
                        NSColor.labelColor.setFill()
                        let filled = NSRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width * percent / 100, height: rectangle.height)
                        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
                    } else {
                        drawPercent(metric.percent, at: NSPoint(x: x + offset, y: 5), font: presentation.compact ? stackedFont : font)
                    }
                    x += metricWidth
                }
                return
            }
            drawLogo(claudeLogo, in: CGRect(x: 27, y: 1, width: 20, height: 20), context: graphics.cgContext)
            if let secondary = presentation.claudeSecondary {
                drawPercent(presentation.claudePrimary, at: NSPoint(x: 51, y: 11), font: stackedFont)
                drawPercent(secondary, at: NSPoint(x: 51, y: 0), font: stackedFont)
            } else {
                drawPercent(presentation.claudePrimary, at: NSPoint(x: 51, y: 5), font: font)
            }
            drawLogo(codexLogo, in: CGRect(x: 90, y: 1, width: 20, height: 20), context: graphics.cgContext)
            drawPercent(presentation.codex, at: NSPoint(x: 114, y: 5), font: font)
        }
        image.isTemplate = false
        return image
    }

    private static func drawPercent(_ percent: Double?, at point: NSPoint, font: NSFont) {
        let text = percent.map { "\(Int($0.rounded(.down)))%" } ?? "—"
        text.draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    private static func drawLogo(_ logo: CGImage, in rectangle: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rectangle, mask: logo)
        context.setFillColor(NSColor.labelColor.cgColor)
        context.fill(rectangle)
        context.restoreGState()
    }

    private static func loadLogo(_ name: String) -> CGImage {
        guard let url = PixelPetView.resourceBundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("Missing bundled menu bar logo: \(name)")
        }
        return logo
    }
}
