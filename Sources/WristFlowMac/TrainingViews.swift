import SwiftUI
import WristFlowCore

/// The window of a guided flow: where the user is in it, what to do now, and the way on.
struct TrainingView: View {
    let session: TrainingSession
    let model: AppModel
    let onClose: () -> Void

    private static let width: CGFloat = 640
    /// Height of the part that changes from stage to stage, so the window never resizes.
    private static let stageHeight: CGFloat = 520

    static func title(of flow: TrainingSession.Flow) -> String {
        switch flow {
        case .newGesture: "New Gesture"
        case .rerecord(let gesture): "Record “\(gesture.name)” Again"
        case .calibration: "Calibrate to Your Hands"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stage
                .frame(width: Self.width, height: Self.stageHeight)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onChange(of: session.isFinished) { _, finished in
            if finished { onClose() }
        }
    }

    // MARK: Header

    private var header: some View {
        let progress = session.progress
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title(of: session.flow))
                    .font(.headline)
                Spacer()
                Text("Step \(progress.step) of \(progress.of)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(progress.step), total: Double(progress.of))
                .accessibilityLabel("Progress through the steps")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        switch session.stage {
        case .intro:
            if session.flow == .calibration {
                CalibrationIntro()
            } else {
                GestureIntro(session: session)
            }
        case .shape(let hand):
            CaptureStage(
                session: session, model: model,
                title: "Show the gesture with your \(hand == .left ? "left" : "right") hand",
                detail: "Hold it still until the ring fills. Do it \(TrainingSession.shapeTakes) times, lowering your hand in between, a little differently each time: nearer, farther, slightly turned."
            )
        case .movement:
            CaptureStage(
                session: session, model: model,
                title: "Make the movement",
                detail: "Hold your hand still, make the movement, and stop: all inside the picture, so keep it small, about two hands across. Do it \(TrainingSession.movementTakes) times the same way, starting from the same hand shape, for example one finger."
            )
        case .calibrate:
            CaptureStage(
                session: session, model: model,
                title: session.calibrationStep?.title ?? "",
                detail: session.calibrationStep?.instruction ?? ""
            )
        case .review:
            ReviewStage(session: session, model: model)
        case .tryIt:
            TrialStage(session: session, model: model)
        case .assign:
            AssignStage(session: session, model: model)
        case .result:
            CalibrationResult(session: session)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if session.stage != .assign {
                Button(session.stage == .result ? "Discard" : "Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch session.stage {
            case .intro:
                Button("Start") { session.begin() }
                    .keyboardShortcut(.defaultAction)
            case .shape, .calibrate:
                if session.canSkip {
                    Button(session.flow == .calibration ? "Skip This Step" : "Skip This Hand") { session.skip() }
                }
            case .movement:
                Button("Undo Last Take") { session.undoTake() }
                    .disabled(!session.canUndoTake)
            case .review:
                Button("Record Again") { session.recordAgain() }
                Button("Try It") { session.startTrial() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.candidate == nil)
            case .tryIt:
                Button("Record Again") { session.recordAgain() }
                Button(session.trialPassed ? "Save" : "Save Anyway") { session.save() }
                    .keyboardShortcut(.defaultAction)
            case .assign:
                Button("Done") { session.finish() }
                    .keyboardShortcut(.defaultAction)
            case .result:
                Button("Use This Calibration") { session.applyCalibration() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.hasCalibration)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Intro

private struct GestureIntro: View {
    @Bindable var session: TrainingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .newGesture = session.flow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.headline)
                    TextField("Name", text: $session.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("What kind of gesture?")
                        .font(.headline)
                    KindCard(
                        symbol: "hand.raised", title: "A hand shape",
                        detail: "A pose you hold still, like the built-in ones: horns, a pinky up, an L, thumbs down. The most reliable kind.",
                        selected: session.kind == .shape
                    ) { session.kind = .shape }
                    KindCard(
                        symbol: "scribble.variable", title: "A movement",
                        detail: "A path your hand draws between two moments of holding still, inside the picture: a circle, a zigzag. Less reliable than a shape.",
                        selected: session.kind == .movement
                    ) { session.kind = .movement }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How it goes")
                    .font(.headline)
                ForEach(steps, id: \.self) { step in
                    Label(step, systemImage: "circle.fill")
                        .labelStyle(BulletLabel())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var steps: [String] {
        let record = session.kind == .shape
            ? "You show the shape \(TrainingSession.shapeTakes) times with your right hand, then with your left. Either hand can be skipped."
            : "You make the movement \(TrainingSession.movementTakes) times."
        return [
            record,
            "WristFlow tells you if it could be mistaken for another gesture.",
            "You try it for real before it is saved.",
            "Your other gestures do nothing while this window is open.",
        ]
    }
}

private struct KindCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                // Down to the middle of the first line of text.
                .padding(.top, 7)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CalibrationIntro: View {
    private static let points = [
        "WristFlow was tuned on one person's hands. This fits it to yours.",
        "You show each built-in gesture with your right hand and then your left, rest a hand against your face, and swipe a few times. About two minutes.",
        "Any step can be skipped; what you skip keeps its standard setting.",
        "Nothing changes until you accept the result at the end, and you can go back to the standard settings whenever you like.",
        "Your gestures do nothing while this window is open.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hand.raised.fingers.spread")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Fit WristFlow to your hands")
                .font(.title2.weight(.semibold))
            ForEach(Self.points, id: \.self) { point in
                Label(point, systemImage: "circle.fill")
                    .labelStyle(BulletLabel())
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Capture

/// The camera with what to do under it: used for every stage that records the hand.
private struct CaptureStage: View {
    let session: TrainingSession
    let model: AppModel
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            VideoArea(model: model, trail: session.trail)
                .frame(width: 640, height: 400)
                .overlay(alignment: .topTrailing) {
                    ProgressRing(value: session.takeProgress)
                        .padding(14)
                }
                .overlay(alignment: .bottom) {
                    if !session.hint.isEmpty {
                        Text(session.hint)
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 14)
                            .accessibilityLabel("Hint: \(session.hint)")
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    TakeDots(done: session.takesDone, wanted: session.takesWanted)
                }
                if let rejection = session.rejection {
                    Label(rejection, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Fills as a take is collected; green with a tick when it is complete.
private struct ProgressRing: View {
    let value: Double

    var body: some View {
        let done = value >= 1
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(done ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 46, height: 46)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .accessibilityElement()
        .accessibilityLabel("Take progress")
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}

/// One dot per take asked for, filled as they are done.
private struct TakeDots: View {
    let done: Int
    let wanted: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(wanted, 0), id: \.self) { index in
                Circle()
                    .fill(index < done ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(wanted) done")
        .opacity(wanted > 1 ? 1 : 0)
    }
}

// MARK: - Review, trial, assign

private struct ReviewStage: View {
    let session: TrainingSession
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            if let candidate = session.candidate {
                GestureIcon(trigger: candidate.trigger, library: preview(candidate), size: 120)
                    .frame(width: 160, height: 160)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                Text(candidate.name)
                    .font(.title2.weight(.semibold))
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.findings) { finding in
                    Label {
                        Text(finding.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: finding.level == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.level == .good ? .green : .orange)
                    }
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The library as it would be with the candidate in it, so its picture can be drawn.
    private func preview(_ candidate: CustomGesture) -> GestureLibrary {
        var library = model.library
        library.customGestures.removeAll { $0.id == candidate.id }
        library.customGestures.append(candidate)
        return library
    }
}

private struct TrialStage: View {
    let session: TrainingSession
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VideoArea(model: model)
                .frame(width: 640, height: 400)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.trialPassed ? "It works" : "Now make the gesture")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    TakeDots(done: min(session.recognitions, TrainingSession.recognitionsWanted), wanted: TrainingSession.recognitionsWanted)
                }
                if let misread = session.misread {
                    Label("That was read as \(misread).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var detail: String {
        if session.trialPassed {
            return "Recognised \(session.recognitions) times. Try your other gestures too if you like: nothing fires here. Save when you are happy."
        }
        return "Make it \(TrainingSession.recognitionsWanted) times, lowering your hand in between, the way you would in daily use. Each dot is one recognition."
    }
}

private struct AssignStage: View {
    let session: TrainingSession
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Saved")
                .font(.title2.weight(.semibold))
            if let candidate = session.candidate {
                Text("Choose what “\(candidate.name)” does. You can change it later in Settings, under My Gestures.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                ActionEditor(model: model, trigger: candidate.trigger)
                    .frame(maxWidth: 480)
                    .padding(14)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Calibration result

private struct CalibrationResult: View {
    let session: TrainingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.hasCalibration ? "Here is what changed" : "Nothing was captured")
                .font(.title2.weight(.semibold))
            Text("How often each gesture you showed is read correctly: with the standard settings, and with yours.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let report = session.report {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            GridRow {
                                Text("Gesture")
                                Text("Standard")
                                Text("Yours")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            ForEach(report.lines, id: \.step.id) { line in
                                GridRow {
                                    Text(line.step.title)
                                    Text(Self.percent(line.before))
                                        .monospacedDigit()
                                    Text(Self.percent(line.after))
                                        .monospacedDigit()
                                        .fontWeight(line.after > line.before + 0.005 ? .semibold : .regular)
                                        .foregroundStyle(line.after > line.before + 0.005 ? .green : .primary)
                                }
                            }
                        }
                        ForEach(report.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
