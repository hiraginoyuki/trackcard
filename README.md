<img src="assets/icon.svg" width="64" height="64" alt="">

# Trackcard

Trackcard is a macOS menu-bar app that shows where your fingers touch the
trackpad. Each contact appears as an oval on a small card with the trackpad's
proportions.

The preview is meant to stay beside your work. Move it to a screen corner,
resize it, lower its opacity, or tuck it into the edge when you need the space.
With two trackpads, it keeps the active one in front and shows both when you
use them together.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain, such as the one included
with Xcode. The package has no external dependencies.

```sh
./scripts/build-app.sh
open "build/Trackcard.app"
```

The script creates a locally signed app named **Trackcard**. Click its
menu-bar icon to show or hide the preview, choose a display, or quit.

## Use the preview

The preview starts above the Dock at the bottom-left of the screen, at 50% of
the trackpad's physical size. Move the pointer over the preview to use its
controls:

| Input | Action |
| --- | --- |
| Drag or swipe with two fingers | Move the preview; release to snap to a screen corner. |
| Pinch | Resize the preview. |
| Rotate two fingers | Change opacity. |
| Right-click | Open the Scale and Opacity sliders. |

During a size or opacity adjustment, the current value appears at the pointer
and haptic ticks mark percentage steps.

Drag the preview past the left or right edge to tuck it away. Click the
remaining tab or swipe inward over it to bring the preview back. You can also
choose **Bring Back Preview** from the menu.

Use **Preview Size** to choose **Compact (50%)** or
**Match Physical Size (100%)**. Physical size is estimated from trackpad and
display measurements; use **Smaller** or **Larger** to adjust it. Choose a
finish from each trackpad's submenu to match its color. Size, opacity, finish,
and corner placement are saved.

### Two trackpads

Trackcard displays up to two trackpads. Their cards normally form a stack;
touching the rear trackpad brings its card forward. Using both spreads the
cards side by side. They return to a stack after you settle back into using
one.

## Record and compare gestures

The recording tools help develop gesture recognition: capture what you did,
replay it, and inspect the evidence behind a decision. In these tools,
**Tilt** means a two-finger rotation.

### Record and replay

Choose **Record Gestures…** from the menu bar, then:

1. Choose the gesture you intend to perform and press **Shift-Space** or click
   **Start Recording**.
2. Perform the gesture. Press **Space** to stop and save the recording.
3. Select a saved session or contact group to replay it. Playback loops;
   **Space** stops it and resumes the selection when pressed again.

**Category** holds your intended gesture label; **Recognized** rows show the
detector's result. Edit labels on sessions, groups, or individual contacts as
you review them. Use **Ready** and **Exclude** to mark sessions for later
analysis.

During recording, contacts remain visible and the preview can still be moved.
Size and opacity adjustments pause until recording ends.

### Compare recognition

Choose **Compare Classifiers…** to see how different recognition rules respond
to the same live input or recording. Each chart shows the evidence over time
and marks when its classifier makes a decision. **Current** identifies the
rules used by the preview.

Hover over a chart to inspect a moment. The rules panel shows the measurements
and thresholds that support or hold back each gesture. **Freeze** holds the
visible graphs while input continues.

### Target experiments

For repeatable gesture samples, open **Radial Experiment** in the recorder.
Choose a trial set and click **Start Block**. Follow the prompts to set your
finger spacing, lift, land, and reach the target. The recorder saves each trial
for comparison.

## Compatibility and local data

Trackcard reads built-in trackpads and external Magic Trackpads through
macOS's private MultitouchSupport framework. Compatibility depends on the
hardware and macOS version. If contacts fail to appear, check the menu for a
capture error and run:

```sh
swift run Trackcard --diagnose
```

Touch the trackpad during the three-second check. The command reports
connected devices and frame/contact counts, then exits.

Contact processing stays on your Mac. Starting a recording saves contact and
preview movement data in
`~/Library/Application Support/Trackcard/Gesture Recordings/`. Choose
**Show Recordings in Finder** in the recorder to open that folder. Gesture
labels and review marks are stored separately from the original sensor logs.

## Development

Use `swift run Trackcard` for a development run and `swift test` to run
the tests. `swift run Trackcard --demo` shows two simulated trackpads for
checking card swaps and layout.

Planned work lives in [ROADMAP.md](ROADMAP.md).

Created in [T3 Code](https://t3.codes).
