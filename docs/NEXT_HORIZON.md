# Next Horizon: Post-Release Feature Analysis

Written against `main` at the v0.2.0-rc1 public release (Apache-2.0, secret-free BYOM
package), with the private paired lead in its interaction-aware eight-hour soak. This
document does three things: states where the project actually is against its original
purpose, identifies which of the original goals are now within one step of done, and lays
out the next set of features and code upgrades in priority order.

Companions to this doc: [CONVERSATION_V2_ROADMAP.md](CONVERSATION_V2_ROADMAP.md) and
[HARDWARE_FEATURE_ROADMAP.md](HARDWARE_FEATURE_ROADMAP.md) already specify two of the
tracks below in detail; this document sequences them against everything else rather than
repeating them.

## 1. Where the project is

The purpose has held constant since the first pathway doc: **a character OS for a
tabletop robot that feels genuinely alive — local-first, safety-gated, with personalities
as shareable data.** Against that purpose, the current release candidate delivers, on
real hardware:

- **Presence:** smooth procedural face under a strict frame gate; blink, breathing,
  saccades, gaze life; ambient character movement; body RGB state cues.
- **Senses:** on-device wake phrase, mic capture, body three-zone touch, IMU
  pickup/orientation/shake with forensic-grade accounting, paired camera capture with
  host-side YuNet face detection and bounded horizontal following.
- **Conversation:** wake → bounded utterance → Whisper STT → Gemma 4 under the Character
  Lock → DirectML RVC voice → chunked speaker downlink with synchronized mouth motion.
  Deterministic local answers (time/date/name) that bypass the model. Bounded, allowlisted
  embodiment snapshots so Gemma knows it was just picked up.
- **Memory:** versioned, bounded, privacy-filtered host memory with atomic persistence,
  relevant-fact recall, and explicit forgetting — the CHARACTER_LOCK.md rules, enforced.
- **Body:** power-coordinated servos, seed-varied procedural nod/shake gestures, PMIC/
  thermal/blackout forensics, motion disabled at boot.
- **Ops:** authenticated rollback-safe LAN OTA with health confirmation, Wi-Fi
  provisioning store, camera pairing, exact-image soak evidence culture.
- **Character platform:** Spark and Glow persona packs, creator guides, pack verifier
  with author provenance, real-model benchmark and red-team gates.
- **Companion:** PC and Android apps with talk panel, pairing QR flow, Wi-Fi bootstrap,
  staged on-phone Gemma (LiteRT), and evidence contracts pending physical proof.

Measured against the original "Johnny Alive definition of done" (the five-step visitor
test in JOHNNY_ALIVE_PATHWAY.md): steps 2-4 — greet it, talk to it, move while talking,
pick it up and have it *mention* it — are functionally there. Step 1 (notices you
entering, before any sound) and step 5 (searches, sighs, gives up, sleeps on schedule)
are the remaining experiential gaps, and they map exactly to the unused proximity sensor
and the person-loss behaviors below.

## 2. Next features, in three tracks

### Track A — Close the release (first, and short)

Everything here is already tracked in FIRST_DEPLOY_STATUS.md / PRODUCTION_READINESS.md;
listed only for sequencing: terminal eight-hour interaction-aware soak pass, final
package regeneration bound to the terminal docs commit, companion owner-failover
evidence, and the voice-provenance decision (see 3.4). Nothing in Tracks B/C should
preempt an engineer-day that closes Track A — an officially released repo with an
unclosed headline gate is a reputation cost that compounds.

### Track B — Aliveness upgrades (the experiential jumps)

Ordered by felt-realism-per-effort:

**B1. Conversation v2: the reply window.** Already fully speced in
CONVERSATION_V2_ROADMAP.md. This is the single biggest remaining jump in "feels real":
one wake phrase per *conversation* instead of per *sentence*. The spec's key insight —
reopen capture from authoritative playback-completion telemetry plus a measured acoustic
tail, not a timer — is right, and the telemetry already exists. Barge-in (user speech
during SPEAKING cancels/ducks) should ship in the same milestone; it was flagged in the
original P6 plan as the single biggest realism win and it falls out of the same echo-guard
work.

**B2. Perceived-latency program.** With the full loop live, latency is now the quality
bar: instrument and publish per-stage timings (wake ack, capture close → STT, STT →
first Gemma token, first token → first speaker sample) the same way the display frame
gate is tracked. Then attack perception before raw speed: think-earcon within ~200 ms of
capture close, mouth/face precommit on `response_start`, and speculative "Hm." fillers
only when the measured budget will overrun. A robot that *visibly starts* responding in
300 ms feels fast even when the sentence takes 2.5 s.

**B3. Light the last dark sensor: LTR-553 proximity + ambient light.** The only
confirmed-hardware sense with zero code (`grep -ri ltr553 src/` is empty). Cheap I2C
bring-up, no privacy surface, and it completes visitor-test step 1: eyes lift and face
brightens when someone approaches, before any sound. Ambient lux also feeds the circadian
layer honestly (dim room → sleepy threshold drops) and display brightness. This is the
best effort-to-aliveness ratio item on the board.

**B4. Person-loss choreography.** The other half of the visitor test: when a tracked
face disappears, look toward last position, small scan, visible sigh, return to idle
life. `GazeTracker` + `ActiveSpeakerTracker` + the expression system already carry all
the state needed; this is persona-side behavior code with no new hardware, and it is the
kind of "it has feelings about you leaving" moment that gets shared in videos.

**B5. Sound-direction orienting.** `StereoDirection` and the saliency path exist; the
original P3 flagship — eyes dart toward a voice, head follows, camera confirms — should
now be closed on hardware and fused as the seed for visual search (sound picks the scan
direction). Also unlocks multi-person active-speaker selection, which
HARDWARE_FEATURE_ROADMAP.md already lists as a remaining report.

**B6. Embodied energy state.** The robot has rich PMIC/battery/thermal telemetry and a
character that is contractually honest. Connect them: battery level shapes arousal
baseline, "Power is low. I will rest soon." at the honest threshold, warm-CPU sluggishness
after long sessions. Zero new hardware; deepens the "it is a small creature" illusion and
it is exactly the CHARACTER_LOCK low-battery behavior, now implementable with real data.

**B7. Gesture vocabulary growth.** Nod/shake proved the seed-varied procedural gesture
approach. Extend the library: lean-in while listening, double-take on surprise, slow
look-around during think, settle-shiver after pickup. Keyed to modes and emotion, built
on the existing motion session/safety rails.

**B8. P8 continuity (now unblocked).** Habit greetings from arrival-time rhythms,
opt-in face familiarity (host-side embeddings only, per PRIVACY.md), longer mood arcs.
The memory foundation (versioned, bounded, deny-listed) is exactly the substrate this
was waiting for. Keep the CHARACTER_LOCK reference-frequency rule: familiarity, never
a log.

### Track C — Platform and product upgrades

**C1. Persona hot-swap and a pack index.** Packs currently bind at firmware build time.
Now that the repo is public, the community flywheel needs: (a) runtime pack loading
(SD/LittleFS assets + bridge-side switch — the OTA and settings machinery already prove
the patterns), (b) persona switching exposed in the companion app (UI seam exists), and
(c) a lightweight pack index — even just a `community-personas` topic/registry repo with
CI running `verify_persona_pack` on PRs. Spark/Glow proved the seam; sharing is the
product now.

**C2. Companion to Play closed track.** The evidence contracts
(`android-speech/controls/pairing/gemma-ready`) are built; what remains is capturing the
physical proofs and shipping to the closed test track (the 12-tester/14-day window is
mandatory anyway — use it while B-track lands). Real on-phone Gemma inference proof
converts Mobile Brain Mode from staged to real.

**C3. First-thirty-minutes onboarding.** The repo is live; the funnel matters now. A
single QUICKSTART path from "I have a CoreS3 + StackChan kit" to "it greeted me": flash
public BYOM build → phone/PC pairing QR → Wi-Fi bootstrap → BYOM model/voice setup →
first conversation. Most pieces exist as separate verified tools; the product gap is one
ruthlessly linear document plus a `first_run_check` script that tells a newcomer which
step failed. Community contribution quality will track this doc's quality.

**C4. Doc estate cleanup (small, do soon).** The status table in
JOHNNY_ALIVE_PATHWAY.md §Current Status still describes the pre-arrival world (P2-P5
"no real adapters") and now contradicts README/FIRST_DEPLOY_STATUS — a newcomer reading
the pathway doc first would badly underestimate the project. Refresh the table, stamp
GAP_ANALYSIS.md and COMPANION_APP_GAP_ANALYSIS.md items with closed/open status, and
declare FIRST_DEPLOY_STATUS.md the single live-status source with pointers from
everything else. Ten stale minutes of reading is the cost of every stale status page.

**C5. OTA channels.** With OTA + rollback proven, add a stable/beta channel distinction
so community units track releases while the reference robot runs release candidates.
Cheap now, painful to retrofit after there are fleets of strangers' robots.

## 3. Sequenced recommendation

| Order | Item | Why now |
|---|---|---|
| 1 | Track A closure (soak, package, failover evidence) | Released repo with open headline gate; everything else inherits credibility from this |
| 2 | B1 Conversation v2 + barge-in | Biggest felt jump; spec already written; telemetry ready |
| 3 | B3 LTR-553 proximity/ambient | Best aliveness-per-effort; last dark sensor; completes visitor-test step 1 |
| 4 | C4 doc estate refresh | Hours of work; protects every new visitor's first impression |
| 5 | B2 latency program | Turns the live loop from "works" to "feels instant"; measurable |
| 6 | C1 persona hot-swap + index | Converts public release into a community flywheel |
| 7 | B4 + B5 person-loss + sound-orient | The shareable-video behaviors; fuse the senses already built |
| 8 | C2 companion closed track | Uses the mandatory Play testing window productively |
| 9 | B6-B8, C3, C5 | Continuous deepening once the above land |

### 3.4 The voice-provenance decision (called out because it blocks quietly)

Production voice provenance has been an open gate since the first pathway doc, and it now
gates both bundling the private RVC model and the "official voice" story for community
units. Two honest exits exist: (a) commission/record a rights-clean voice for a one-time
cost and close the gate permanently, or (b) declare BYOM-voice the *permanent* public
stance and make the Spark Synth DSP chain over a stock TTS the official public voice.
Either is defensible; the expensive thing is the current in-between, where every release
cycle re-litigates it. Recommend deciding this before v0.3.0.

## 4. One structural caution

The evidence culture (exact-image binding, formal checkers, forensic soaks) is this
project's superpower and its main tax: several recent soak restarts were caused by the
*checker policy*, not the robot. As community contributors arrive, keep two explicit
tiers — release-gate rigor for promotion evidence, and a fast lane (native tests +
simulator + short smoke) for feature iteration — so the rigor that protects releases
does not price hobbyists out of contributing. The interaction-aware policy split
(commit `6a90a8f`) was exactly the right instinct; generalize it.
