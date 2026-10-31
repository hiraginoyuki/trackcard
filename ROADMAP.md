# Roadmap

## Hardware validation

- Validate ordered recognition delivery on both trackpads with bursty input,
  rapid gesture changes, native clicks, UI stalls and sleep/wake. Compare source
  commitment, host processing and visible response before changing classifier rules.

- Collect labeled swipe, pinch, and tilt attempts with Gesture Recorder; compare overlapping raw/native/recognized intervals before revising the heuristic.

- Check live contact delivery, placement, orientation, release, and hover on the built-in trackpad.
- Connect a second physical trackpad and check independent streams, swaps, the 0.5-second shared-use window, and the 2-second return to stacking.
- Check external-device disconnect/reconnect, sleep/wake, scaled displays, Reduce Motion, and bottom-left placement with Stage Manager enabled.
- Measure physical preview size and refine finish detection for trackpads whose IORegistry metadata does not contain explicit RGB values.

## Click ripples

Begin with ripples from every active contact when a physical click is confirmed. Research reliable click detection and contact association before adding finger-specific ripples. A contact path ID is a gesture-local identifier, not an anatomical finger identity; force values alone have not been established as a system click signal.

## Possible follow-ups

- Validate the V2 lift-and-land radial sets with physical trials, including the 100 ms second-contact window and lower abrupt-retry thresholds. Keep deprecated V1 pre-contact results separate from V2 landing results. Collect all gesture categories in each recording block to reduce category/session confounding, compare landing prompts and both finger spans, and evaluate onset discrimination separately from target precision. Revisit target tolerances and pace prompts using the recorded error, overshoot, and settling times.

- Placement that responds to the actual Stage Manager thumbnail area.
- Display selection that survives relaunch and monitor reconnection.
- Compatibility checks for future private-framework ABI changes.

- Validate the relative-motion classifier and its ambiguity latency with new physical sessions on both trackpads. Check the separate resized clone at 50% opacity, its fading with Tilt evidence, and its immediate Pinch window promotion and interruptible opacity, confidence rumble, classification snap, and 1%/10%/landmark haptic hierarchy, especially cursor restoration after interruption. Use held-out sessions with all gesture categories and actual landed geometry; existing block-level calibration is descriptive and uses small control samples. Compare all sixteen variants on fresh sessions, including source-clock timer completion, relative turns during shared movement, the radial-motion boundary, developing-turn recovery, independent classifiers, decisive 8 ms paths, firing paths, and live suppression reasons, especially brief pinches with incidental rotation, slow radial setup before a turn, and the position-path-curvature and thumb-axis derivative variants. Compare early decisions separately from the amount of path travel needed for a reliable curve; coarse external ellipse angles must not substitute for positional evidence. Keep the explicitly selected real-world tuning sessions separate from held-out evaluation. Validate reversible press feedback on firm stationary holds, press-like gesture starts, both trackpads, and physical right clicks. Check pointer restoration and same-pair recovery after a pressure cue; retain native clicks as the authoritative veto. Measure the coordinated Swipe path on fresh sessions, including slow and asymmetric starts.

- Collect fresh mixed-category sessions to validate the s6472/s6663 radial-motion boundary across devices and postures. The fallback change corrects ten recorded Pinch-to-Tilt errors without delaying those commitments, while the four earliest overlapping starts remain unresolved. Keep those cases labeled and visible; a session-specific thumb-axis split does not justify a global posture gate. Preserve visually flagged structural outliers and evaluate them separately from valid two-contact inputs.

- Physically check the minimum-size opacity preference with both hands and turn directions, at full, intermediate, and minimum opacity. Include outward Pinch, an inward Pinch that reverses, and native right-clicks. Compare the balanced base thresholds with the same thresholds at minimum size; retain pair-start action context in new recordings and keep historical recordings context-free. Evaluate the calibrated Tilt/Pinch balance on fresh mixed-category sessions.

- Validate relative turns during shared movement on fresh mixed-category sessions. The 504-group tuning replay corrects twelve errors, including ten in s6751, and makes 46 previously correct decisions earlier without delaying another correct decision. Preserve asymmetric Swipe controls and the held-pointer prior. Use fresh recordings to investigate the remaining radial and shared-motion starts before adding a general delay or a posture gate.
