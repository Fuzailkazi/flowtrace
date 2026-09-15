import SwiftUI
import AppKit

/// The FlowTrace mark — a single continuous looped stroke.
///
/// Drawn from the vector path in the approved Stitch design ("FlowTrace Primary
/// Monochromatic Geometric Mark"), not from a bitmap, so it renders crisp at
/// 16pt in the menu bar and at 28pt in the sidebar, in any colour, and as a
/// template image that follows the menu bar's appearance.
struct BrandMark: Shape {
    /// The design's path is authored in a 128×128 box.
    private static let designBox: CGFloat = 128

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.designBox
        let offset = CGPoint(
            x: rect.minX + (rect.width - Self.designBox * scale) / 2,
            y: rect.minY + (rect.height - Self.designBox * scale) / 2
        )
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        var path = Path()
        path.move(to: p(28, 64))
        path.addCurve(to: p(80, 18), control1: p(28, 32), control2: p(54, 18))
        path.addCurve(to: p(92, 72), control1: p(108, 18), control2: p(122, 42))
        path.addCurve(to: p(22, 82), control1: p(68, 96), control2: p(40, 98))
        path.addCurve(to: p(26, 30), control1: p(8, 68), control2: p(8, 44))
        path.addCurve(to: p(112, 58), control1: p(48, 16), control2: p(92, 28))
        path.addCurve(to: p(82, 106), control1: p(124, 78), control2: p(110, 106))
        path.addCurve(to: p(28, 64), control1: p(52, 106), control2: p(28, 88))
        path.closeSubpath()
        return path
    }

    /// Stroke width relative to the mark's size (12.5 of 128 in the design).
    static func lineWidth(for size: CGFloat) -> CGFloat { size * 12.5 / designBox }
}

/// The mark, stroked in a colour, at a size.
struct BrandMarkView: View {
    var size: CGFloat = 24
    var color: Color = Journal.pen

    var body: some View {
        BrandMark()
            .stroke(color, style: StrokeStyle(
                lineWidth: BrandMark.lineWidth(for: size), lineCap: .round, lineJoin: .round
            ))
            .frame(width: size, height: size)
    }
}

extension BrandMark {
    /// A template image for the menu bar: monochrome, auto-inverting.
    @MainActor
    static func menuBarImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            let path = BrandMark().path(in: rect.insetBy(dx: 1, dy: 1))
            let bezier = NSBezierPath(cgPath: path.cgPath)
            bezier.lineWidth = BrandMark.lineWidth(for: rect.width - 2)
            bezier.lineCapStyle = .round
            bezier.lineJoinStyle = .round
            NSColor.black.setStroke()
            bezier.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Mark plus wordmark, as the sidebar header in the design.
struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMarkView(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("FlowTrace")
                    .font(.journalTitle(15))
                    .tracking(-0.3)
                    .foregroundStyle(Journal.ink)
                HStack(spacing: 5) {
                    Circle().fill(Journal.pen).frame(width: 6, height: 6)
                    Text("Local only")
                        .font(.caption())
                        .foregroundStyle(Journal.inkMid)
                }
            }
        }
    }
}
