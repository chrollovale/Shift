import SwiftUI
import AppKit
import CoreText

// MARK: - Colour

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private func adaptiveNS(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
    })
}

private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: adaptiveNS(light, dark))
}

/// Warm paper, black ink, one orange accent. Follows the system light / dark appearance.
enum Palette {
    static let deskNS = adaptiveNS(0xD8D2C4, 0x18181B)
    static let desk = Color(nsColor: deskNS)
    static let paper = adaptive(0xF7F3E9, 0x242429)
    static let paperAlt = adaptive(0xECE6D8, 0x2D2D33)
    static let zebra = adaptive(0xF0EBDE, 0x29292E)
    static let ink = adaptive(0x17171A, 0xF1ECDE)
    static let inkSoft = ink.opacity(0.55)
    static let shadow = adaptive(0x17171A, 0x000000)
    static let accent = Color(nsColor: NSColor(hex: 0xFF5A2B))
    static let onAccent = Color(nsColor: NSColor(hex: 0x17171A))
    static let folder = adaptive(0xF3BE4B, 0xD19A2F)
    static let docFill = adaptive(0xFFFFFF, 0x3B3B42)
    static let good = adaptive(0x2E9E5B, 0x45C27A)
    static let bad = adaptive(0xD63B2F, 0xE5584B)
}

// MARK: - Type

enum Fonts {
    /// Silkscreen: a pixel face that ships inside the app. Falls back to the system font if missing.
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", size: size)
    }

    /// Geneva was the classic Mac interface font. It's still installed on macOS.
    static func body(_ size: CGFloat = 12) -> Font {
        .custom("Geneva", size: size)
    }

    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, design: .monospaced)
    }
}

enum FontLoader {
    static func registerBundled() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension.lowercased() == "ttf" {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Boxes and buttons

/// A bordered panel with a hard offset shadow, like a classic Mac window.
struct RetroBox: ViewModifier {
    var radius: CGFloat = 8
    var shadow: CGFloat = 4
    var fill: Color = Palette.paper

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(fill)
            .clipShape(shape)
            .overlay(shape.stroke(Palette.ink, lineWidth: 1.5))
            .background(shape.fill(Palette.shadow).offset(x: shadow, y: shadow))
    }
}

extension View {
    func retroBox(radius: CGFloat = 8, shadow: CGFloat = 4, fill: Color = Palette.paper) -> some View {
        modifier(RetroBox(radius: radius, shadow: shadow, fill: fill))
    }

    func retroField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(Fonts.body(13))
            .foregroundColor(Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Palette.paper)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Palette.ink, lineWidth: 1.5))
    }
}

/// A chunky keycap that sinks when pressed.
struct KeyButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case primary
        case danger
    }

    var kind: Kind = .normal
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .font(Fonts.pixel(compact ? 8 : 10, bold: true))
            .foregroundColor(textColor)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(shape.fill(fillColor))
            .overlay(shape.stroke(Palette.ink, lineWidth: 1.5))
            .background(shape.fill(Palette.shadow).offset(y: pressed ? 0 : 2.5))
            .offset(y: pressed ? 2.5 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.06), value: pressed)
    }

    private var fillColor: Color {
        switch kind {
        case .normal: return Palette.paper
        case .primary: return Palette.accent
        case .danger: return Palette.bad
        }
    }

    private var textColor: Color {
        switch kind {
        case .normal: return Palette.ink
        case .primary: return Palette.onAccent
        case .danger: return .white
        }
    }
}

/// Small label-style button used for the quick-access places.
struct ChipStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return configuration.label
            .font(Fonts.pixel(8, bold: true))
            .foregroundColor(active ? Palette.paper : Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(active ? Palette.ink : (configuration.isPressed ? Palette.paperAlt : Palette.paper)))
            .overlay(shape.stroke(Palette.ink, lineWidth: 1))
    }
}

// MARK: - Title bar stripes, dither, window helpers

/// The horizontal pinstripes from a Platinum-era title bar.
struct StripeFill: View {
    var body: some View {
        Canvas { context, size in
            let lines = 6
            let gap: CGFloat = 3
            let total = CGFloat(lines - 1) * gap + 1.5
            let top = (size.height - total) / 2
            for index in 0..<lines {
                let rect = CGRect(x: 0, y: top + CGFloat(index) * gap, width: size.width, height: 1.5)
                context.fill(Path(rect), with: .color(Palette.ink))
            }
        }
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}

/// A faint checkerboard, tiled across the desktop colour.
enum Dither {
    static let image: NSImage = {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSRect(x: 0, y: 0, width: 2, height: 2).fill()
            NSRect(x: 2, y: 2, width: 2, height: 2).fill()
            return true
        }
    }()
}

struct DeskBackground: View {
    var body: some View {
        ZStack {
            Palette.desk
            Image(nsImage: Dither.image)
                .resizable(resizingMode: .tile)
        }
        .allowsHitTesting(false)
    }
}

/// Lets a region of the custom title bar drag the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Makes the window's own title bar transparent so ours shows through.
struct WindowConfigurator: NSViewRepresentable {
    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = Palette.deskNS
        }
    }

    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Progress

/// Solid fill for known progress, the classic barber pole when it isn't known.
struct RetroProgress: View {
    var fraction: Double?
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Palette.paper
                if let value = fraction {
                    Palette.accent
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                } else {
                    TimelineView(.animation) { timeline in
                        BarberPole(phase: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Palette.ink, lineWidth: 1.5))
        }
        .frame(height: height)
    }
}

private struct BarberPole: View {
    var phase: Double

    var body: some View {
        Canvas { context, size in
            let width: CGFloat = 8
            let offset = CGFloat((phase * 28).truncatingRemainder(dividingBy: Double(width * 2)))
            var x = -size.height - width * 2 + offset
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + width, y: size.height))
                path.addLine(to: CGPoint(x: x + width + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.closeSubpath()
                context.fill(path, with: .color(Palette.accent))
                x += width * 2
            }
        }
    }
}

// MARK: - Logo and arrows

/// The app mark: two arrows passing each other. Matches the Dock icon.
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let head = h * 0.19
            let style = StrokeStyle(lineWidth: h * 0.13, lineCap: .round, lineJoin: .round)
            let arrows: [(y: CGFloat, from: CGFloat, to: CGFloat, color: Color)] = [
                (0.32, 0.08, 0.80, Palette.ink),
                (0.68, 0.92, 0.20, Palette.accent)
            ]
            for arrow in arrows {
                let y = arrow.y * h
                let x0 = arrow.from * w
                let x1 = arrow.to * w
                let direction: CGFloat = x1 > x0 ? 1 : -1
                var path = Path()
                path.move(to: CGPoint(x: x0, y: y))
                path.addLine(to: CGPoint(x: x1, y: y))
                path.move(to: CGPoint(x: x1 - direction * head, y: y - head))
                path.addLine(to: CGPoint(x: x1, y: y))
                path.addLine(to: CGPoint(x: x1 - direction * head, y: y + head))
                context.stroke(path, with: .color(arrow.color), style: style)
            }
        }
    }
}

struct ArrowGlyph: Shape {
    var pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        let head = rect.height * 0.42
        let direction: CGFloat = pointsRight ? 1 : -1
        let tail = pointsRight ? rect.minX : rect.maxX
        let tip = pointsRight ? rect.maxX : rect.minX
        path.move(to: CGPoint(x: tail, y: y))
        path.addLine(to: CGPoint(x: tip, y: y))
        path.move(to: CGPoint(x: tip - direction * head, y: y - head))
        path.addLine(to: CGPoint(x: tip, y: y))
        path.addLine(to: CGPoint(x: tip - direction * head, y: y + head))
        return path
    }
}

// MARK: - Pixel art file icons

struct PixelArt: View {
    let rows: [String]
    let palette: [Character: Color]
    var cell: CGFloat = 1.5

    var body: some View {
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = palette[character] else { continue }
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(rows.first?.count ?? 0) * cell, height: CGFloat(rows.count) * cell)
    }
}

enum Pixel {
    // '#' = outline, 'o' = fill, 'x' = accent
    static let folder: [String] = [
        "..#####.........",
        ".#ooooo#........",
        "################",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "#oooooooooooooo#",
        "################"
    ]

    static let documentBase: [String] = [
        "########....",
        "#oooooo##...",
        "#oooooo#o#..",
        "#oooooo#oo#.",
        "#oooooo#####",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "#oooooooooo#",
        "############"
    ]

    // 8 x 6 marks, stamped inside the page.
    private static let imageGlyph = [
        "........",
        "..x...x.",
        ".xxx.xxx",
        "xxxxxxxx",
        "xxxxxxxx",
        "........"
    ]
    private static let musicGlyph = [
        "...xxxx.",
        "...x..x.",
        "...x..x.",
        ".xxx.xxx",
        ".xxx.xxx",
        "........"
    ]
    private static let videoGlyph = [
        "..x.....",
        "..xxx...",
        "..xxxxx.",
        "..xxx...",
        "..x.....",
        "........"
    ]
    private static let archiveGlyph = [
        "...xx...",
        "...xx...",
        "...xx...",
        "...xx...",
        "..xxxx..",
        "..xxxx.."
    ]
    private static let appGlyph = [
        ".xxxxxx.",
        ".x....x.",
        ".x.xx.x.",
        ".x.xx.x.",
        ".x....x.",
        ".xxxxxx."
    ]

    private static func stamp(_ glyph: [String]) -> [String] {
        var grid = documentBase.map { Array($0) }
        for (gy, row) in glyph.enumerated() {
            for (gx, character) in row.enumerated() where character == "x" {
                grid[7 + gy][2 + gx] = "x"
            }
        }
        return grid.map { String($0) }
    }

    private static let imageDoc = stamp(imageGlyph)
    private static let musicDoc = stamp(musicGlyph)
    private static let videoDoc = stamp(videoGlyph)
    private static let archiveDoc = stamp(archiveGlyph)
    private static let appDoc = stamp(appGlyph)

    static func rows(for entry: FileEntry) -> [String] {
        if entry.isDirectory { return folder }
        switch entry.symbolName {
        case "photo": return imageDoc
        case "music.note": return musicDoc
        case "film": return videoDoc
        case "doc.zipper": return archiveDoc
        case "shippingbox": return appDoc
        default: return documentBase
        }
    }
}

struct FileIcon: View {
    let entry: FileEntry

    var body: some View {
        let palette: [Character: Color] = [
            "#": Palette.ink,
            "o": entry.isDirectory ? Palette.folder : Palette.docFill,
            "x": Palette.accent
        ]
        PixelArt(rows: Pixel.rows(for: entry), palette: palette)
            .frame(width: 26, height: 24, alignment: .center)
    }
}
