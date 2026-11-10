# WristFlow

Control your computer with hand gestures in front of the camera, and let focus follow the
display you are looking at.

WristFlow lives in the menu bar. macOS first; the gesture and gaze logic is kept free of
Apple frameworks so a Windows version can be built on the same core
(see [docs/WINDOWS.md](docs/WINDOWS.md)).

**Status:** early. Swipes, palm against back of the hand, and the hand at the face are tuned on
real recordings (see `Fixtures/`); fist, OK and gaze are still set on synthetic data.

## Gestures

| Gesture | How | Default action |
| --- | --- | --- |
| Open palm | Show the palm of your open hand and hold it still | Wispr Flow: start / stop dictation |
| Back of the hand | Show the back of your open hand and hold it still | Wispr Flow: discard dictation |
| Fist | Show a closed fist and hold it still | Previous tab |
| OK sign | Thumb and index touching, other fingers up, hold | Next tab |
| Swipe left / right | With your hand open, flick it sideways from the wrist | Move one desktop left / right |
| Swipe up | With your hand open, flick it upwards from the wrist | Show all windows |

A pose counts only when held still for a moment (0.4 s by default), and a swipe only when it
is a quick flick, so ordinary hand movement does not fire anything. The slower way back after
a swipe is ignored, so you can swipe several times in a row. A hand touching your face (biting
a nail, chin on the hand, scratching) is not read as a pose. Every gesture can be bound to
any action, including a shortcut you record, in Settings.

## Gaze focus

With two or more displays, WristFlow can move the pointer and the active window to the display
you look at. Calibrate once per setup from the menu (**Calibrate Gaze…**): look at a few dots
on each display. Focus never moves while you are typing or using the mouse, and you can turn
it off from the menu.

## Build and run

Requires macOS 15 or later on Apple silicon, and the Swift toolchain (Xcode or the Command
Line Tools).

```sh
./scripts/build-app.sh --run       # build and launch build/WristFlow.app
./scripts/build-app.sh --install   # build, copy to ~/Applications and launch
swift test                         # core tests
```

On first launch macOS asks for:

- **Camera**, to see your hands and face.
- **Accessibility**, to press shortcuts and switch windows for you.

Without an Apple Development certificate the app is signed ad hoc and macOS asks for these
again after every rebuild.

## Privacy

Camera images are processed on your Mac, in memory, and dropped. Nothing is stored or sent.
The camera is off while WristFlow is disabled and while the screen is locked or asleep.

## Development

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the code is laid out.
- **Camera Preview…** in the menu shows the hand skeleton and what is being read.
- `WristFlow --record-landmarks <file> [seconds]` records joint positions (not images) to a
  file; `WristFlow --replay <file>` runs a recording through the gesture engine and prints
  what fires. Launch through `open build/WristFlow.app --args …` so the camera permission of
  the app applies.
- `WristFlow --snapshot <folder>` renders the views to PNG files without turning the camera on.
- `WRISTFLOW_CORE_ONLY=1 swift test` builds and tests the portable core on its own.
