# Architecture

WristFlow is split in two so that a second platform only has to redo the outer half.

```
camera ──► landmarks ──► gesture engine ──► trigger ──► binding ──► action
              │
              └────────► gaze tracker ───► display ──► focus
   platform   │            core (shared)              │   platform
```

## Core (`Sources/WristFlowCore`)

Foundation only. It never sees an image: its input is landmark frames, its output is decisions.

| File | Role |
| --- | --- |
| `Landmarks.swift` | `Hand` (21 joints), `HandFrame`, `FaceFrame`, and the coordinate conventions |
| `PoseClassifier.swift` | Which fingers are extended, and which pose that makes |
| `GestureEngine.swift` | Hold timing, swipes, and the rules that keep ordinary hand movement from firing |
| `GazeClassifier.swift` | Which display a face measurement points at, learned from a calibration |
| `GazeTracker.swift` | Dwell and hysteresis on top of the classifier |
| `Bindings.swift` | `Trigger`, `ActionKind`, `ActionBinding`, `AppConfig` (the settings file) |
| `Platform.swift` | The three protocols a platform implements |
| `Recording.swift` | Landmark recordings, used as test fixtures |

### Conventions

- Points are in the user's mirror view: moving a hand to your right increases `x`, raising it
  increases `y`.
- Both axes are measured in image heights, so shapes are not stretched by the aspect ratio.
- Hand measurements are divided by the palm size, so nothing depends on the distance to the
  camera.
- Time comes from the frames, never from frame counts: the camera runs slower when idle.

### How a gesture is decided

1. A hand is usable when it is confident and close enough.
2. A pose (open palm, back of the hand, fist, OK, thumbs up, one to four fingers) fires once
   when it is held still for the hold time. It cannot fire again until the hand changes shape or leaves. Palm and back are
   told apart by which way round the knuckles run, given which hand it is.
3. A swipe is a flick of the open hand: the fingertips travel far in about a tenth of a
   second while the wrist stays roughly in place. Speed is what tells it from the slower way
   back, which is ignored, and the pivot is what tells it from a hand being carried somewhere.
   A hand that has just come into view, and diagonal or downward movements, fire nothing.
4. A swipe uses up the open hand for that appearance, so the hand that swiped does not also
   count as a palm or a back being shown.
5. Poses are read only from a hand held out towards the camera. Such a hand is nearer the
   camera than the face, so its palm looks at least as large as the face is tall; a hand back
   by the head (biting a nail, propping up a chin) looks smaller and is ignored. Where the
   hand is in the image does not decide it: people hold gestures up in front of their face.
   Swipes are not affected. This needs the platform to pass face frames to the engine while
   a hand is in view.

`Fixtures/` holds landmark recordings of real gestures with the triggers they must produce;
the tests replay them, and a port of the core to another language should too.

### How gaze is decided

Calibration records the face while the user looks at a few points on each display. At run
time the nearest calibrated samples vote for a display; a new display wins only after it has
been named steadily for the dwell time, and measurements unlike anything calibrated (looking
away, down at the desk) are ignored.

## macOS shell (`Sources/WristFlowMac`)

| File | Role |
| --- | --- |
| `CameraSource.swift` | `AVCaptureSession`, low resolution, adaptive frame rate |
| `VisionLandmarker.swift` | Apple Vision hand pose and face landmarks, converted to core types |
| `Actions.swift` | Key events, Wispr Flow deep links, Accessibility permission |
| `DisplayFocus.swift` | Moves the pointer and activates the front window on a display |
| `AppModel.swift` | Configuration, live status, and the pipeline that ties everything together |
| `App.swift`, `MenuContentView.swift`, `SettingsView.swift` | Menu bar item and settings |
| `PreviewView.swift` | Camera with the hand skeleton and what is being read |
| `GazeCalibration.swift` | The calibration run across displays |
| `HUD.swift` | On-screen confirmation of a recognised gesture |
| `Recorder.swift`, `Replay.swift`, `Snapshot.swift` | Development tools |

## Privacy

Camera frames are processed in memory and dropped. Nothing is stored or sent. Landmark
recordings are made only by the `--record-landmarks` development tool and contain joint
positions, not images.
