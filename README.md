<img src="assets/icon.svg" width="64" height="64" alt="">

# Trackcard

Trackcard is a macOS menu-bar app that shows where your fingers touch the
trackpad. Each contact appears as an oval on a small card with the trackpad's
proportions, so you can see a gesture take shape as you make it.

The preview is meant to sit beside your work without asking for attention:
move it, resize it, lower its opacity, or tuck it against a screen edge.

## Build and run

Trackcard needs macOS 14 or newer and a Swift 6 toolchain, such as the one in
Xcode. The package has no external dependencies.

```sh
./scripts/build-app.sh
open "build/Trackcard.app"
```

The script builds a locally signed app named **Trackcard**. Click its menu-bar
icon to show or hide the preview, pick a display, or quit.

## Use the preview

The preview starts above the Dock at the bottom-left of the screen, at half
the trackpad's physical size. Move the pointer over it to use its controls:

| Input | Action |
| --- | --- |
| Drag or swipe with two fingers | Move the preview; release to snap to a screen corner. |
| Pinch | Resize the preview. |
| Rotate two fingers | Change opacity. |
| Right-click | Open the Scale and Opacity sliders. |

While you adjust size or opacity, the current value appears at the pointer and
haptic ticks mark percentage steps. At minimum size, turning while pinching
inward slightly favors an available opacity adjustment. Pinch outward to
enlarge the preview.

Drag the preview past either side of the screen to tuck it away. Bring it
back by clicking the tab, swiping inward over it, or choosing **Bring Back
Preview** from the menu.

The **Preview Size** submenu offers **Compact (50%)** and **Match Physical
Size (100%)**, estimated from trackpad and display measurements; nudge it with
**Smaller** or **Larger** if it looks off. Each trackpad's submenu lets you
pick a finish to match its color. Size, opacity, finish, and corner placement
are saved between launches.

### Two trackpads

Trackcard displays up to two trackpads. Their cards normally form a stack, and
touching the rear trackpad brings its card forward. Using both at once spreads
the cards side by side; they return to a stack after you settle back into one.

## Record and compare gestures

The recording tools support gesture-recognition work: capture what you did,
replay it, and inspect the evidence behind each decision. In these tools,
**Tilt** means a two-finger rotation.

### Record and replay

Choose **Record Gestures…** from the menu bar, then:

1. Choose the gesture you intend to perform and press **Shift-Space**, or
   click **Start Recording**.
2. Perform the gesture. Press **Space** to stop and save the recording.
3. Select a saved session or contact group to replay it. Playback loops;
   **Space** stops it, and pressing it again resumes the selection.

**Category** holds your intended gesture label; **Recognized** rows show the
detector's result. Edit labels on sessions, groups, or individual contacts as
you review them, and use **Ready** and **Exclude** to mark sessions for later
analysis. Contacts stay visible and the preview stays movable while you
record; size and opacity adjustments pause until recording ends.

### Compare recognition

Choose **Compare Classifiers…** to see how different recognition rules respond
to the same live input or recording. Each chart shows the evidence over time
and marks when its classifier decides; **Current** identifies the rules the
preview uses. Hover over a chart to inspect a moment, and the rules panel
shows the measurements and thresholds behind each gesture. **Freeze** holds
the visible graphs while input continues.

### Target experiments

For repeatable gesture samples, open **Radial Experiment** in the recorder.
Choose a trial set and click **Start Block**, then follow the prompts to set
your finger spacing, lift, land, and reach the target. The recorder saves each
trial for comparison.

## Compatibility and local data

Trackcard reads built-in trackpads and external Magic Trackpads through
macOS's private MultitouchSupport framework, so compatibility depends on your
hardware and macOS version. If contacts fail to appear, check the menu for a
capture error and run:

```sh
swift run Trackcard --diagnose
```

Touch the trackpad during the three-second check; the command reports
connected devices and frame and contact counts, then exits.

Contact processing stays on your Mac. Recordings save contact and preview
movement data to `~/Library/Application Support/Trackcard/Gesture Recordings/`;
choose **Show Recordings in Finder** in the recorder to open that folder.
Gesture labels and review marks are stored separately from the original sensor
logs.

## Development

Use `swift run Trackcard` for a development run and `swift test` for the core
tests. `./scripts/test-bridge.sh` checks capture buffering and concurrent
delivery without hardware, and `swift run Trackcard --demo` shows two
simulated trackpads for checking card swaps and layout.

For delivery diagnostics, set `TRACKCARD_DELIVERY_TRACE` to a local JSONL file
when launching the executable. It records callback, recognition, and visual
submission timestamps along with target and displayed scale and opacity.
Trace writes can affect timing, so leave tracing off when assessing ordinary
use.

Planned work lives in [ROADMAP.md](ROADMAP.md).

Created in [T3 Code](https://t3.codes).
