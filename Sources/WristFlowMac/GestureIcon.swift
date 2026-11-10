import SwiftUI
import WristFlowCore

/// Pictures a trigger: an emoji for the built-in gestures, the user's own recording for
/// theirs (the hand as it was shown, or the path it drew), both halves for a combination.
struct GestureIcon: View {
    let trigger: Trigger
    let library: GestureLibrary
    /// Height of the picture in points.
    var size: CGFloat = 16

    var body: some View {
        switch trigger {
        case .combination(let id):
            if let combination = library.combination(id) {
                HStack(spacing: 1) {
                    GestureIcon(trigger: combination.left, library: library, size: size * 0.8)
                    GestureIcon(trigger: combination.right, library: library, size: size * 0.8)
                }
            } else {
                glyph
            }
        case .custom(let id):
            if let example = library.gesture(id)?.shape?.examples.first {
                RecordedDrawing(points: example.points, bones: Self.bones, size: size)
            } else if let path = library.gesture(id)?.movement?.takes.first {
                RecordedDrawing(points: path.points, bones: Self.chain(path.points.count), size: size, marksStart: true)
            } else {
                glyph
            }
        default:
            glyph
        }
    }

    private var glyph: some View {
        Text(trigger.glyph).font(.system(size: size))
    }

    /// The hand's bones as pairs of indexes into its 21 points.
    private static let bones: [(Int, Int)] = HandDrawing.bones.map { ($0.0.rawValue, $0.1.rawValue) }

    /// Consecutive points joined up, for a path.
    private static func chain(_ count: Int) -> [(Int, Int)] {
        (0..<max(count - 1, 0)).map { ($0, $0 + 1) }
    }
}

/// A recording drawn as lines between its points, scaled to fit a square. The points have
/// `y` growing upwards, like everything WristFlow measures.
private struct RecordedDrawing: View {
    let points: [Point2]
    let bones: [(Int, Int)]
    let size: CGFloat
    /// Puts a dot where a path begins, which is what tells a circle one way from the other.
    var marksStart = false

    var body: some View {
        Canvas { context, canvas in
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let stroke = max(1, canvas.height / 14)
            let room = canvas.height - stroke * 2
            let span = max(maxX - minX, maxY - minY, 1e-6)
            let scale = room / span
            // Centred in the square, whichever way the drawing is longer.
            let offsetX = (canvas.width - (maxX - minX) * scale) / 2
            let offsetY = (canvas.height - (maxY - minY) * scale) / 2
            func place(_ index: Int) -> CGPoint {
                CGPoint(
                    x: offsetX + (points[index].x - minX) * scale,
                    y: canvas.height - offsetY - (points[index].y - minY) * scale
                )
            }
            var path = Path()
            for (from, to) in bones where from < points.count && to < points.count {
                path.move(to: place(from))
                path.addLine(to: place(to))
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
            if marksStart, !points.isEmpty {
                let start = place(0)
                let radius = stroke * 1.6
                let dot = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: dot), with: .foreground)
            }
        }
        .frame(width: size, height: size)
    }
}
