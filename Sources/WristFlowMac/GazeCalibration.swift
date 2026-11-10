import AppKit
import Observation
import SwiftUI
import WristFlowCore

/// Runs the gaze calibration across the connected displays: a dark window on every display, a
/// dot to look at on one of them at a time, and the faces seen meanwhile recorded as samples.
@MainActor
final class GazeCalibrationController {
    static let shared = GazeCalibrationController()

    /// Seconds the eyes get to reach a new dot before anything is recorded.
    private static let settleTime = 0.8
    /// Seconds of faces recorded per dot.
    private static let recordTime = 1.5
    /// Seconds without a face after which the user counts as not being seen.
    private static let faceTimeout = 0.5
    /// Fewest samples a dot needs, however slowly faces arrive.
    private static let minimumSamples = 8
    /// Where the dots go, as fractions of the display from its top left: the centre, then the
    /// corners clockwise, so the eyes travel along one edge at a time. The corners sit 85% of
    /// the way out from the centre: far enough to span the display, not so far that the bezel
    /// gets in the way.
    private static let unitPoints: [CGPoint] = {
        let reach = 0.85 / 2
        return [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.5 - reach, y: 0.5 - reach),
            CGPoint(x: 0.5 + reach, y: 0.5 - reach),
            CGPoint(x: 0.5 + reach, y: 0.5 + reach),
            CGPoint(x: 0.5 - reach, y: 0.5 + reach),
        ]
    }()

    private struct ScreenSlot: Equatable {
        let id: String
        /// In AppKit's global coordinates, like `NSEvent.mouseLocation`.
        let frame: CGRect
    }

    private struct Target {
        let display: String
        let point: CGPoint
        /// Unique across the run; the classifier summarises and holds out samples by it.
        let group: Int
    }

    private var model: AppModel?
    private var run: CalibrationRun?
    private var screens: [ScreenSlot] = []
    private var windows: [String: CalibrationWindow] = [:]
    private var screenObserver: NSObjectProtocol?
    private var timer: Timer?

    private var targets: [Target] = []
    private var targetIndex = 0
    private var samples: [GazeSample] = []
    private var pointSamples = 0
    /// Seconds of faces recorded for the current dot.
    private var recorded = 0.0
    private var pointShownAt = 0.0
    private var lastFaceAt: Double?
    private var listeningSince = 0.0

    /// Starts a calibration run, or brings the one in progress to the front.
    func begin(model: AppModel) {
        guard run == nil else {
            bringToFront()
            return
        }
        let screens = Self.connectedScreens()
        if let problem = Self.problem(displays: screens.count, model: model) {
            Self.showAlert(title: problem.title, text: problem.text)
            return
        }

        let run = CalibrationRun(activeDisplay: Self.pointerDisplay(in: screens))
        self.model = model
        self.run = run
        self.screens = screens
        for screen in screens {
            windows[screen.id] = makeWindow(for: screen, run: run, model: model)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // Already during the introduction: with the face stream taken, gaze focus cannot pull
        // the pointer and the keyboard away while the user reads, and the first dot knows
        // from the start whether a face is in view.
        listenForFaces()
        bringToFront()
    }

    // MARK: What the buttons do

    fileprivate func start() {
        guard let run, run.phase != .recording else { return }
        if model?.faceSink == nil { listenForFaces() }

        // The display the user just clicked on goes first: that is where they are looking.
        let first = Self.pointerDisplay(in: screens)
        let ordered = screens.filter { $0.id == first } + screens.filter { $0.id != first }
        targets = ordered.enumerated().flatMap { index, screen in
            Self.unitPoints.enumerated().map { offset, point in
                Target(display: screen.id, point: point, group: index * Self.unitPoints.count + offset)
            }
        }
        samples = []
        run.faceLost = false
        run.phase = .recording
        show(target: 0)

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so a click held on a button does not freeze the run.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Closes the windows and gives the face stream back, whatever state the run is in. This is
    /// Cancel, Esc and Done alike: a finished run has already been saved.
    fileprivate func end() {
        guard run != nil else { return }
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        model?.faceSink = nil

        let closing = Array(windows.values)
        windows = [:]
        screens = []
        targets = []
        samples = []
        run = nil
        model = nil
        for window in closing {
            window.onCancel = nil
            window.onClose = nil
            window.close()
        }
        // The click or key press that ended the run is still being handled by a view inside
        // one of these windows, so they are let go only once that has returned.
        DispatchQueue.main.async { _ = closing }
    }

    // MARK: Recording

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func listenForFaces() {
        lastFaceAt = nil
        listeningSince = Self.now
        model?.faceSink = { [weak self] face in self?.ingest(face) }
    }

    private func show(target index: Int) {
        guard let run else { return }
        let target = targets[index]
        targetIndex = index
        pointSamples = 0
        recorded = 0
        pointShownAt = Self.now
        run.pointIndex = index
        run.dot = target.point
        run.progress = 0
        run.activeDisplay = target.display
    }

    private func ingest(_ face: FaceFrame) {
        guard let run else { return }
        let now = Self.now
        let previous = lastFaceAt
        lastFaceAt = now
        if run.faceLost { run.faceLost = false }
        guard run.phase == .recording, targets.indices.contains(targetIndex) else { return }

        let recordingSince = pointShownAt + Self.settleTime
        // Time is credited face by face, as the stretch since the one before, so it cannot
        // advance while nobody is seen. A face that follows a gap only restarts the stream:
        // nothing vouches for where the user was looking during the gap.
        guard now >= recordingSince, let previous, now - previous <= Self.faceTimeout else { return }
        let features = GazeFeatures.vector(face)
        // The classifier drops such a sample, so it must not count towards the minimum either.
        guard features.allSatisfy(\.isFinite) else { return }

        let target = targets[targetIndex]
        samples.append(GazeSample(display: target.display, group: target.group, features: features))
        pointSamples += 1
        recorded += now - max(previous, recordingSince)
        run.progress = min(1, recorded / Self.recordTime, Double(pointSamples) / Double(Self.minimumSamples))

        guard recorded >= Self.recordTime, pointSamples >= Self.minimumSamples else { return }
        if targetIndex + 1 < targets.count {
            show(target: targetIndex + 1)
        } else {
            finish()
        }
    }

    private func tick() {
        guard let run, run.phase == .recording else { return }
        let lost = Self.now - (lastFaceAt ?? listeningSince) > Self.faceTimeout
        if run.faceLost != lost { run.faceLost = lost }
    }

    private func finish() {
        guard let run, let model else { return }
        timer?.invalidate()
        timer = nil
        // The face stream stays taken until the windows close: gaze focus coming alive on the
        // result screen could move the keyboard to another app before the user presses Done.
        model.saveGazeCalibration(samples: samples)
        samples = []

        let outcome: CalibrationRun.Outcome
        if case .ready(let accuracy) = model.gazeHealth {
            outcome = .calibrated(accuracy: accuracy)
        } else {
            outcome = .failed
        }
        run.activeDisplay = Self.pointerDisplay(in: screens)
        run.phase = .finished(outcome)
        // Return and Esc go to the key window, so it has to be the one with the buttons.
        windows[run.activeDisplay]?.makeKey()
    }

    // MARK: Displays

    /// Same derivation as `MacDisplayFocus`, so the samples carry the ids the model knows the
    /// displays by.
    private static func displayID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
              let id = CFUUIDCreateString(nil, uuid) as String?
        else { return nil }
        return id
    }

    /// Sorted by id, so two readings of the same arrangement compare equal.
    private static func connectedScreens() -> [ScreenSlot] {
        NSScreen.screens.compactMap { screen in
            displayID(of: screen).map { ScreenSlot(id: $0, frame: screen.frame) }
        }
        .sorted { $0.id < $1.id }
    }

    /// Id of the display the pointer is on. `screens` must not be empty.
    private static func pointerDisplay(in screens: [ScreenSlot]) -> String {
        let pointer = NSEvent.mouseLocation
        return (screens.first { $0.frame.contains(pointer) } ?? screens[0]).id
    }

    private func screensChanged() {
        guard let run else { return }
        // The notification also comes for changes that leave every display where it was.
        guard Self.connectedScreens() != screens else { return }
        let alreadySaved: Bool
        if case .finished = run.phase { alreadySaved = true } else { alreadySaved = false }
        end()
        guard !alreadySaved else { return }
        Self.showAlert(
            title: "Calibration stopped",
            text: "Your displays changed while calibrating. Start the calibration again once they are set up the way you use them."
        )
    }

    // MARK: Windows

    private func makeWindow(for screen: ScreenSlot, run: CalibrationRun, model: AppModel) -> CalibrationWindow {
        let window = CalibrationWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.94)
        window.hasShadow = false
        window.animationBehavior = .none
        // Above the menu bar and the Dock, which would otherwise sit close to the corner dots.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The content is drawn on black whatever the system appearance is.
        window.appearance = NSAppearance(named: .darkAqua)
        window.onCancel = { [weak self] in self?.end() }
        window.onClose = { [weak self] in self?.end() }

        let content = FirstClickHostingView(
            rootView: CalibrationScreenView(run: run, model: model, display: screen.id, controller: self)
        )
        // Left alone, the hosting view would resize the window to what its content asks for.
        content.sizingOptions = []
        window.contentView = content
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func bringToFront() {
        guard let run else { return }
        // A menu bar app is not activated by showing a window, and an app that is not active
        // gets no key presses.
        NSApp.activate(ignoringOtherApps: true)
        for window in windows.values { window.orderFrontRegardless() }
        // While dots are showing no window has buttons, so the pointer's is as good as any.
        let key = run.phase == .recording ? Self.pointerDisplay(in: screens) : run.activeDisplay
        windows[key]?.makeKeyAndOrderFront(nil)
    }

    // MARK: Alerts

    private static func problem(displays: Int, model: AppModel) -> (title: String, text: String)? {
        guard displays >= 2 else {
            return (
                "Gaze focus needs two displays",
                "WristFlow moves focus to the display you look at, so there is nothing to calibrate with one display. Connect another and try again."
            )
        }
        switch model.camera {
        case .running:
            return nil
        case .denied:
            return (
                "WristFlow cannot use the camera",
                "Allow WristFlow in System Settings > Privacy & Security > Camera, then start the calibration again."
            )
        case .failed(let message):
            return ("The camera is not working", message)
        case .starting:
            return ("The camera is not ready yet", "Start the calibration again in a moment.")
        case .stopped where !model.config.enabled:
            return ("WristFlow is turned off", "Calibration needs the camera. Turn WristFlow on, then start the calibration again.")
        case .stopped:
            return ("The camera is off", "Calibration needs the camera. Start the calibration again in a moment.")
        }
    }

    private static func showAlert(title: String, text: String) {
        // On the next turn of the run loop: a modal alert should not start inside a menu
        // action or while AppKit is still delivering the display change to its observers.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = text
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}

/// What the calibration windows show. One instance per run, read by every window.
@MainActor
@Observable
private final class CalibrationRun {
    enum Outcome: Equatable {
        case calibrated(accuracy: Double)
        /// The model could not build a classifier from what was recorded.
        case failed
    }

    enum Phase: Equatable {
        case intro
        case recording
        case finished(Outcome)
    }

    var phase = Phase.intro
    /// Id of the display that shows the introduction, the dot or the result; the others stay dark.
    var activeDisplay: String
    /// Changes with every dot, so each one gets a fresh ring.
    var pointIndex = 0
    /// Where the dot is, as fractions of the display from its top left.
    var dot = CGPoint(x: 0.5, y: 0.5)
    /// 0...1 of the current dot's recording.
    var progress = 0.0
    var faceLost = false

    init(activeDisplay: String) {
        self.activeDisplay = activeDisplay
    }
}

private final class CalibrationWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    // A borderless window refuses the keyboard unless told otherwise, and Esc would never arrive.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// What AppKit sends for Esc when no button in the window claims the key.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func close() {
        // However the window comes to close, the run must not be left holding the face stream.
        let handler = onClose
        onClose = nil
        super.close()
        handler?()
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    // Another app can become active while these windows are up (gaze focus is live again on
    // the result screen). A click on a button must work all the same, not just bring the
    // window back.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Views

private struct CalibrationScreenView: View {
    let run: CalibrationRun
    let model: AppModel
    let display: String
    let controller: GazeCalibrationController

    var body: some View {
        // Measured over the whole window, safe areas included: the dots are placed as
        // fractions of the display itself.
        GeometryReader { geometry in
            ZStack {
                if run.activeDisplay == display {
                    switch run.phase {
                    case .intro:
                        IntroCard(controller: controller)
                    case .recording:
                        TargetView(run: run, cameraRunning: model.camera == .running, size: geometry.size)
                            .id(run.pointIndex)
                    case .finished(let outcome):
                        ResultCard(outcome: outcome, controller: controller)
                    }
                }
                if run.phase == .recording {
                    // On every display: a way out that needs neither the keyboard nor the dot.
                    Button("Cancel") { controller.end() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0.6)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 28)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

private struct TargetView: View {
    private static let ringSize: CGFloat = 60
    private static let messageOffset: CGFloat = 62
    /// Keeps the message on the display when the dot is in a corner.
    private static let messageMargin: CGFloat = 150

    let run: CalibrationRun
    let cameraRunning: Bool
    let size: CGSize

    var body: some View {
        let centre = CGPoint(x: run.dot.x * size.width, y: run.dot.y * size.height)
        ZStack {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: run.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Faces arrive in steps of about a tenth of a second.
                    .animation(.linear(duration: 0.1), value: run.progress)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                // A point inside the dot gives the eyes one exact place to rest on.
                Circle()
                    .fill(.black)
                    .frame(width: 4, height: 4)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .position(centre)

            if run.faceLost {
                Text(cameraRunning ? "I can't see your face" : "The camera is off")
                    .font(.title3.weight(.medium))
                    .fixedSize()
                    .position(
                        x: min(max(centre.x, Self.messageMargin), max(Self.messageMargin, size.width - Self.messageMargin)),
                        // Towards the middle of the display, where there is always room.
                        y: centre.y + (run.dot.y > 0.5 ? -Self.messageOffset : Self.messageOffset)
                    )
            }
        }
    }
}

private struct IntroCard: View {
    let controller: GazeCalibrationController

    var body: some View {
        VStack(spacing: 16) {
            Text("Gaze calibration")
                .font(.largeTitle.weight(.semibold))
            Text("Look at each dot until its ring fills. Sit the way you normally do and move your head and eyes as you naturally would to look at each dot.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Cancel") { controller.end() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 10)
        }
        .frame(maxWidth: 480)
        .padding(40)
    }
}

private struct ResultCard: View {
    /// Under this share of the self-test (0...1) the user is advised to calibrate again.
    private static let goodAccuracy = 0.7

    let outcome: CalibrationRun.Outcome
    let controller: GazeCalibrationController

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Calibrate Again") { controller.start() }
                Button("Done") { controller.end() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 10)
        }
        .frame(maxWidth: 480)
        .padding(40)
    }

    private var title: String {
        switch outcome {
        case .calibrated: "Gaze calibrated"
        case .failed: "Gaze was not calibrated"
        }
    }

    private var detail: String {
        switch outcome {
        case .calibrated(let accuracy):
            let figure = "\(Int((accuracy * 100).rounded()))% in self-test"
            guard accuracy < Self.goodAccuracy else { return figure }
            return "\(figure)\nTry again sitting as you normally do, and look straight at each dot."
        case .failed:
            return "What was recorded is not enough to tell your displays apart. Try again."
        }
    }
}
