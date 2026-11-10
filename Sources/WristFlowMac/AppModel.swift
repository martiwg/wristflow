import AppKit
import AVFoundation
import Observation
import ServiceManagement
import WristFlowCore

/// The app's single source of truth: configuration, live status and the camera pipeline.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum CameraState: Equatable {
        case stopped
        case starting
        case running
        /// The user said no to camera access.
        case denied
        case failed(String)
    }

    enum GazeHealth: Equatable {
        /// Only one display is connected, so there is nothing to choose between.
        case singleDisplay
        case notCalibrated
        /// Calibrated, but for a different set of displays or another camera.
        case displaysChanged
        case ready(accuracy: Double)
    }

    struct TriggerReport: Equatable {
        let trigger: Trigger
        let binding: ActionBinding
        let date: Date
    }

    // MARK: State the views read

    private(set) var config: AppConfig
    /// What this user taught WristFlow: recorded gestures, combinations, calibration.
    private(set) var library: GestureLibrary
    private(set) var camera = CameraState.stopped
    private(set) var cameras: [CameraDevice] = []
    private(set) var displays: [DisplayInfo] = []
    private(set) var accessibilityGranted = false
    private(set) var launchAtLogin = false
    /// What the gesture engine is reading right now.
    private(set) var gesture = GestureEngine().state
    /// Hands and face of the latest frame. Only kept up to date while `previewVisible`.
    private(set) var hands: [Hand] = []
    private(set) var face: FaceFrame?
    private(set) var lastTrigger: TriggerReport?
    /// True for a moment after a gesture fired, so the menu bar icon can blink.
    private(set) var isFlashing = false
    private(set) var gazeHealth = GazeHealth.singleDisplay
    /// Id of the display the user is looking at, once gaze is calibrated.
    private(set) var lookingAt: String?

    /// Set by the preview window while it is open.
    var previewVisible = false {
        didSet { refreshFaceTracking() }
    }

    /// While set, face measurements go here instead of moving focus (gaze calibration, and
    /// the flows that record gestures).
    var faceSink: ((FaceFrame) -> Void)? {
        didSet { refreshFaceTracking() }
    }

    /// While set, hand frames go here instead of to the gesture engine, so nothing fires
    /// while the user is being asked to show gestures (recording one, calibrating).
    var handSink: ((HandFrame) -> Void)? {
        didSet {
            engine.reset()
            gesture = engine.state
        }
    }

    // MARK: Internals

    @ObservationIgnored private var landmarker: VisionLandmarker?
    @ObservationIgnored private var engine = GestureEngine()
    @ObservationIgnored private var tracker: GazeTracker?
    @ObservationIgnored private var calibrations: [GazeCalibration] = []
    @ObservationIgnored private let performer = MacActionPerformer()
    @ObservationIgnored private let displayFocus = MacDisplayFocus()
    @ObservationIgnored private var housekeeping: Timer?
    /// True while the screen is locked or asleep; the camera stays off.
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var started = false

    private init() {
        config = Storage.loadConfig()
        library = Storage.loadLibrary()
        configureEngine()
    }

    /// Hands the engine the user's settings, gestures and calibration.
    private func configureEngine() {
        var gestures = GestureConfig()
        gestures.holdTime = config.holdTime
        engine.config = library.tuned(gestures)
        engine.library = library
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        calibrations = Storage.loadCalibrations()
        cameras = CameraSource.devices()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        configureLoginItemOnFirstRun()
        refreshPermissions()
        observeSystem()
        rebuildGaze()
        refreshPipeline()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        refreshPermissions()
        let current = CameraSource.devices()
        if current != cameras {
            cameras = current
            // The chosen camera may have been unplugged, or have come back.
            restartPipeline()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pause: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let resume: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pause {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(true) }
            }
        }
        for name in resume {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(false) }
            }
        }
        // Locking the screen does not put it to sleep straight away, and nobody is gesturing
        // at a locked Mac.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(true) }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(false) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildGaze() }
        }
    }

    private func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        refreshPipeline()
    }

    // MARK: Camera pipeline

    private func refreshPipeline() {
        guard config.enabled, !suspended else {
            stopPipeline()
            return
        }
        guard landmarker == nil else { return }

        switch CameraSource.authorization {
        case .authorized:
            startPipeline()
        case .notDetermined:
            camera = .starting
            Task {
                _ = await CameraSource.requestAccess()
                self.refreshPipeline()
            }
        default:
            camera = .denied
        }
    }

    private func startPipeline() {
        let source = VisionLandmarker(cameraID: config.cameraID)
        source.onHands = { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.handle(frame) } }
        }
        source.onFace = { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.handle(frame) } }
        }
        do {
            try source.start()
            landmarker = source
            camera = .running
            refreshFaceTracking()
        } catch {
            camera = .failed(error.localizedDescription)
        }
    }

    private func stopPipeline() {
        landmarker?.stop()
        landmarker = nil
        engine.reset()
        tracker?.reset()
        gesture = engine.state
        hands = []
        face = nil
        if camera != .denied { camera = .stopped }
    }

    private func restartPipeline() {
        stopPipeline()
        refreshPipeline()
    }

    /// The capture session, for the preview window. Nil while the camera is off.
    var captureSession: AVCaptureSession? { landmarker?.session }

    /// Reading the face costs energy, so it runs at its full rate only when something uses it.
    private func refreshFaceTracking() {
        let gazeActive = tracker != nil && config.gazeFocusEnabled
        landmarker?.faceEnabled = gazeActive || previewVisible || faceSink != nil
    }

    private func handle(_ frame: HandFrame) {
        guard landmarker != nil else { return }
        if previewVisible || handSink != nil { hands = frame.hands }
        if let handSink {
            handSink(frame)
            return
        }
        let trigger = engine.ingest(frame)
        if engine.state != gesture { gesture = engine.state }
        if let trigger { fire(trigger) }
    }

    private func handle(_ frame: FaceFrame) {
        guard landmarker != nil else { return }
        engine.ingest(frame)
        if previewVisible || handSink != nil { face = frame }
        if let faceSink {
            faceSink(frame)
            return
        }
        guard config.gazeFocusEnabled, tracker != nil else { return }
        if let display = tracker?.ingest(frame) {
            lookingAt = display
            displayFocus.focus(display: display)
        }
    }

    private func fire(_ trigger: Trigger) {
        let binding = config.binding(for: trigger)
        lastTrigger = TriggerReport(trigger: trigger, binding: binding, date: Date())
        flash()
        if config.showsHUD { HUD.shared.show(trigger: trigger, binding: binding, library: library) }
        if config.playsSound { NSSound(named: "Tink")?.play() }
        performer.perform(binding)
    }

    private func flash() {
        isFlashing = true
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            self.isFlashing = false
        }
    }

    // MARK: Settings

    func setEnabled(_ value: Bool) {
        config.enabled = value
        save()
        refreshPipeline()
    }

    func setBinding(_ binding: ActionBinding, for trigger: Trigger) {
        config.setBinding(binding, for: trigger)
        save()
    }

    func setHoldTime(_ value: Double) {
        config.holdTime = value
        configureEngine()
        save()
    }

    func setGazeFocusEnabled(_ value: Bool) {
        config.gazeFocusEnabled = value
        save()
        tracker?.reset()
        refreshFaceTracking()
    }

    func setGazeDwell(_ value: Double) {
        config.gazeDwell = value
        tracker?.config.dwellTime = value
        save()
    }

    func setCamera(id: String?) {
        guard config.cameraID != id else { return }
        config.cameraID = id
        save()
        restartPipeline()
        rebuildGaze()
    }

    func setShowsHUD(_ value: Bool) {
        config.showsHUD = value
        save()
    }

    func setPlaysSound(_ value: Bool) {
        config.playsSound = value
        save()
    }

    private func save() {
        Storage.save(config)
    }

    /// The camera in use: the chosen one, or the default when none was chosen or it is gone.
    var activeCamera: CameraDevice? {
        cameras.first { $0.id == config.cameraID } ?? CameraSource.defaultDevice()
    }

    func isAvailable(_ kind: ActionKind) -> Bool {
        performer.isAvailable(kind)
    }

    /// Runs what a trigger is bound to, as if the gesture had been made (Settings' Test button).
    func perform(_ trigger: Trigger) {
        performer.perform(config.binding(for: trigger))
    }

    // MARK: The user's own gestures

    /// The name to show for a trigger, including the ones the user made.
    func title(for trigger: Trigger) -> String {
        library.title(for: trigger)
    }

    /// Adds a recorded gesture, or replaces the one with the same id (recording it again).
    func saveGesture(_ gesture: CustomGesture, binding: ActionBinding? = nil) {
        var changed = library
        if let index = changed.customGestures.firstIndex(where: { $0.id == gesture.id }) {
            changed.customGestures[index] = gesture
        } else {
            changed.customGestures.append(gesture)
        }
        if let binding { config.setBinding(binding, for: gesture.trigger) }
        update(changed)
    }

    func renameGesture(id: String, to name: String) {
        guard let index = library.customGestures.firstIndex(where: { $0.id == id }) else { return }
        var changed = library
        changed.customGestures[index].name = name
        update(changed)
    }

    /// Deletes a recorded gesture together with the combinations that used it.
    func deleteGesture(id: String) {
        var changed = library
        for trigger in changed.removeGesture(id) { config.removeBinding(for: trigger) }
        update(changed)
    }

    /// Adds a combination, or changes the one with the same id. Returns false when the same
    /// hands already make another combination.
    @discardableResult
    func saveCombination(_ combination: Combination) -> Bool {
        guard library.clash(for: combination) == nil else { return false }
        var changed = library
        if let index = changed.combinations.firstIndex(where: { $0.id == combination.id }) {
            changed.combinations[index] = combination
        } else {
            changed.combinations.append(combination)
        }
        update(changed)
        return true
    }

    func deleteCombination(id: String) {
        var changed = library
        for trigger in changed.removeCombination(id) { config.removeBinding(for: trigger) }
        update(changed)
    }

    /// Stores what a calibration run measured, or goes back to the factory values with nil.
    func setCalibration(_ calibration: PersonalCalibration?) {
        var changed = library
        changed.calibration = calibration
        update(changed)
    }

    private func update(_ changed: GestureLibrary) {
        library = changed
        Storage.save(library)
        save()
        configureEngine()
    }

    // MARK: Gaze

    /// Picks the calibration recorded for the displays and camera in use now, if there is one.
    private func rebuildGaze() {
        displays = displayFocus.displays
        tracker = nil
        lookingAt = nil
        defer { refreshFaceTracking() }

        guard displays.count > 1 else {
            gazeHealth = .singleDisplay
            return
        }
        let ids = displays.map(\.id).sorted()
        let matching = calibrations.last { $0.matches(displays: ids, cameraID: activeCamera?.id) }
        guard let matching, let classifier = GazeClassifier(samples: matching.samples) else {
            gazeHealth = calibrations.isEmpty ? .notCalibrated : .displaysChanged
            return
        }
        var gazeConfig = GazeConfig()
        gazeConfig.dwellTime = config.gazeDwell
        tracker = GazeTracker(classifier: classifier, config: gazeConfig)
        gazeHealth = .ready(accuracy: classifier.evaluate())
    }

    /// Stores a finished calibration for the current displays and camera, replacing an earlier
    /// one for the same setup. Calibrations for other setups (another desk) are kept.
    func saveGazeCalibration(samples: [GazeSample]) {
        let ids = displayFocus.displays.map(\.id).sorted()
        let cameraID = activeCamera?.id
        calibrations.removeAll { $0.matches(displays: ids, cameraID: cameraID) }
        calibrations.append(GazeCalibration(displays: ids, cameraID: cameraID, createdAt: Date(), samples: samples))
        Storage.save(calibrations)
        rebuildGaze()
    }

    func displayName(_ id: String?) -> String? {
        displays.first { $0.id == id }?.name
    }

    // MARK: Permissions and login item

    func refreshPermissions() {
        accessibilityGranted = Accessibility.isGranted
        if camera == .denied, CameraSource.authorization == .authorized { refreshPipeline() }
    }

    func requestAccessibility() {
        Accessibility.request()
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("WristFlow: could not change the login item: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Starting at login is the default, but only for an installed copy: registering a build
    /// folder would leave a login item pointing at a path that disappears.
    private func configureLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.contains("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    // MARK: Menu bar

    var menuBarSymbol: String {
        if !config.enabled { return "hand.raised.slash" }
        return isFlashing || gesture.pose != nil ? "hand.raised.fill" : "hand.raised"
    }
}

/// Files in `~/Library/Application Support/WristFlow`: one set per macOS account, so each
/// person has their own settings, recorded gestures and calibration.
enum Storage {
    private static var folder: URL {
        // For development: keeps a trial run away from the real files.
        if let override = ProcessInfo.processInfo.environment["WRISTFLOW_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WristFlow", isDirectory: true)
    }

    private static var configURL: URL { folder.appendingPathComponent("config.json") }
    private static var gazeURL: URL { folder.appendingPathComponent("gaze.json") }
    private static var libraryURL: URL { folder.appendingPathComponent("gestures.json") }

    static func loadConfig() -> AppConfig {
        load(AppConfig.self, from: configURL) ?? AppConfig()
    }

    static func save(_ config: AppConfig) {
        write(config, to: configURL)
    }

    /// The user's recordings are not something to lose quietly: a file that is there but
    /// cannot be read is set aside under another name before an empty library takes its place.
    static func loadLibrary() -> GestureLibrary {
        if let library = load(GestureLibrary.self, from: libraryURL) { return library }
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = folder.appendingPathComponent("gestures.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: libraryURL, to: aside)
            NSLog("WristFlow: could not read gestures.json; kept it as %@", aside.lastPathComponent)
        }
        return GestureLibrary()
    }

    static func save(_ library: GestureLibrary) {
        write(library, to: libraryURL)
    }

    static func loadCalibrations() -> [GazeCalibration] {
        load([GazeCalibration].self, from: gazeURL) ?? []
    }

    static func save(_ calibrations: [GazeCalibration]) {
        write(calibrations, to: gazeURL)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func write(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("WristFlow: could not save %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }
}
