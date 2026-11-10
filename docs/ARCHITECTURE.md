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
| `PoseClassifier.swift` | Which fingers are extended, and which pose that makes, judged by a `PoseProfile` of thresholds |
| `GestureEngine.swift` | Hold timing, swipes, two-hand combinations, and the rules that keep ordinary hand movement from firing |
| `ShapeMatcher.swift` | Hand shapes the user recorded: how one is stored and when a hand matches it |
| `MovementMatcher.swift` | Movements the user recorded: cutting a hand's motion into movements and matching them |
| `Calibration.swift` | Fitting the thresholds to one person from a guided session |
| `PoseCapture.swift` | Collecting steady takes of a hand, for recording and calibrating |
| `GestureLibrary.swift` | What a user taught: recorded gestures, combinations, calibration (the per-user file) |
| `GazeClassifier.swift` | Which display a face measurement points at, learned from a calibration |
| `GazeTracker.swift` | Dwell and hysteresis on top of the classifier |
| `Bindings.swift` | `Pose`, `Trigger`, `ActionKind`, `ActionBinding`, `AppConfig` (the settings file) |
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
   second while the wrist stays roughly in place. The pivot is what tells it from a hand being
   carried somewhere. After a swipe, a flick the opposite way is the hand going back and is
   ignored, until the fingertips are back where they started or a few seconds have passed;
   an unhurried way back is too slow to be a flick in the first place.
   A hand that has just come into view, and diagonal or downward movements, fire nothing.
4. A swipe uses up the open hand for that appearance, so the hand that swiped does not also
   count as a palm or a back being shown.
5. Poses are read only from a hand held out towards the camera. Such a hand is nearer the
   camera than the face, so its palm looks at least as large as the face is tall; a hand back
   by the head (biting a nail, propping up a chin) looks smaller and is ignored. Where the
   hand is in the image does not decide it: people hold gestures up in front of their face.
   Swipes are not affected. This needs the platform to pass face frames to the engine while
   a hand is in view.

6. A second hand in view is followed only for its pose. When both hands hold, at the same
   time, the two poses of a combination the user set up, the combination fires once and
   neither pose fires alone. A pose that belongs to a combination waits a little longer before
   firing alone, and waits while a second hand is still coming into view, so the other hand
   has time to come up. Which hand is left and which right comes from the detector, or from
   their places when it names both the same.
7. Poses are read with the user's own thresholds once they have calibrated
   (`GestureLibrary.profile`, `GestureLibrary.tuned`).

`Fixtures/` holds landmark recordings of real gestures with the triggers they must produce;
the tests replay them, and a port of the core to another language should too.

### Gestures the user records

A **shape** is stored as a few examples of the hand in its own frame: wrist at the origin,
scaled by the palm size, turned upright, left hands mirrored. Two shapes are compared by the
finger that differs most (the mean displacement of its joints), so one finger out of place
decides. Measured on recordings, the same shape is 0.03 to 0.25 palm sizes from itself across
takes, sessions and hands, and different shapes 0.39 and more, so each template gets a
threshold between 0.25 and 0.32 from how much its own takes differ. The tilt the shape was
shown at and the side facing the camera are kept too (thumbs down is not thumbs up). A hand
that matches a recorded shape is read as that shape, otherwise as a built-in pose; from there
on it is a pose like any other. A shape recorded over a built-in pose remembers which, so one
showing of the hand cannot fire both.

A **movement** is what the palm centre does between two rests: hand still, move, hand still.
The path is resampled, centred and scaled by its own size, and compared point by point with
the recorded takes; direction matters. The hand shape at the starting rest is part of the
gesture when it was the same in every take. A movement is read on the main hand only, and not
when a swipe was made during it.

### Calibration

A guided session collects each built-in pose with each hand, a hand resting against the face
and a few swipes. For every finger the thresholds are placed in the gap between that person's
curled and extended values; the thumb, the pinch, the depth rule and the swipe speed are
fitted the same way. Each value stays inside fixed bounds, and the fitted set is used only if
the person's own captured frames read at least as well with it as with the factory set.

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
| `Actions.swift` | Key events, Wispr Flow deep links, opening things, running Shortcuts, Accessibility permission |
| `DisplayFocus.swift` | Moves the pointer and activates the front window on a display |
| `AppModel.swift` | Configuration, live status, and the pipeline that ties everything together |
| `App.swift`, `MenuContentView.swift` | Menu bar item |
| `SettingsView.swift`, `Settings*.swift` | The settings window, one tab per file or two |
| `TrainingSession.swift`, `TrainingViews.swift`, `TrainingController.swift` | The guided flows: recording a gesture, trying it, calibrating |
| `GestureIcon.swift` | Pictures a trigger; a recorded gesture by its own recording |
| `PreviewView.swift` | Camera with the hand skeleton and what is being read |
| `GazeCalibration.swift` | The calibration run across displays |
| `HUD.swift` | On-screen confirmation of a recognised gesture |
| `Recorder.swift`, `Replay.swift`, `Snapshot.swift` | Development tools |

## Privacy

Camera frames are processed in memory and dropped. No image is stored and nothing is sent.
Gestures the user records and their calibration are stored as joint positions in
`~/Library/Application Support/WristFlow/gestures.json`, one file per macOS account. Landmark
recordings are made only by the `--record-landmarks` development tool and likewise contain
joint positions, not images.
