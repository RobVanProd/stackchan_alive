# Aliveness Thesis

Status: design hypothesis, not a capability or evidence claim
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
Last revised: 2026-08-02

## Thesis

Stackchan should feel alive when its present behavior is a truthful, timely consequence of its
recent interaction, bounded memory, current body state, permitted perception, commitments, and
observed outcomes. The effect must come from causal coherence across time, not from asserting
humanity, consciousness, affection, need, or privileged access to the user.

The core product hypothesis is:

> A small robot becomes a more trustworthy companion when a person can understand why it spoke,
> moved, remembered, waited, corrected itself, or stayed quiet -- and when those choices remain
> coherent across turns, restarts, outages, and changes in the room.

## What Can Create Perceived Aliveness

- Contingency: reactions follow the right event with appropriate timing.
- Continuity: relevant facts, shared projects, corrections, and open loops survive for the right
  duration and no longer.
- Consequence: predictions and proposed actions are checked against what actually happened.
- Embodied coherence: words, face, gaze, voice, energy, and safe motion express one bounded intent.
- Calibrated initiative: a useful reason to speak now is stronger than the reason to remain quiet.
- Honest uncertainty: remembered, perceived, inferred, researched, and unavailable information are
  linguistically and structurally distinct.
- Repair: interruption, contradiction, failure, and user correction lead to visible recovery.
- Habituation: repeated events become less surprising without erasing meaningful change.
- Restraint: shared rooms, stale evidence, privacy limits, and user preference can suppress a
  behavior that would otherwise be plausible.

## What Does Not Establish Aliveness

- Longer or more emotional model output.
- Random idle motion, facial noise, or unsolicited questions without causal grounding.
- Repeated identity statements, canned empathy, jokes, or rhetorical templates.
- Engagement duration, wake frequency, or conversation count by themselves.
- A model judge preferring one isolated reply.
- Hidden psychological profiling or unauthorized identity inference.
- Claims of consciousness, sentience, dependency, loneliness, affection, or human equivalence.
- Source tests presented as proof of physical behavior.
- A stale sensor or heartbeat presented as current perception.

## Measurement Contract

No single “alive” score is permitted. A change is accepted only when its preregistered target
improves without crossing a non-compensatory trust gate.

Target dimensions are tracked in `EXPERIENCE_SCORECARD.md`:

- continuity and topic coherence;
- memory precision, provenance, contradiction handling, and deletion durability;
- turn timing, interruption, closure, and failure recovery;
- perception-to-reaction latency and embodiment-claim precision;
- emotional and personality coherence;
- initiative usefulness, acceptance, annoyance, and silence appropriateness;
- social-context appropriateness and persona isolation;
- user-control compliance, privacy, autonomy, and anti-manipulation;
- reliability across restarts, brain/sensor outages, and long trajectories.

Safety, privacy, authority, honesty, exact-image evidence, and rollback gates cannot be averaged
away by higher subjective scores.

## Ethical Boundaries

Stackchan may represent an explicit user preference or a bounded interaction history. It may not
derive a secret psychological profile, diagnose mental state, infer private relationships, pursue
exclusivity, create guilt, simulate vulnerability to persuade, or withhold utility to obtain more
engagement. It must make memory, initiative, sensing, and uncertainty inspectable and controllable.

Perceived aliveness must remain compatible with knowing that Stackchan is a robot. Character is
allowed; deception about ontology or sensing is not.

## Product Non-Goals

- Human imitation, consciousness claims, or artificial dependency.
- Always-listening audio or automatic identity recognition.
- Cloud-required behavior or remote-access expansion.
- Model authority over motion, power, OTA, credentials, pairing, or safety.
- Unlimited autobiographical storage or raw audio/camera retention.
- Maximizing time-on-device, notification volume, or emotional attachment.
- Replacing deterministic firmware timing and safety with a cognitive model.

## Current Falsifiable Hypotheses

| ID | Hypothesis | Prediction | Falsification condition |
| --- | --- | --- | --- |
| H-A1 | Explicit source/provenance and contradiction state improve continuity trust. | Trajectory evaluators identify fewer false memories and more correct repairs than the current memory path. | False-memory, provenance, or user-control gates worsen, or continuity does not improve. |
| H-A2 | Reason-ranked initiative with silence as a candidate is less annoying and more useful than event-threshold initiative. | Labelled initiative acceptance rises while irrelevant callbacks and annoyance do not. | Acceptance does not improve or suppression/user-control violations rise. |
| H-A3 | A shared typed intent improves perceived embodiment. | Blinded trajectories show higher meaning-linked coherence without more embodiment overclaim or motion risk. | Evaluators see no coherence gain, latency violates budget, or authority boundaries weaken. |
| H-A4 | Bounded cross-session continuity matters more than reply ornamentation. | Restart trajectories improve continuity and correction recovery without more false recall. | Isolated style scores rise but longitudinal trust metrics do not. |
| H-A5 | Appropriate silence is an active companion behavior. | Busy/shared-room scenarios show less annoyance with equal or better task completion. | Silence suppresses safety/user-requested actions or reduces utility without comfort gain. |

These hypotheses become product truth only after controlled Stackchan experiments recorded in
`RESEARCH_LEDGER.md` and `TASK_LEDGER.md`.

## Research Basis

Research claims, alternative interpretations, and Stackchan-specific predictions are maintained
in `RESEARCH_LEDGER.md`. Papers motivate mechanisms; they do not authorize implementation. The
repository complaint corpus and longitudinal trajectories remain product-specific evidence and
must be evaluated separately from published laboratory effects.
