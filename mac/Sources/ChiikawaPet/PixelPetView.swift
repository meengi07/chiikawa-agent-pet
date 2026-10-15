import AppKit
import ImageIO

@MainActor
class PixelPetView: NSView {
    var language = AppLanguage.current { didSet { updateAccessibility() } }
    var remainingPercent: Double? {
        didSet {
            guard remainingPercent != oldValue else { return }
            updateAccessibility()
            needsDisplay = true
        }
    }

    var character: PetCharacter = .chiikawa {
        didSet {
            guard character != oldValue else { return }
            updateAccessibility()
            needsDisplay = true
        }
    }

    var animationEnabled = true {
        didSet {
            guard animationEnabled != oldValue else { return }
            updateAnimationTimer()
        }
    }

    private var animationTimer: Timer?
    private var animationFrame = 0
    private static let spriteSize = CGSize(width: 64, height: 80)
    private static let shadow = CGColor(srgbRed: 0.39, green: 0.30, blue: 0.31, alpha: 0.12)
    private static let momongaRowEdges = [0, 400, 700, 1024]
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ChiikawaPet_ChiikawaPet.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
    static let frames: [PetCharacter: [CGImage]] = loadFrames()
    private static let menuBarImages: [PetCharacter: [NSImage]] = loadMenuBarImages()

    static func menuBarImage(character: PetCharacter, mood: PetMood) -> NSImage {
        return menuBarImages[character]![spriteRow(for: mood)]
    }

    private static func spriteRow(for mood: PetMood) -> Int {
        switch mood {
        case .delighted: 0
        case .happy: 1
        case .uneasy: 2
        case .sad: 3
        case .crying: 4
        case .unknown: 5
        }
    }

    private static func loadMenuBarImages() -> [PetCharacter: [NSImage]] {
        var icons: [PetCharacter: [NSImage]] = [:]
        for character in PetCharacter.allCases {
            let face: CGRect
            switch character {
            case .chiikawa: face = CGRect(x: 8, y: 16, width: 48, height: 40)
            case .hachiware: face = CGRect(x: 8, y: 11, width: 48, height: 45)
            case .usagi: face = CGRect(x: 8, y: 2, width: 48, height: 54)
            case .momonga: face = CGRect(x: 0, y: 0, width: 64, height: 80)
            }
            var characterIcons: [NSImage] = []
            for row in 0..<6 {
                guard let crop = frames[character]![row * 8].cropping(to: face),
                      let context = CGContext(
                        data: nil, width: 40, height: 40, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else {
                    fatalError("Unable to render menu bar sprite: \(character.rawValue)")
                }
                let scale = min(40 / face.width, 40 / face.height)
                let size = CGSize(width: face.width * scale, height: face.height * scale)
                let rectangle = CGRect(
                    x: ((40 - size.width) / 2).rounded(),
                    y: ((40 - size.height) / 2).rounded(),
                    width: size.width, height: size.height
                )
                context.setShouldAntialias(false)
                context.interpolationQuality = .none
                context.draw(crop, in: rectangle)
                guard let rendered = context.makeImage() else {
                    fatalError("Unable to cache menu bar sprite: \(character.rawValue)")
                }
                let image = NSImage(cgImage: rendered, size: NSSize(width: 20, height: 20))
                image.isTemplate = false
                characterIcons.append(image)
            }
            icons[character] = characterIcons
        }
        return icons
    }

    private static func loadFrames() -> [PetCharacter: [CGImage]] {
        var sprites: [PetCharacter: [CGImage]] = [:]
        for character in PetCharacter.allCases {
            guard let url = resourceBundle.url(forResource: character.rawValue, withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  atlas.width >= 512, atlas.height >= 480,
                  character != .momonga || (atlas.width == 1536 && atlas.height == 1024) else {
                fatalError("Missing or invalid bundled sprite: \(character.rawValue)")
            }
            var characterFrames: [CGImage] = []
            characterFrames.reserveCapacity(48)
            for row in 0..<6 {
                for column in 0..<8 {
                    // Momonga uses one open/blinking pair per mood; idle motion is drawn below.
                    let index = row * 2 + (column >= 6 ? 1 : 0)
                    let columns = character == .momonga ? 4 : 8
                    let rows = character == .momonga ? 3 : 6
                    let sourceColumn = character == .momonga ? index % 4 : column
                    let sourceRow = character == .momonga ? index / 4 : row
                    let x = sourceColumn * atlas.width / columns
                    let y = character == .momonga ? momongaRowEdges[sourceRow] : sourceRow * atlas.height / rows
                    let rectangle = CGRect(x: x, y: y,
                        width: (sourceColumn + 1) * atlas.width / columns - x,
                        height: (character == .momonga ? momongaRowEdges[sourceRow + 1]
                            : (sourceRow + 1) * atlas.height / rows) - y)
                    guard var frame = atlas.cropping(to: rectangle) else {
                        fatalError("Invalid sprite frame: \(character.rawValue)")
                    }
                    if character == .momonga {
                        // Trim transparent padding only, retaining the complete tail and outline.
                        guard let pixels = CGContext(data: nil, width: frame.width, height: frame.height,
                            bitsPerComponent: 8, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = pixels.data else {
                            fatalError("Unable to read Momonga sprite")
                        }
                        pixels.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                        let bytes = data.assumingMemoryBound(to: UInt8.self)
                        var left = frame.width, top = frame.height, right = -1, bottom = -1
                        for y in 0..<frame.height {
                            for x in 0..<frame.width where bytes[(y * frame.width + x) * 4 + 3] > 1 {
                                left = min(left, x); right = max(right, x)
                                top = min(top, y); bottom = max(bottom, y)
                            }
                        }
                        guard right >= left, bottom >= top,
                              let trimmed = frame.cropping(to: CGRect(x: left, y: top,
                                width: right - left + 1, height: bottom - top + 1)) else {
                            fatalError("Empty Momonga sprite")
                        }
                        frame = trimmed
                        guard let context = CGContext(data: nil, width: 64, height: 80, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                            fatalError("Unable to normalize Momonga sprite")
                        }
                        let scale = min(60 / CGFloat(frame.width), 76 / CGFloat(frame.height))
                        let width = CGFloat(frame.width) * scale, height = CGFloat(frame.height) * scale
                        context.interpolationQuality = .none
                        context.draw(frame, in: CGRect(x: (64 - width) / 2, y: 4,
                            width: width, height: height))
                        guard let normalized = context.makeImage() else {
                            fatalError("Unable to normalize Momonga sprite")
                        }
                        frame = normalized
                    }
                    characterFrames.append(frame)
                }
            }
            sprites[character] = characterFrames
        }
        return sprites
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationTimer()
    }

    func advanceFrame() {
        animationFrame = (animationFrame + 1) % 120
        needsDisplay = true
    }

    private func updateAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        guard window != nil, animationEnabled else { return }
        let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] timer in
            let hasView = MainActor.assumeIsolated {
                guard let self else { return false }
                self.advanceFrame()
                return true
            }
            if !hasView { timer.invalidate() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = T("클릭: 사용량 · 드래그: 이동 · 우클릭: 펫 종류")
        setAccessibilityHelp(toolTip)
        updateAccessibility()
    }

    private func updateAccessibility() {
        toolTip = T("클릭: 사용량 · 드래그: 이동 · 우클릭: 펫 종류")
        setAccessibilityHelp(toolTip)
        let mood = PetMood.forRemaining(remainingPercent)
        if let remainingPercent {
            let percent = remainingPercent.formatted(.number.precision(.fractionLength(0...1)))
            setAccessibilityLabel(T("\(character.name), 잔여량 \(percent)퍼센트. \(mood.caption)"))
        } else {
            setAccessibilityLabel(T("\(character.name), 잔여량을 아직 몰라요. \(mood.caption)"))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let graphics = NSGraphicsContext.current else { return }
        let context = graphics.cgContext
        context.clear(bounds)
        let backingScale = window?.backingScaleFactor ?? 2
        let scale = min(bounds.width / Self.spriteSize.width, bounds.height / Self.spriteSize.height)
        guard scale > 0 else { return }
        let originX = ((bounds.width - Self.spriteSize.width * scale) / 2 * backingScale).rounded() / backingScale
        let originY = ((bounds.height - Self.spriteSize.height * scale) / 2 * backingScale).rounded() / backingScale
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        context.translateBy(x: originX, y: originY)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(Self.shadow)
        context.fill(CGRect(x: 22, y: 77, width: 20, height: 1))
        context.fill(CGRect(x: 18, y: 78, width: 28, height: 1))

        let mood = PetMood.forRemaining(remainingPercent)
        let row = Self.spriteRow(for: mood)
        let column: Int
        if mood == .crying {
            column = (animationFrame / 3) % 8
        } else if animationFrame % 40 >= 38 {
            column = 6 + animationFrame % 2
        } else {
            column = animationFrame % 6
        }
        let bob = (animationFrame / 8) % 4 == 2 ? -1 : 0
        context.translateBy(x: 0, y: CGFloat(bob) + Self.spriteSize.height)
        context.scaleBy(x: 1, y: -1)
        let frame = Self.frames[character]![row * 8 + column]
        context.draw(frame, in: CGRect(origin: .zero, size: Self.spriteSize))
    }
}
