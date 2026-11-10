# WristFlow

Control your computer with hand gestures in front of the camera, and let focus follow the
display you are looking at.

WristFlow lives in the menu bar. macOS first; the gesture and gaze logic is kept free of
Apple frameworks so a Windows version can be built on the same core
(see [docs/WINDOWS.md](docs/WINDOWS.md)).

**Status:** early. The built-in hand gestures except the OK sign, and two-hand combinations,
are checked on real recordings of one person (see `Fixtures/`); a calibration fits the
gestures to anyone else. The OK sign, gaze and recorded movements are still set on synthetic
data.

## Gestures

| Gesture | How | Default action |
| --- | --- | --- |
| Open palm | Show the palm of your open hand and hold it still | Wispr Flow: start / stop dictation |
| Back of hand | Show the back of your open hand and hold it still | Wispr Flow: discard dictation |
| Fist | Show a closed fist and hold it still | Previous tab |
| OK sign | Thumb and index touching, other fingers up, hold | Next tab |
| Thumbs up | Fist with the thumb pointing up, hold | Press Return (Enter) |
| One, two, three, four fingers | Hold up that many fingers, starting from the index (five is the open palm) | None: yours to assign |
| Swipe left / right | With your hand open, flick it sideways from the wrist | Move one desktop left / right |
| Swipe up | With your hand open, flick it upwards from the wrist | Show all windows |

A pose counts only when held still for a moment (0.4 s by default), and a swipe only when it
is a quick flick, so ordinary hand movement does not fire anything. After a swipe, the hand
going back the other way is not a swipe, whether it goes at once or a moment later, so you
can swipe several times in a row. Poses are read from a hand held
out towards the camera; a hand back by your head (biting a nail, chin on the hand, scratching)
is not read as a pose. Every gesture can be bound to any action in Settings: the built-in
ones, a shortcut you record, an app, file or link to open, or one of your Shortcuts to run.

### Your own actions

In Settings, under **Actions**, you put together actions of your own: a name and one or more
steps done in order, each a key combination you record (any key with any mix of Control,
Option, Shift and Command) or any other action. Once made, an action appears in the list of
every gesture, recorded gesture and combination. Pressing keys for you needs the
Accessibility permission.

### Combinations

A combination is one pose on each hand, held still at the same time: a fist on one hand and
one finger on the other, say. There are none to begin with; add them in Settings and choose
what each does. While both hands are up only the combination fires. A pose that is part of a
combination and also does something alone takes a moment longer to fire alone, which gives
the other hand time to come up.

### Your own gestures

In Settings, under **My Gestures**, **New Gesture…** records a gesture of your own in about a
minute:

- **A hand shape** you hold still, like the built-in poses: horns, a pinky up, an L, thumbs
  down. You show it three times with each hand (either hand can be skipped).
- **A movement** your hand draws between two moments of holding still: a circle, a zigzag.
  You make it four times. The hand shape it starts from is part of the gesture, which keeps
  everyday hand movement from setting it off. The whole movement has to stay inside the
  camera's picture, so keep it small (about two hands across); one that starts or ends out
  of view, or stops at a corner on the way, is not read. Movements are less reliable than
  shapes.

Before saving, WristFlow says whether the new gesture could be mistaken for another one and
lets you try it for real. A recorded shape can be one hand of a combination.

### Calibration

The built-in gestures were tuned on one person's hands. **Calibrate…** (Settings,
**Calibration**) asks you for each of them with each hand, for a hand resting against your
face, and for a few swipes, and fits the thresholds to you. It shows how well each gesture is
read before and after, changes nothing until you accept, and can be undone at any time.

Everything you record belongs to your account on the Mac: it is stored in
`~/Library/Application Support/WristFlow`, next to your settings, and never leaves it.

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

Camera images are processed on your Mac, in memory, and dropped. No image is stored and
nothing is sent. Gestures you record and a calibration are stored on your Mac as joint
positions, not pictures. The camera is off while WristFlow is disabled and while the screen
is locked or asleep.

## Development

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the code is laid out.
- **Camera Preview…** in the menu shows the hand skeleton and what is being read.
- `WristFlow --record-landmarks <file> [seconds]` records joint positions (not images) to a
  file; `WristFlow --replay <file>` runs a recording through the gesture engine and prints
  what fires (`--library <gestures.json>` adds recorded gestures, combinations and a
  calibration). Launch through `open build/WristFlow.app --args …` so the camera permission
  of the app applies.
- `WristFlow --snapshot <folder>` renders the views to PNG files without turning the camera on.
- `WRISTFLOW_HOME=<folder>` makes the app keep its files there instead of in Application
  Support, for trying things without touching your own settings.
- `WRISTFLOW_CORE_ONLY=1 swift test` builds and tests the portable core on its own.
