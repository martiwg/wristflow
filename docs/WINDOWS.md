# Adding the Windows version

Nothing here exists yet. This is the map for whoever builds it.

## What is already shared

`Sources/WristFlowCore` has no Apple dependency and is built and tested on Windows in CI. It
contains everything that decides what the user meant:

- the landmark types every platform fills in (`Landmarks.swift`),
- pose classification and the gesture engine, including two-hand combinations,
- recorded shapes and movements (`ShapeMatcher.swift`, `MovementMatcher.swift`),
- the calibration maths and the capture state machine the guided flows run on
  (`Calibration.swift`, `PoseCapture.swift`),
- the gaze classifier and tracker,
- triggers, actions, bindings and the two file formats: settings (`Bindings.swift`) and what
  the user taught (`GestureLibrary.swift`),
- the recording format used by the fixtures in `Fixtures/`.

## What a Windows shell has to provide

Three protocols, declared in `Platform.swift`:

| Protocol | macOS implementation | On Windows |
| --- | --- | --- |
| `LandmarkSource` | AVFoundation camera + Apple Vision | Media Foundation camera + MediaPipe Hand Landmarker and Face Landmarker |
| `ActionPerforming` | `CGEvent`, deep links | `SendInput`, protocol activation |
| `DisplayFocusing` | `CGWarpMouseCursorPosition`, Accessibility API | `SetCursorPos`, `EnumWindows`, `SetForegroundWindow` |

Plus the shell itself: tray icon, settings window, camera preview, the guided flows for
recording a gesture and calibrating (the macOS ones are `Training*.swift`; their logic is in
the core), start at sign-in.

### Landmarks

MediaPipe's 21 hand landmarks are in the same order as the `Joint` enum, so filling a `Hand`
is a direct copy. Mind the conventions documented in `Landmarks.swift`:

- points are in the user's mirror view (`x` grows to the user's right, `y` grows upwards),
- both axes are measured in image heights (`x` goes up to the aspect ratio, not to 1),
- head angles are in radians, from the user's side.

MediaPipe's image coordinates have `y` pointing down and are not mirrored, so both axes need
converting.

Two things beyond the joints matter to the engine: `Hand.handedness` (palm and back of the hand
are told apart with it; check that MediaPipe's label means the user's own left and right for
an unmirrored image), and face frames, which have to keep coming while a hand is in view so a
hand back by the head can be told from one held out in a gesture. The engine compares palm
size with `FaceFrame.size`, so that has to be the height of a face box like Apple Vision's
(roughly chin to forehead); check the ratio on a recording when using another detector.

### Actions

`ActionKind` names what should happen, not how. On Windows the natural mappings are:

| `ActionKind` | Windows |
| --- | --- |
| `spaceLeft` / `spaceRight` | Ctrl + Win + Left / Right (virtual desktops) |
| `missionControl` | Win + Tab (Task View) |
| `previousTab` / `nextTab` | Ctrl + Shift + Tab / Ctrl + Tab |
| `pressReturn` | Enter |
| `wisprToggle` | Wispr Flow's deep link, if the Windows app registers one; otherwise its hotkey |
| `wisprCancel` | Wispr Flow's dismiss key (Escape by default), only while a microphone is recording |
| `shortcut` | the recorded `KeyCombo` (key codes are per platform, so shortcuts are recorded again on Windows) |
| `open` | `ShellExecute` on the binding's `target` (a path or a link) |
| `custom` | nothing to do: `AppConfig.steps(of:)` breaks the user's own actions into the steps above |
| `runShortcut` | no direct counterpart; report it as unavailable, or map it to a script the user names |

## Two ways to use the core

1. **Link it.** Swift builds on Windows; the shell can be written in Swift, or in C# / C++
   calling the core through a small C interface.
2. **Port it.** If the shell is written in another language, reimplement the core there and
   run the recordings in `Fixtures/` through it: each fixture lists the triggers it must
   produce, so both implementations stay in agreement.

The configuration file is the same JSON on both systems (`AppConfig`), and so is the file of
what the user taught (`GestureLibrary`): both live in the user's application data folder, one
set per account. Recorded shapes and a calibration depend on the hand detector, so a library
recorded with Apple Vision should be recorded again under MediaPipe rather than copied over.
