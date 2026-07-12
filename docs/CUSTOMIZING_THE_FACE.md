# Customizing The Procedural Face

Stackchan: Alive draws its face from geometry every frame. There are no required face
sprites, image sequences, or expression bitmaps. A custom face can therefore keep the
same blink, gaze, emotion, speech-mouth, and reduced-motion behavior while changing how
the character looks.

There are two supported customization levels:

1. **Persona tuning** changes expression values in YAML. This is the recommended path for
   most creators and does not require C++ changes.
2. **Engine skinning** changes the procedural eye, mouth, color, pose, or transition code.
   Use this only when the character needs a visibly different face language.

Start with persona tuning. Move into engine skinning only after the persona passes its
validator and looks coherent in every runtime mode.

## How A Frame Is Built

The face pipeline is layered in this order:

1. `ExpressionMapper` turns emotion and mode into a `FaceTargets` baseline.
2. `FaceAnimator` chooses the mode pose, then adds blink, saccade, breathing, transition,
   event, and speech-viseme layers.
3. `ProceduralFace` converts the composed targets into `EyeGeometry` and `MouthGeometry`.
4. `DisplayAdapter` draws those shapes into the display canvas and flushes the dirty area.

This separation is important. A creator describes a target expression; the shared engine
keeps it alive and moves toward it smoothly. Do not animate values from a persona YAML file
or add a second display loop.

## Quick Start: Tune A Persona Face

Create a persona by copying the validated reference pack:

```powershell
.\tools\create_persona_pack.cmd nova -Name "Stackchan Nova" -Author "Your Name"
```

Edit:

```text
personas/nova/expressions.yaml
personas/nova/behavior.yaml
```

Then validate and build with that persona selected:

```powershell
.\tools\verify_persona_pack.cmd nova --Json
$env:STACKCHAN_PERSONA = "nova"
pio test -e native_logic
pio run -e stackchan
```

The PlatformIO pre-build step validates the pack and generates:

```text
.pio/build/<environment>/generated/PersonaExpressions.hpp
.pio/build/<environment>/generated/PersonaBehavior.hpp
```

These files are generated output. Edit the YAML source, not the generated headers.

## Expression Sections

The reference file is `personas/spark/expressions.yaml`. Keep its required sections while
tuning values:

| Section | What it expresses | Current runtime connection |
| --- | --- | --- |
| `neutral` | Resting eye openness, eye smile, and mouth smile | Direct baseline used by `ExpressionMapper` |
| `listen` | Focus metadata and small pitch attention bias | Pitch bias is wired; `focus` is validated/generated but not yet consumed, and the detailed listen pose remains in `FaceAnimator` |
| `think` | Upward/downward thought gaze and small yaw bias | Pupil Y and motion bias |
| `drowsy` | Fatigue-heavy lids, squint, brow, mouth, and face drop | Blended in as fatigue rises |
| `yawn` | Timed eye, squint, mouth, and pitch deltas | Layered by `IdleLife` |
| `surprise` | Alert reflex target | Authored target; advanced mode/event styling is still implemented in C++ |
| `picked_up` | Lift/startle target | Authored target; pickup behavior remains foundation-controlled |
| `shaken` | Safety/startle target | Authored target; safety behavior remains foundation-controlled |
| `put_down` | Relief/settling target | Authored target; event behavior remains foundation-controlled |
| `tilted` | Orientation mismatch target | Authored target; IMU behavior remains foundation-controlled |
| `sound_direction` | Eyes-first sound orientation and yaw bias | Yaw bias is wired; detailed face reflex remains foundation-controlled |
| `loud_noise` | Short alert/startle target | Authored target; event behavior remains foundation-controlled |

The distinction in the last column is deliberate. The generator accepts the authored
targets so the pack format has one expression language, but only the explicitly listed
runtime connections should be expected to alter the current production face without a C++
engine change.

## Face Values

The common generated pose fields use normalized values unless marked as pixels:

| YAML field | Generated range | Visual effect |
| --- | ---: | --- |
| `eye_open` | `0.02` to `1.20` | `0` is closed; about `0.85` is a relaxed open eye; values above `1` read as startled |
| `eye_smile` | `0.00` to `1.00` | Raises the lower lid and softens the eye |
| `squint` | `0.00` to `1.00` | Narrows eye width and strengthens the brow read |
| `brow_tilt` | `-1.00` to `1.00` | Tilts the procedural brow; test both eyes because the tilt is mirrored |
| `mouth_smile` | `-1.00` to `1.00` | Negative curves down, positive curves up |
| `mouth_open` | `0.00` to `1.00` | Opens the filled speech/yawn mouth |
| `pupil_x`, `pupil_y` | `-1.00` to `1.00` | Moves pupils inside the current eye geometry |
| `pupil_scale` | `0.50` to `1.50` | Changes pupil size; large values feel alert or affectionate |
| `face_x`, `face_y` | `-12.00` to `12.00` px | Offsets the whole face before autonomic motion is added |

Some advanced `FaceTargets` fields are currently C++ only: `eyeWidthScale`, lid tilts,
mouth width and corner offsets, and independent corner cuts for each eye. Those controls
are described in the engine-skinning section.

Tune one visual idea at a time. For example, this is a calm, friendly baseline with a
clearer fatigue pose:

```yaml
neutral:
  eye_open: 0.82
  eye_smile: 0.22
  mouth_smile: 0.24
listen:
  focus: 0.94
  pitch_bias_deg: -2.0
think:
  pupil_y: -0.14
  yaw_bias_deg: 10.0
drowsy:
  perceptual_purpose: eyelids become heavy while the smile settles
  eye_open: 0.52
  squint: 0.12
  brow_tilt: -0.05
  mouth_smile: 0.08
  face_y: 1.2
```

Keep the descriptive `perceptual_purpose` notes. They do not change firmware, but they make
future edits easier to judge: every number should support the same readable intent.

## Idle Life And Transitions

Use `behavior.yaml` for the rhythm around the face:

- `idle_life.breathing_hz` controls the breathing cycle rate.
- `idle_life.breathing_px` controls whole-face vertical breathing amplitude.
- `idle_life.fidget_min_ms` and `fidget_max_ms` bound occasional micro-expressions.
- `idle_life.reduced_motion_scale` preserves character while reducing autonomic movement.

Blink timing, saccade timing, mode poses, and transition gestures are shared engine behavior
in `src/face/FaceAnimator.cpp`. Keeping them in one animator prevents a persona from
creating rapid flashing, constant motion, or a second timing system that competes with the
bridge and microphone tasks.

For advanced transition changes, edit one transition at a time and preserve these rules:

- Mode changes must ease into a target; do not snap the complete pose in one frame.
- A blink may accent a transition, but repeated full-eye flashes are not an expression.
- Pupils should normally lead a whole-face or servo orientation response.
- Reduced-motion mode must remain recognizable and complete.
- Speech onset suppresses a scheduled blink briefly so eye contact and mouth motion stay
  readable.

## Speech Mouth And Visemes

Speech animation is driven by a normalized audio envelope plus four bounded visemes:
`Neutral`, `Ah`, `Oh`, and `Ee`. `FaceAnimator::applyReactive` changes mouth opening, width,
smile, and corners for each viseme, then smooths those values. A persona does not generate
per-frame mouth commands.

When skinning the mouth:

- Keep `mouth_open = 0` visually closed with no filled mouth body.
- Keep all four visemes distinct at small display size.
- Preserve a clean return to neutral after the final audio frame.
- Never perform audio decoding, allocation, or file I/O in the face renderer.
- Validate a complete reply, not only a short test word, so truncation and stale-open-mouth
  failures are visible.

## Preview Before Flashing

Install the preview dependencies and generate the reference animation suite:

```powershell
python -m pip install -r requirements-preview.txt
python tools/render_preview.py
.\tools\verify_preview_media.cmd
```

The output includes the idle animation, expression sheet, mode-transition filmstrips, and
speech-reactive preview under `docs/media/` and `artifacts/face/`.

The current preview script is a renderer/animation reference, not a parser for a selected
persona pack. Use it to inspect advanced geometry or transition edits. For YAML-only persona
tuning, the generated `PersonaExpressions.hpp`, native tests, and a display-only device run
are the authoritative checks.

## Advanced Engine Skinning

These files define the deeper visual language:

- `src/persona/StateMatrix.hpp`: all `FaceTargets` channels.
- `src/face/FaceAnimator.cpp`: mode poses, smoothing, transitions, blink, gaze, fidgets,
  and speech visemes.
- `src/face/ProceduralFace.cpp`: base eye positions and sizes plus mouth placement.
- `src/face/EyeGeometry.hpp` and `MouthGeometry.hpp`: renderer-facing geometry contracts.
- `src/io/DisplayAdapter.cpp`: colors and the actual procedural drawing operations.
- `tools/render_preview.py`: host-side visual reference that should track renderer changes.

Useful advanced controls include:

- `eyeWidthScale` for wide or narrow eye silhouettes.
- `upperLidTilt` and `lowerLidTilt` for asymmetrical lid lines.
- `leftCorners` and `rightCorners` for cutting individual eye corners.
- `mouthWidthDelta` for compact versus broad mouth shapes.
- `mouthCornerL` and `mouthCornerR` for asymmetrical mouth attitude.
- `faceX` and `faceY` for subtle whole-face staging.

Change the matching host preview whenever procedural drawing changes. A preview that looks
right while the firmware renderer differs is not a valid customization workflow.

## Performance And Stability Invariants

Face customization must preserve the runtime that keeps the physical robot stable:

- Only the face task may draw to the display.
- Do not add a second renderer, display task, or direct display writes from bridge, sensor,
  camera, audio, or persona code.
- Keep drawing bounded and allocation-free per frame.
- Keep the dirty-region renderer and one display wait/flush per composed frame.
- Preserve the normal 33,333 microsecond frame budget telemetry.
- The strict acceptance ceiling is `display_window_max_frame_us <= 50000` during a combined
  system run. A custom face that exceeds it is not release-ready.
- Do not treat one good screenshot as validation. Watch for flicker, black frames, stale
  regions, frozen eyes, missed mouth closure, and bridge/audio starvation.

Run the face and architecture checks after an advanced edit:

```powershell
.\tools\verify_face_phase_a.cmd
.\tools\verify_face_phase_b.cmd
.\tools\verify_face_phase_c.cmd
.\tools\verify_face_phase_d.cmd
.\tools\verify_face_phase_e.cmd
pio test -e native_logic
pio run -e stackchan
```

## Device Acceptance Checklist

Use display-only firmware before combining the custom face with wake, Wi-Fi, camera, audio,
or servos. Confirm:

- The face boots without a white, black, or partially drawn flash.
- Idle breathing and saccades feel alive without looking restless.
- Blinks close and reopen cleanly with no full-screen flicker.
- Listen, think, speak, react, sleep, and error remain visually distinct.
- Pupils stay inside the eye silhouette at their extreme positions.
- Every viseme reads clearly and the mouth closes after speech.
- Reduced-motion mode still communicates every state.
- The face remains smooth during a complete bridge reply.
- Frame telemetry remains under the strict 50 ms ceiling in the final combined soak.

Archive the selected persona folder, generated firmware hash, preview artifacts, native test
result, and physical acceptance notes together. That makes a custom face reproducible instead
of leaving it as an untracked set of numbers.
