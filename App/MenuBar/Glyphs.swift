import AppKit
import SimmerCore
import SwiftUI

/// A ring that fills clockwise with the charge level. Draws in the current foreground style.
struct RingGlyph: View {
    enum Mark: Equatable {
        case none, holding, charging, discharging, paused
    }

    var fraction: Double
    var mark = Mark.none
    var diameter: CGFloat = 15
    var lineWidth: CGFloat = 2.25

    var body: some View {
        ZStack {
            Circle()
                .stroke(.foreground.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RingMarkShape(mark: mark)
                .fill(.foreground)
                .frame(width: diameter * 0.42, height: diameter * 0.42)
        }
        .frame(width: diameter, height: diameter)
        .padding(lineWidth / 2 + 0.5)
    }
}

/// The small symbol inside the ring: dot = holding, chevrons = charging / discharging, bars = paused.
private struct RingMarkShape: Shape {
    var mark: RingGlyph.Mark

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let stroke = StrokeStyle(lineWidth: max(1.3, width * 0.24), lineCap: .round, lineJoin: .round)
        switch mark {
        case .none:
            break
        case .holding:
            path.addEllipse(in: rect.insetBy(dx: width * 0.16, dy: height * 0.16))
        case .charging, .discharging:
            let up = mark == .charging
            var chevron = Path()
            chevron.move(to: CGPoint(x: rect.minX + width * 0.08, y: rect.minY + height * (up ? 0.68 : 0.32)))
            chevron.addLine(to: CGPoint(x: rect.midX, y: rect.minY + height * (up ? 0.26 : 0.74)))
            chevron.addLine(to: CGPoint(x: rect.maxX - width * 0.08, y: rect.minY + height * (up ? 0.68 : 0.32)))
            path = chevron.strokedPath(stroke)
        case .paused:
            let bar = CGSize(width: width * 0.26, height: height * 0.84)
            let top = rect.midY - bar.height / 2
            let radius = CGSize(width: bar.width / 3, height: bar.width / 3)
            path.addRoundedRect(in: CGRect(x: rect.minX + width * 0.14, y: top, width: bar.width, height: bar.height), cornerSize: radius)
            path.addRoundedRect(in: CGRect(x: rect.maxX - width * 0.14 - bar.width, y: top, width: bar.width, height: bar.height), cornerSize: radius)
        }
        return path
    }
}

/// Simmer's mark: a small cooking pot with three wisps of steam.
struct PotGlyph: View {
    var size = CGSize(width: 18, height: 16)

    var body: some View {
        ZStack {
            PotBodyShape().fill(.foreground)
            PotSteamShape()
                .stroke(.foreground, style: StrokeStyle(lineWidth: max(1, size.height * 0.07), lineCap: .round))
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct PotBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * w, y: rect.minY + y * h, width: width * w, height: height * h)
        }
        var path = Path()
        // Lid with a small knob.
        let lid = frame(0.16, 0.43, 0.68, 0.09)
        path.addRoundedRect(in: lid, cornerSize: CGSize(width: lid.height / 2, height: lid.height / 2))
        let knob = frame(0.44, 0.36, 0.12, 0.09)
        path.addRoundedRect(in: knob, cornerSize: CGSize(width: knob.height / 2, height: knob.height / 2))
        // Body: flat top, generously rounded bottom.
        let body = frame(0.21, 0.57, 0.58, 0.41)
        let radius = body.height * 0.42
        path.addPath(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0.5, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0.5
                ),
                style: .continuous
            ).path(in: body)
        )
        // Handles.
        for x in [0.06, 0.79] {
            let handle = frame(x, 0.61, 0.15, 0.1)
            path.addRoundedRect(in: handle, cornerSize: CGSize(width: handle.height / 2, height: handle.height / 2))
        }
        return path
    }
}

private struct PotSteamShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        for (x, top) in [(0.33, 0.1), (0.5, 0.03), (0.67, 0.1)] {
            let bottom = 0.28
            let middle = (top + bottom) / 2
            let sway = 0.07
            func point(_ dx: Double, _ y: Double) -> CGPoint {
                CGPoint(x: rect.minX + (x + dx) * w, y: rect.minY + y * h)
            }
            path.move(to: point(0, bottom))
            path.addQuadCurve(to: point(0, middle), control: point(-sway, (bottom + middle) / 2))
            path.addQuadCurve(to: point(0, top), control: point(sway, (middle + top) / 2))
        }
        return path
    }
}

extension RingGlyph.Mark {
    init(activity: ChargeActivity) {
        self = switch activity {
        case .holding, .resting: .holding
        case .charging: .charging
        case .discharging: .discharging
        case .heatPaused: .paused
        case .onBattery, .full, .unmanaged: .none
        }
    }
}

/// Rasterises SwiftUI glyphs into template images, so AppKit tints them for light and dark
/// menu bars and they stay sharp on Retina displays.
@MainActor
enum GlyphRenderer {
    static func templateImage(_ glyph: some View) -> NSImage {
        let renderer = ImageRenderer(content: glyph.foregroundStyle(.black))
        renderer.scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let image = renderer.nsImage
            ?? NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }
}
