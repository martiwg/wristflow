import Foundation
import Observation
import WristFlowCore

/// One run of a guided flow: recording a gesture of the user's own, or fitting the built-in
/// gestures to their hands. It is fed the camera's frames while it runs and decides what the
/// window shows; nothing is saved until the user says so.
@MainActor
@Observable
final class TrainingSession {
    enum Flow: Equatable {
        case newGesture
        /// Recording an existing gesture again, keeping its name and what it does.
        case rerecord(CustomGesture)
        case calibration
    }

    enum GestureKind: String, CaseIterable, Identifiable {
        case shape, movement

        var id: String { rawValue }
    }

    enum Stage: Equatable {
        /// Naming the gesture and choosing its kind, or what the calibration is about to ask.
        case intro
        /// Showing the shape with one hand, in several takes.
        case shape(Handedness)
        /// Making the movement, in several takes.
        case movement
        /// One step of the calibration plan, by its index.
        case calibrate(Int)
        /// What was learned, and what it could be mistaken for.
        case review
        /// Making the new gesture for real, to see it recognised.
        case tryIt
        /// Saved; choosing what it does.
        case assign
        /// What the calibration changed.
        case result
    }

    /// Something the review found.
    struct Finding: Identifiable, Equatable {
        enum Level { case good, caution }

        let level: Level
        let text: String
        var id: String { text }
    }

    /// Takes of a shape asked of each hand.
    static let shapeTakes = 3
    /// Steady frames collected per take of a shape; at 30 frames a second, under a second.
    static let framesPerShapeTake = 20
    /// Takes of a movement.
    static let movementTakes = 4
    /// Steady frames collected for a calibration step.
    static let framesPerCalibrationStep = 30
    /// Swipes asked for in each direction.
    static let swipesPerStep = 3
    /// Times the new gesture should be recognised before the test counts as passed.
    static let recognitionsWanted = 3

    let flow: Flow
    private let model: AppModel
    private(set) var stage = Stage.intro
    var name: String
    var kind = GestureKind.shape

    // MARK: What the capture stages show

    /// What stops the capture right now, or what to do next, in words.
    private(set) var hint = ""
    /// 0...1 through the current take, for the ring.
    private(set) var takeProgress = 0.0
    /// Takes finished in the current stage, and how many it asks for.
    private(set) var takesDone = 0
    private(set) var takesWanted = 0
    /// The movement under way, in image heights, for drawing it over the camera.
    private(set) var trail: [Point2] = []
    /// Why the last calibration step was not accepted, shown until the next attempt.
    private(set) var rejection: String?

    // MARK: What the later stages show

    private(set) var candidate: CustomGesture?
    private(set) var findings: [Finding] = []
    private(set) var recognitions = 0
    /// Something else the test read instead of the new gesture, in words.
    private(set) var misread: String?
    private(set) var report: CalibrationReport?
    /// Set when the flow is over and the window should close.
    private(set) var isFinished = false

    // MARK: Internals

    @ObservationIgnored private var capture: PoseCapture?
    @ObservationIgnored private var shapes: [Handedness: [[Hand]]] = [:]
    @ObservationIgnored private var tracker = MovementTracker()
    @ObservationIgnored private var segments: [MovementSegment] = []
    @ObservationIgnored private var trial: GestureEngine?
    @ObservationIgnored private var samples: [CalibrationSample] = []
    @ObservationIgnored private var swipeFrames: [HandFrame] = []
    @ObservationIgnored private var calibration: PersonalCalibration?
    @ObservationIgnored private var advancing: Task<Void, Never>?
    /// The problem the capture is reporting and since when (frame time), before it is shown.
    @ObservationIgnored private var pendingHint: (text: String, since: Double)?
    /// Seconds a problem has to last before the hint names it.
    private static let hintDelay = 0.3
    /// False for a session that only exists to be drawn (snapshots): it never touches the camera.
    @ObservationIgnored private let isLive: Bool

    init(flow: Flow, model: AppModel, live: Bool = true) {
        self.flow = flow
        self.model = model
        isLive = live
        switch flow {
        case .newGesture:
            name = Self.freshName(in: model.library)
        case .rerecord(let gesture):
            name = gesture.name
            kind = gesture.movement == nil ? .shape : .movement
        case .calibration:
            name = ""
        }
        if case .rerecord = flow { begin() }
    }

    private static func freshName(in library: GestureLibrary) -> String {
        let taken = Set(library.customGestures.map(\.name))
        var number = library.customGestures.count + 1
        while taken.contains("My gesture \(number)") { number += 1 }
        return "My gesture \(number)"
    }

    /// Puts a session that is not live at a stage, for drawing the window without the camera.
    func show(_ stage: Stage, hint: String, takesDone: Int, progress: Double) {
        guard !isLive else { return }
        enter(stage)
        self.hint = hint
        self.takesDone = takesDone
        takeProgress = progress
    }

    // MARK: Camera

    /// Takes over the camera's frames. Gestures fire nothing until `detach`.
    func attach() {
        guard isLive else { return }
        model.handSink = { [weak self] frame in self?.ingest(frame) }
        model.faceSink = { [weak self] frame in self?.ingest(frame) }
    }

    func detach() {
        advancing?.cancel()
        guard isLive else { return }
        model.handSink = nil
        model.faceSink = nil
    }

    private func ingest(_ frame: FaceFrame) {
        capture?.ingest(frame)
        trial?.ingest(frame)
    }

    private func ingest(_ frame: HandFrame) {
        switch stage {
        case .shape, .calibrate:
            if isSwipeStep {
                followSwipes(frame)
            } else {
                followCapture(frame)
            }
        case .movement:
            followMovement(frame)
        case .tryIt:
            followTrial(frame)
        case .intro, .review, .assign, .result:
            break
        }
    }

    // MARK: Moving through the flow

    /// Position in the flow, for the header: 1-based step and the number of steps.
    var progress: (step: Int, of: Int) {
        if flow == .calibration {
            let steps = CalibrationPlan.steps.count
            switch stage {
            case .calibrate(let index): return (index + 2, steps + 2)
            case .result: return (steps + 2, steps + 2)
            default: return (1, steps + 2)
            }
        }
        var stages: [Stage] = kind == .shape ? [.shape(.right), .shape(.left), .review, .tryIt] : [.movement, .review, .tryIt]
        // Recording a gesture again keeps its name and its action, so those steps are not there.
        if flow == .newGesture { stages = [.intro] + stages + [.assign] }
        return ((stages.firstIndex(of: stage) ?? 0) + 1, stages.count)
    }

    /// Leaves the intro: starts capturing.
    func begin() {
        switch flow {
        case .calibration:
            samples = []
            enter(.calibrate(0))
        case .newGesture, .rerecord:
            shapes = [:]
            segments = []
            enter(kind == .shape ? .shape(.right) : .movement)
        }
    }

    /// Skips what the current stage asks for: a hand the user does not want to record, or a
    /// calibration step they cannot do.
    func skip() {
        switch stage {
        case .shape(.right):
            enter(.shape(.left))
        case .shape(.left):
            finishShape()
        case .calibrate(let index):
            advanceCalibration(from: index)
        default:
            break
        }
    }

    /// Whether the current stage can be skipped. One hand of a shape has to be recorded.
    var canSkip: Bool {
        switch stage {
        case .shape(.right): true
        case .shape(.left): !(shapes[.right] ?? []).isEmpty
        case .calibrate: true
        default: false
        }
    }

    /// Starts the recording over from the first capture stage.
    func recordAgain() {
        candidate = nil
        findings = []
        begin()
    }

    /// From the review on to the test.
    func startTrial() {
        guard let candidate else { return }
        var library = model.library
        library.customGestures.removeAll { $0.id == candidate.id }
        library.customGestures.append(candidate)
        var gestures = GestureConfig()
        gestures.holdTime = model.config.holdTime
        var engine = GestureEngine(config: library.tuned(gestures))
        engine.library = library
        trial = engine
        recognitions = 0
        misread = nil
        stage = .tryIt
    }

    /// Saves the gesture. A new one goes on to choosing its action; one recorded again is done.
    func save() {
        guard var candidate else { return }
        candidate.name = cleanName
        trial = nil
        model.saveGesture(candidate)
        self.candidate = candidate
        if case .rerecord = flow {
            isFinished = true
        } else {
            stage = .assign
        }
    }

    /// Puts the calibration to use.
    func applyCalibration() {
        model.setCalibration(calibration)
        isFinished = true
    }

    func finish() {
        isFinished = true
    }

    private var cleanName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.freshName(in: model.library) : trimmed
    }

    private func enter(_ next: Stage) {
        advancing?.cancel()
        stage = next
        rejection = nil
        takeProgress = 0
        takesDone = 0
        trail = []
        capture = nil
        switch next {
        case .shape(let hand):
            takesWanted = Self.shapeTakes
            capture = PoseCapture(request: PoseCapture.Request(
                hand: hand, takes: Self.shapeTakes, framesPerTake: Self.framesPerShapeTake, heldOut: true
            ))
            hint = Self.hint(for: .noHand, hand: hand)
        case .movement:
            takesWanted = Self.movementTakes
            tracker = MovementTracker()
            hint = "Hold your hand still, make the movement, then hold still again"
        case .calibrate(let index):
            beginCalibrationStep(index)
        case .intro, .review, .tryIt, .assign, .result:
            takesWanted = 0
            hint = ""
        }
    }

    /// Moves on a moment later, so the user sees the take complete before the screen changes.
    private func advance(after delay: Double = 0.7, _ action: @escaping @MainActor () -> Void) {
        advancing?.cancel()
        advancing = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    // MARK: Capturing held hands

    private func followCapture(_ frame: HandFrame) {
        guard var capture, capture.phase != .done else { return }
        capture.ingest(frame)
        self.capture = capture
        takesDone = capture.takes.count

        switch capture.phase {
        case .waiting(let problem):
            // What stops a capture changes from frame to frame at the edges (a blurred
            // frame, a small move), and words that change that fast cannot be read. A
            // problem is named once it has lasted a moment.
            let text = Self.hint(for: problem, hand: askedHand)
            if text != pendingHint?.text { pendingHint = (text, frame.time) }
            if let pendingHint, abs(frame.time - pendingHint.since) >= Self.hintDelay { hint = pendingHint.text }
        case .capturing(_, let progress):
            pendingHint = nil
            takeProgress = progress
            hint = "Hold it there"
        case .lowerHand:
            takeProgress = 1
            hint = "Good. Lower your hand, then show it again a little differently"
        case .done:
            takeProgress = 1
            hint = "Got it"
            captureFinished(capture)
        }
    }

    private var askedHand: Handedness? {
        switch stage {
        case .shape(let hand): hand
        case .calibrate(let index): CalibrationPlan.steps[index].hand
        default: nil
        }
    }

    private static func hint(for problem: PoseCapture.Problem, hand: Handedness?) -> String {
        let which = hand.map { $0 == .left ? "left " : "right " } ?? ""
        switch problem {
        case .noHand: return "Show your \(which)hand to the camera"
        case .wrongHand: return "That is your other hand. Use your \(which)hand"
        case .tooFar: return "Come a little closer"
        case .unclear: return "Keep your whole hand in view"
        case .moving: return "Hold it still"
        case .byTheHead: return "Hold your hand out towards the camera"
        }
    }

    private func captureFinished(_ capture: PoseCapture) {
        switch stage {
        case .shape(let hand):
            shapes[hand] = capture.takes
            advance { [weak self] in
                guard let self else { return }
                if hand == .right { self.enter(.shape(.left)) } else { self.finishShape() }
            }
        case .calibrate(let index):
            let step = CalibrationPlan.steps[index]
            let hands = capture.takes.flatMap { $0 }
            if case .pose(let pose) = step.kind, let problem = Self.mismatch(of: hands, with: pose) {
                // A wrong pose would teach the wrong thresholds; ask again instead.
                rejection = problem
                beginCalibrationStep(index)
                return
            }
            rejection = nil
            samples.append(CalibrationSample(step: step, hands: hands, palmToFace: capture.palmToFace, swipePeaks: []))
            advance { [weak self] in self?.advanceCalibration(from: index) }
        default:
            break
        }
    }

    // MARK: Shapes

    private func finishShape() {
        let hands = [Handedness.right, .left].flatMap { shapes[$0] ?? [] }
        let takes = hands.map { $0.compactMap(ShapeExample.init) }.filter { !$0.isEmpty }
        guard let template = ShapeTemplate(takes: takes) else {
            findings = [Finding(level: .caution, text: "That was not enough to learn the shape. Record it again, holding each take still.")]
            candidate = nil
            enter(.review)
            return
        }
        let id = existingID ?? UUID().uuidString
        let others = model.library.shapes.filter { $0.id != id }
        let review = ShapeMatcher.review(takes: hands, template: template, others: others, profile: model.library.profile)
        candidate = CustomGesture(id: id, name: cleanName, shape: template, alsoReadAs: review.builtIn)

        var found: [Finding] = []
        if let builtIn = review.builtIn {
            let title = Trigger(pose: builtIn).title
            found.append(Finding(
                level: .caution,
                text: "WristFlow already reads this as \(title). If you keep it, your gesture takes over whenever the hand looks like your recording."
            ))
        }
        let similar = review.similar.compactMap { model.library.gesture($0)?.name }
        if !similar.isEmpty {
            found.append(Finding(
                level: .caution,
                text: "Very close to your gesture \(similar.joined(separator: ", ")). They may be mistaken for each other."
            ))
        }
        if !review.isConsistent {
            found.append(Finding(
                level: .caution,
                text: "Your takes were quite different from each other. Recording it again the same way each time will make it more reliable."
            ))
        }
        if shapes[.left]?.isEmpty ?? true {
            found.append(Finding(level: .good, text: "Recorded with your right hand; your left hand can make it too, mirrored."))
        } else if shapes[.right]?.isEmpty ?? true {
            found.append(Finding(level: .good, text: "Recorded with your left hand; your right hand can make it too, mirrored."))
        }
        if found.allSatisfy({ $0.level == .good }) {
            found.insert(Finding(level: .good, text: "It looks different from every other gesture."), at: 0)
        }
        findings = found
        enter(.review)
    }

    private var existingID: String? {
        if case .rerecord(let gesture) = flow { return gesture.id }
        return nil
    }

    // MARK: Movements

    private func followMovement(_ frame: HandFrame) {
        guard segments.count < Self.movementTakes else { return }
        let limits = GestureConfig()
        let usable = frame.hands.filter { Double($0.confidence) >= limits.minConfidence && $0.palmSize >= limits.minPalmSize }
        guard let hand = usable.max(by: { $0.palmSize < $1.palmSize }) else {
            trail = tracker.trail
            return
        }
        let segment = tracker.ingest(
            time: frame.time, center: hand.palmCenter, palmSize: hand.palmSize, pose: model.library.read(hand)
        )
        trail = tracker.trail
        hint = tracker.isMoving ? "Keep going, then hold still" : "Hold still, then make the movement"
        guard let segment else { return }

        segments.append(segment)
        takesDone = segments.count
        if segments.count < Self.movementTakes {
            hint = "Good. Do it again the same way"
        } else {
            hint = "Got it"
            advance { [weak self] in self?.finishMovement() }
        }
    }

    /// Forgets the last take of the movement, for one that went wrong.
    func undoTake() {
        guard stage == .movement, !segments.isEmpty else { return }
        advancing?.cancel()
        segments.removeLast()
        takesDone = segments.count
        hint = "Hold still, then make the movement"
    }

    var canUndoTake: Bool { stage == .movement && !segments.isEmpty }

    private func finishMovement() {
        guard let template = MovementTemplate(takes: segments) else {
            findings = [Finding(level: .caution, text: "Those takes did not make one movement. Record it again, the same way each time.")]
            candidate = nil
            enter(.review)
            return
        }
        candidate = CustomGesture(id: existingID ?? UUID().uuidString, name: cleanName, movement: template)

        var found: [Finding] = []
        if template.isStraightLine {
            found.append(Finding(
                level: .caution,
                text: "This is a plain straight line. Hands make those all day, so it may fire by accident; a curve or a zigzag is safer."
            ))
        }
        if let key = template.startPose, let start = Trigger(key: key) {
            let title = model.title(for: start)
            found.append(Finding(level: .good, text: "It starts from \(title): the movement only counts when it begins with that hand shape."))
            if model.config.binding(for: start).kind != .none {
                found.append(Finding(
                    level: .caution,
                    text: "\(title) also does something when held still. Start moving right away, or it fires first."
                ))
            }
        } else {
            found.append(Finding(
                level: .caution,
                text: "Your hand shape changed between takes, so the movement counts with any hand shape. Starting each take from the same clear pose makes accidents less likely."
            ))
        }
        findings = found
        enter(.review)
    }

    // MARK: Trying it

    private func followTrial(_ frame: HandFrame) {
        guard var engine = trial, let candidate else { return }
        let trigger = engine.ingest(frame)
        trial = engine
        guard let trigger else { return }
        if trigger == candidate.trigger {
            recognitions += 1
            misread = nil
        } else {
            misread = model.title(for: trigger)
        }
    }

    var trialPassed: Bool { recognitions >= Self.recognitionsWanted }

    // MARK: Calibration

    /// The step the calibration is on, when it is on one.
    var calibrationStep: CalibrationStep? {
        if case .calibrate(let index) = stage { return CalibrationPlan.steps[index] }
        return nil
    }

    private var isSwipeStep: Bool {
        if case .swipe = calibrationStep?.kind { return true }
        return false
    }

    private func beginCalibrationStep(_ index: Int) {
        let step = CalibrationPlan.steps[index]
        takeProgress = 0
        takesDone = 0
        switch step.kind {
        case .pose:
            takesWanted = 1
            capture = PoseCapture(request: PoseCapture.Request(
                hand: step.hand, takes: 1, framesPerTake: Self.framesPerCalibrationStep, heldOut: true
            ))
            hint = Self.hint(for: .noHand, hand: step.hand)
        case .handAtFace:
            takesWanted = 1
            capture = PoseCapture(request: PoseCapture.Request(
                hand: step.hand, takes: 1, framesPerTake: Self.framesPerCalibrationStep, heldOut: false
            ))
            hint = "Rest your chin or cheek on your hand"
        case .swipe:
            takesWanted = Self.swipesPerStep
            capture = nil
            swipeFrames = []
            hint = "Swipe \(Self.swipesPerStep) times"
        }
    }

    /// Why a captured hand cannot be the asked pose: two or more fingers doing the opposite
    /// of what the pose asks, on most frames. A finger that is merely unclear is fine; that is
    /// what the calibration is there to fix.
    private static func mismatch(of hands: [Hand], with pose: Pose) -> String? {
        let wanted = PoseClassifier.fingers(in: pose)
        let wrong = hands.filter { hand in
            let states = PoseClassifier.fingerStates(hand)
            let opposite = wanted.filter { finger, state in
                guard finger != .thumb, let seen = states[finger] else { return false }
                return (state == .extended && seen == .curled) || (state == .curled && seen == .extended)
            }
            return opposite.count >= 2
        }
        guard !hands.isEmpty, Double(wrong.count) / Double(hands.count) > 0.5 else { return nil }
        return "That did not look like \(Trigger(pose: pose).title.lowercased()). Try again."
    }

    private func followSwipes(_ frame: HandFrame) {
        guard case .calibrate(let index) = stage, case .swipe(let direction) = CalibrationPlan.steps[index].kind,
              takesDone < Self.swipesPerStep else { return }
        swipeFrames.append(frame)
        let peaks = SwipeMeasure.peaks(in: swipeFrames).filter { $0.direction == direction }.map(\.travel)
        guard peaks.count != takesDone else { return }
        takesDone = min(peaks.count, Self.swipesPerStep)
        takeProgress = Double(takesDone) / Double(Self.swipesPerStep)
        guard takesDone >= Self.swipesPerStep else {
            hint = "\(Self.swipesPerStep - takesDone) more"
            return
        }
        hint = "Got it"
        samples.append(CalibrationSample(step: CalibrationPlan.steps[index], hands: [], palmToFace: [], swipePeaks: peaks))
        advance { [weak self] in self?.advanceCalibration(from: index) }
    }

    private func advanceCalibration(from index: Int) {
        guard index + 1 < CalibrationPlan.steps.count else {
            let outcome = Calibrator.calibrate(samples)
            calibration = outcome.calibration
            report = outcome.report
            enter(.result)
            return
        }
        enter(.calibrate(index + 1))
    }

    /// Whether anything was captured, so there is a calibration worth using.
    var hasCalibration: Bool { !samples.isEmpty }
}
