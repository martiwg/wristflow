import SwiftUI
import WristFlowCore

/// Pictures a trigger: an emoji for the built-in gestures, both halves for a combination.
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
        default:
            glyph
        }
    }

    private var glyph: some View {
        Text(trigger.glyph).font(.system(size: size))
    }
}
