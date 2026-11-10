import AVFoundation
import AppKit
import SwiftUI
import WristFlowCore

/// The window where the user learns the gestures: the camera as in a mirror, the hand
/// skeleton on top of it and, underneath, what WristFlow is reading right now.
struct PreviewView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VideoArea(model: model)
                .frame(width: PreviewLayout.videoSize.width, height: PreviewLayout.videoSize.height)
            Divider()
            ReadingPanel(model: model)
        }
        // The window takes its size from its content, so the content must not be flexible.
        .frame(width: PreviewLayout.videoSize.width)
        .fixedSize(horizontal: false, vertical: true)
        // The model only publishes hands and face while somebody is looking at them.
        .onAppear { model.previewVisible = true }
        .onDisappear { model.previewVisible = false }
    }
}

private enum PreviewLayout {
    static let videoSize = CGSize(width: 640, height: 480)
    static let fallbackAspect: CGFloat = 4.0 / 3.0

    /// Width over height of the frames the camera delivers.
    static func cameraAspect(of session: AVCaptureSession?) -> CGFloat {
        guard let input = session?.inputs.lazy.compactMap({ $0 as? AVCaptureDeviceInput }).first else {
            return fallbackAspect
        }
        let size = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        guard size.width > 0, size.height > 0 else { return fallbackAspect }
        return CGFloat(size.width) / CGFloat(size.height)
    }

    /// The rectangle a picture of this aspect takes when fitted inside `size`, which is where
    /// the preview layer draws the video.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var fitted = CGSize(width: size.width, height: size.width / aspect)
        if fitted.height > size.height {
            fitted = CGSize(width: size.height * aspect, height: size.height)
        }
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

// MARK: Video

private struct VideoArea: View {
    let model: AppModel

    var body: some View {
        // `captureSession` is not observable by itself. It only ever changes together with
        // `camera`, so reading both here is what keeps this in step when the camera is turned
        // off or another one is chosen.
        let session = model.camera == .running ? model.captureSession : nil
        if let session {
            ZStack {
                Color.black
                CameraPreview(session: session)
                HandOverlay(model: model)
            }
        } else {
            CameraPlaceholder(model: model)
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewLayerView {
        PreviewLayerView()
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        view.show(session)
    }

    static func dismantleNSView(_ view: PreviewLayerView, coordinator: ()) {
        // A layer left attached would keep a stopped session and its camera input alive.
        view.show(nil)
    }
}

private final class PreviewLayerView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    func show(_ session: AVCaptureSession?) {
        if previewLayer.session !== session { previewLayer.session = session }
        // The camera delivers a true view of the scene. People expect to see themselves as in
        // a mirror, and that is also the view the landmarks are expressed in. Automatic
        // mirroring has to go first: setting the flag while it is on raises an exception.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

private struct CameraPlaceholder: View {
    let model: AppModel

    var body: some View {
        let reason = reason
        VStack(spacing: 10) {
            Image(systemName: reason.symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(reason.title)
                .font(.title3.weight(.semibold))
            Text(reason.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.camera == .denied {
                Button("Open Camera Settings") { model.openCameraSettings() }
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reason: (symbol: String, title: String, detail: String) {
        switch model.camera {
        case .denied:
            ("video.slash", "No access to the camera", "Allow WristFlow in System Settings > Privacy & Security > Camera.")
        case .failed(let message):
            ("exclamationmark.triangle", "The camera could not be started", message)
        case .starting:
            ("video", "Waiting for camera access", "Answer the system prompt to let WristFlow use the camera.")
        case .running:
            ("video", "Starting the camera", "The picture will appear in a moment.")
        case .stopped where !model.config.enabled:
            ("video.slash", "The camera is off", "WristFlow is turned off, so it is not using the camera.")
        case .stopped:
            ("video.slash", "The camera is off", "It stays off while the screen is locked or asleep.")
        }
    }
}

// MARK: Hand skeleton

private struct HandOverlay: View {
    let model: AppModel

    var body: some View {
        let hands = model.hands
        // Read again on every redraw: the session settles on its format a moment after it
        // starts, and by the time hands arrive the value is final.
        let aspect = PreviewLayout.cameraAspect(of: model.captureSession)
        Canvas { context, size in
            let video = PreviewLayout.fit(aspect: aspect, in: size)
            context.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            for hand in hands {
                HandDrawing.draw(hand, in: video, aspect: aspect, context: &context)
            }
        }
        .allowsHitTesting(false)
    }
}

private enum HandDrawing {
    /// Joints under this confidence (0...1) are drawn dimmed; the pose classifier does not
    /// believe them either.
    static let trustedConfidence: Float = 0.3
    static let dimmedOpacity = 0.3

    static let bones: [(Joint, Joint)] = {
        var pairs: [(Joint, Joint)] = []
        for finger in Finger.allCases {
            let joints = finger.joints
            pairs.append((.wrist, joints[0]))
            pairs.append(contentsOf: zip(joints, joints.dropFirst()))
        }
        let bases: [Joint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        pairs.append(contentsOf: zip(bases, bases.dropFirst()))
        return pairs
    }()

    static func draw(_ hand: Hand, in video: CGRect, aspect: CGFloat, context: inout GraphicsContext) {
        func location(_ joint: Joint) -> CGPoint {
            let point = hand[joint]
            return CGPoint(
                x: video.minX + CGFloat(point.x) / aspect * video.width,
                y: video.minY + (1 - CGFloat(point.y)) * video.height
            )
        }
        // A joint with no confidence at all was not seen: its position is a stand-in at the
        // middle of the hand, and drawing it would show a joint where there is none.
        func seen(_ joint: Joint) -> Bool { hand.confidence(of: joint) > 0 }
        func opacity(_ joints: Joint...) -> Double {
            joints.allSatisfy { hand.confidence(of: $0) >= trustedConfidence } ? 1 : dimmedOpacity
        }

        for (from, to) in bones where seen(from) && seen(to) {
            var path = Path()
            path.move(to: location(from))
            path.addLine(to: location(to))
            context.stroke(
                path,
                with: .color(.white.opacity(0.9 * opacity(from, to))),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        for joint in Joint.allCases where seen(joint) {
            let centre = location(joint)
            let radius: CGFloat = joint == .wrist ? 5 : 3.5
            let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(.yellow.opacity(opacity(joint))))
        }
    }
}

// MARK: What is being read

private struct ReadingPanel: View {
    let model: AppModel

    var body: some View {
        let gesture = model.gesture
        let progress = min(1, max(0, gesture.holdProgress))
        // Every row is always there, hidden rather than removed, so the window keeps its size.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(poseText(gesture))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(gesture.pose == nil ? .secondary : .primary)
                Spacer()
                Label("Ready to swipe", systemImage: "arrow.left.and.right")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .opacity(gesture.armedForSwipe ? 1 : 0)
                    .accessibilityHidden(!gesture.armedForSwipe)
            }
            ProgressView(value: progress)
                // Full means the pose has fired.
                .tint(progress >= 1 ? Color.green : Color.accentColor)
                .accessibilityLabel("Hold progress")
            lastGesture
            FaceLine(model: model)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // Qualified because SwiftUI has a `GestureState` of its own.
    private func poseText(_ gesture: WristFlowCore.GestureState) -> String {
        if let pose = gesture.pose {
            let trigger = Trigger(pose: pose)
            return "\(trigger.glyph) \(trigger.title)"
        }
        return gesture.handVisible ? "Hand seen, no pose" : "No hand"
    }

    @ViewBuilder
    private var lastGesture: some View {
        if let report = model.lastTrigger {
            HStack(spacing: 6) {
                Text("Last gesture:")
                    .foregroundStyle(.secondary)
                Text("\(report.trigger.glyph) \(report.trigger.title)")
                Text(report.binding.summary)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No gesture yet")
                .foregroundStyle(.secondary)
        }
    }
}

private struct FaceLine: View {
    /// Faces arrive about ten times a second; after this long without one, the last one no
    /// longer says anything about now.
    private static let freshness = 1.0

    let model: AppModel
    /// When the latest face arrived. The model keeps the last face it measured, so without
    /// this a face that has left the picture would go on showing its last angles.
    @State private var faceSeenAt: Date?

    var body: some View {
        let face = model.face
        let display = model.displayName(model.lookingAt)
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Text(text(face: face, display: display, at: timeline.date))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onChange(of: face?.time) { _, time in
            faceSeenAt = time == nil ? nil : Date()
        }
    }

    private func text(face: FaceFrame?, display: String?, at date: Date) -> String {
        guard let face, let faceSeenAt, date.timeIntervalSince(faceSeenAt) < Self.freshness else {
            return "No face seen"
        }
        let head = "Head yaw \(Self.degrees(face.yaw))°, pitch \(Self.degrees(face.pitch))°"
        guard let display else { return head }
        return "\(head) · Looking at \(display)"
    }

    private static func degrees(_ radians: Double) -> Int {
        // Converting a value that is not a number to an integer traps.
        radians.isFinite ? Int((radians * 180 / .pi).rounded()) : 0
    }
}
