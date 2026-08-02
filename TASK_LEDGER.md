# Task Ledger

Ledger timestamp: 2026-08-02 America/New_York

## M0-001 — Establish Repository Truth

- **Problem:** Local `main`, active worktrees, remote branches, roadmap text, and PR topology did
  not provide one current source of truth.
- **User-facing consequence:** Stale, unsafe, or already-merged mechanisms could be reapplied or
  used to justify false capability claims.
- **Evidence:** Fetched `origin/main` is `39b750e6`; local `main` is 75 commits behind; several
  ahead branches are patch-equivalent; PR #218 is open/conflicting; Away work is separate and
  security-sensitive.
- **Priority:** P0.
- **Dependencies:** None.
- **Owner:** `/root`.
- **Allowed files:** `BRANCH_LEDGER.md`, `PROJECT_STATE.md`, `TASK_LEDGER.md`.
- **Frozen systems:** Firmware, bridge runtime, hardware, credentials, evidence archives, remote
  refs, and GitHub state.
- **Acceptance tests:** Fetch all refs/tags; record exact main; inventory every non-generated
  branch; recompute merge base/ahead/behind/patch equivalence; map PRs; group dependency domains;
  independent read-only verification.
- **Stop conditions:** Any operation would switch an active checkout, change a ref, expose a
  secret, or disturb live services.
- **Result:** Complete. AUDIT-01 independently recomputed topology and found four documentation
  gaps; all four are now incorporated in `BRANCH_LEDGER.md`.
- **Commit:** `0e3467e79766ed1cafeef4837c162c8a50bb29e1` (`docs: establish aliveness
  control baseline`).
- **Decision:** Accept as repository truth. No branch/reference cleanup is authorized in this
  workstream.

## M0-002 — Establish Baseline Gates

- **Problem:** Current-main quality and buildability were not recorded in this workstream.
- **User-facing consequence:** New work could be stacked on an already-red or incorrectly invoked
  build.
- **Evidence:** Native 289/289, bridge 543/543, trusted-facts smoke and three contracts passed.
  Default shared-core release build failed before compilation; documented isolated-core build
  passed with SHA-256 `8A76CA80...B756`.
- **Priority:** P0.
- **Dependencies:** M0-001 fetched baseline.
- **Owner:** `/root`.
- **Allowed files:** Project-control and audit Markdown only.
- **Frozen systems:** Source behavior, live processes, hardware, ignored private evidence.
- **Acceptance tests:** Run every AGENTS verification command; distinguish tool-context failure
  from source failure; preserve exact counts/hash without claiming physical proof.
- **Stop conditions:** A command would flash, start motion, overwrite evidence, or require
  weakening a gate.
- **Result:** Complete; source baseline is green in the documented build context. Invocation/core
  ambiguity is recorded as a tooling/documentation fault.
- **Commit:** `0e3467e79766ed1cafeef4837c162c8a50bb29e1` (`docs: establish aliveness
  control baseline`).
- **Decision:** Accept as the source baseline; do not treat the build hash as physical evidence.

## M0-003 — Ten-Domain Read-Only Audit Wave

- **Problem:** Current capabilities and gaps have not been independently mapped across repository,
  conversation, memory, self-state, perception, initiative, expression, product, ethics, and
  research/evaluation domains.
- **User-facing consequence:** Architecture work could optimize an imagined defect or regress a
  hidden safety/privacy boundary.
- **Evidence:** All ten role-specific reports are complete: repository, conversation, memory,
  self-state, perception, initiative, expression, product, privacy/ethics, and research/evaluation.
  Audit findings are reconciled into the capability, gap, risk, scorecard, and research records.
- **Priority:** P0.
- **Dependencies:** M0-001 and M0-002.
- **Owner:** `/root`, with non-writing Luna audit agents.
- **Allowed files:** None for audit agents; `/root` may later write the mandated audit Markdown.
- **Frozen systems:** All production code, hardware, live services, private data, GitHub state.
- **Acceptance tests:** Ten evidence-backed reports with file/symbol references, commands, tests,
  uncertainty, risks, and ranked next action; implementation agent is not its only reviewer.
- **Stop conditions:** An agent would need to infer sensing/identity, read private values, mutate
  code, call hardware, or weaken a boundary.
- **Result:** Complete; no audit agent changed files or production behavior. One privacy report was
  reissued as a defensive summary after the first detailed response was blocked by safety filters.
- **Commit:** `0e3467e79766ed1cafeef4837c162c8a50bb29e1` (`docs: establish aliveness
  control baseline`).
- **Decision:** Close the read-only wave; preserve durable replay references before preregistration.

## M0-004 — Salvage Reproducible Firmware Builds

- **Problem:** PR #218 addresses real firmware timestamp nondeterminism but is 67 commits behind,
  conflicting, lacks the required all-environment contract, can duplicate inherited pre-scripts,
  accepts loosely bounded overrides, and includes an unrelated LAN-test change.
- **User-facing consequence:** A rebuilt binary may not match exact source/evidence, weakening
  release trust and rollback reproducibility.
- **Evidence:** PR diff and body; effective `extra_scripts` inheritance; successful current-main
  release build in the documented core.
- **Priority:** P0 Milestone 0 candidate.
- **Dependencies:** M0-003 audit reconciliation; clean task preregistration.
- **Owner:** One future implementation owner, with separate verification owner.
- **Allowed files:** Tentatively `platformio.ini`, a single reproducible-build pre-script, one
  focused contract test, `AGENTS.md`, and the relevant release/build documentation. Final scope
  must be frozen before implementation.
- **Frozen systems:** Firmware behavior, face timing, actuator/power authority, bridge runtime,
  package secret policy, hardware, and unrelated LAN tests.
- **Acceptance tests:** Failing effective-config coverage test first; exactly one effective
  pre-script for every firmware/release environment; sanitized/fail-closed overrides and release
  packaging governance; current gates; two clean exact-image builds across a clock boundary for
  all three public packaged environments (`stackchan`, `stackchan_servo_calibration`, and
  `stackchan_release_full`) plus classified private evidence-bearing domains, with identical
  SHA-256; explicit documented PlatformIO core.
- **Stop conditions:** Ordinary current-main build becomes red; a release environment cannot be
  classified; identical clean builds differ; implementation needs unrelated source changes.
- **Result:** Not started.
- **Commit:** None.
- **Decision:** Candidate experiment, not yet selected.

## M0-005 — Reconcile Stale Status Documents

- **Problem:** Authoritative documents contain superseded lower sections and current conversation
  behavior is described inconsistently across protocol and roadmap text.
- **User-facing consequence:** Operators may run the wrong gate, repeat retired experiments, or
  misstate what was physically qualified.
- **Evidence:** `FIRST_DEPLOY_STATUS.md` and `ARRIVAL_DAY_RUNBOOK.md` top sections supersede older
  content; `BRIDGE_PROTOCOL.md` and `CONVERSATION_V2_ROADMAP.md` still describe the pre-#216
  4.8-second/fixed initial capture while current tests/code use endpointing and a larger ceiling.
- **Priority:** P0 documentation truth.
- **Dependencies:** Audit reports and current-source trace.
- **Owner:** Future documentation owner with independent consistency reviewer.
- **Allowed files:** Status/runbook/protocol/roadmap documents only after exact line-level scope is
  approved.
- **Frozen systems:** All code and hardware evidence; completed evidence statements may be
  clarified but never rewritten as stronger proof.
- **Acceptance tests:** Every current claim cites source/tests or exact physical evidence; older
  sections are clearly historical; no evidence transfer; documentation consistency review passes.
- **Stop conditions:** A claimed current firmware/hash cannot be proven, or reconciliation would
  discard historical evidence.
- **Result:** Complete in the working tree. Historical physical evidence remains intact; current
  installation is labelled unknown; conversation 12/13/15-second source timing plus 10-second host
  mismatch, camera compilation, Character Lock earcon/signed-valence, dashboard launch defaults,
  managed desktop Python, and dated vision evidence are reconciled. Launcher, desktop runtime, and
  three evidence/archive contract suites pass.
- **Commit:** `0e3467e79766ed1cafeef4837c162c8a50bb29e1` (`docs: establish aliveness
  control baseline`).
- **Decision:** Accepted by the final independent documentation review; no historical evidence was
  strengthened or transferred. Complete.

## UX-001 — Expire Stale Dashboard Robot Readiness

- **Problem:** The loopback dashboard reports robot connected/ready from an approximately
  64,909-second-old heartbeat even though direct debug/ping/TCP probes fail and the bridge process
  has no established robot socket.
- **User-facing consequence:** An operator can believe the robot and bridge are ready when current
  reachability is not established.
- **Evidence:** Bounded live snapshot recorded in `PROJECT_STATE.md`.
- **Priority:** P1 trust/recovery candidate.
- **Dependencies:** Product/onboarding and failure-attribution audit reports.
- **Owner:** Future host-dashboard vertical-slice owner plus independent reviewer.
- **Allowed files:** To be frozen after source trace; likely dashboard status projection and
  focused host tests only.
- **Frozen systems:** Firmware, motion endpoints, live service startup/restart, private status
  values, bridge protocol.
- **Acceptance tests:** Stale heartbeat/socket state deterministically degrades connection and
  operational readiness; fresh heartbeat restores it; last-known telemetry stays labeled stale;
  no polling or model load is added.
- **Stop conditions:** Fix would require probing hardware on each dashboard poll, restarting the
  bridge, or conflating one timeout with robot failure.
- **Result:** Observed and queued; no diagnosis or fix implemented.
- **Commit:** None.
- **Decision:** Compare against M0-004 after all audit reports rank impact.

## M1-001 — Physically Qualify Conversation V2 Closure

- **Problem:** Source covers reply windows, endpointing, host cancellation, recovery, and bounded
  context, but physical over-speaker barge-in, echo rejection, exact-image qualification, and a
  no-motion conversation soak remain unproven.
- **User-facing consequence:** Long utterances or interruptions may still fail on the real robot
  despite source tests.
- **Evidence:** Conversation roadmap, current source/tests, and authoritative release documents.
- **Priority:** P0 for Milestone 1; not part of the current no-hardware Milestone 0 slice.
- **Dependencies:** Current exact installed image identity, live reachability, operator presence,
  no-motion qualification, and the complete physical runbook.
- **Owner:** One hardware-affecting owner with operator and independent evidence reviewer.
- **Allowed files:** None until the source baseline and exact candidate are frozen.
- **Frozen systems:** Privacy/wake gate, face 50 ms gate, power/thermal/motion safety, memory policy,
  camera auth, current production services.
- **Acceptance tests:** Physical endpointing, long utterance, reply-window closure, echo rejection,
  barge-in cancellation, failure recovery, bounded no-motion soak, exact SHA/evidence checker.
- **Stop conditions:** Any bad state during motion triggers `/motion-stop`, runner termination, and
  post-stop `/debug` when reachable; eye discomfort; privacy leak; exact image mismatch; repeated
  unreadable snapshot alone is not failure.
- **Result:** Pending; no physical action authorized in this workstream.
- **Commit:** None.
- **Decision:** Remains the next hardware milestone after Milestone 0, not silently promoted into
  v1 evidence.

## SAFE-001 — Authorize Every Durable Memory Delta Host-Side

- **Problem:** Otherwise-valid model-authored writes and forgets are applied even when they do not
  match an explicit current user instruction; a wildcard forget can reset memory.
- **User-facing consequence:** Ordinary conversation can create a false personal memory or erase
  durable memory without consent.
- **Evidence:** AUDIT-03 source trace and synthetic probes through character normalization, runner
  enforcement, reference bridge application, and Memory v4 store.
- **Priority:** P0 trust/privacy.
- **Dependencies:** Ten-domain audit reconciliation, `MEMORY_CONTRACT.md`, preregistered failing
  tests.
- **Owner:** One future host-memory vertical-slice owner plus separate memory/privacy reviewers.
- **Allowed files:** To be frozen; expected character-policy enforcement and focused runner/
  integration tests only.
- **Frozen systems:** Memory file/schema/migration, explicit remember/forget language contract,
  live/private memory, research path, persona scoping, firmware, services, and hardware.
- **Acceptance tests:** Ordinary model write, delayed replay, wildcard forget, scope substitution,
  tool/research output, and malformed actions produce zero deltas; exact transcript-derived
  remember/forget/reset still work; broad bridge and silent privacy gates pass.
- **Stop conditions:** Fix requires reading live values, changing the memory schema, broadening
  sensitive categories, or breaking an explicit memory command.
- **Result:** Candidate; not started.
- **Commit:** None.
- **Decision:** Queued immediately after the stop-ship transport/control security work; it is not
  the currently selected slice.

## CONV-001 — Establish One Bounded Device/Host Conversation Terminal Contract

- **Problem:** Playback start/chunk/finish failure may never produce `playback_complete`; host
  `SPEAKING` has no timeout; model/TTS recovery can claim a reply state that firmware did not open;
  and the host capture lease ends before firmware's accepted utterance ceiling.
- **User-facing consequence:** Stackchan can appear stuck, close a valid long utterance, or believe
  it is listening when the robot remains wake-gated.
- **Evidence:** AUDIT-02 source trace, 42 focused passing positive tests, and deterministic 10,001/
  12,000 ms rejection probe.
- **Priority:** P0 conversation trust; hardware qualification remains a later gate.
- **Dependencies:** Milestone 0 closure and one preregistered terminal-event design.
- **Owner:** One future coupled firmware/host conversation owner with independent failure and
  hardware-authority reviewers.
- **Allowed files:** To be frozen across conversation session, audio downlink/protocol realization,
  and exact focused tests only.
- **Frozen systems:** Wake privacy, microphone ceiling, motion/power authority, memory, persona,
  face gate, live services, and hardware.
- **Acceptance tests:** Start/chunk/finish failure, missing acknowledgement, model/TTS error,
  cancel, silence, boundary heartbeat, and 12/13/15-second timing all terminate consistently;
  broad source gates pass before physical qualification.
- **Stop conditions:** Any path widens wake capture, masks failed playback, weakens privacy, or
  requires live device action before source gates.
- **Result:** Queued; not started.
- **Commit:** None.
- **Decision:** Required before claiming natural-conversation closure.

## AFFECT-001 — Remove Synthetic Affect From Production Defaults

- **Problem:** `IntentEngine` boots with demo mode enabled and injects random synthetic emotion
  events; phrase streaming also erases negative valence before firmware.
- **User-facing consequence:** Mood/sleep may be driven by events that never occurred, and concern
  speech can conflict with a neutral face.
- **Evidence:** AUDIT-04 source trace, native demo-prevents-sleep test, and signed-valence probe
  (`-0.72` became `0.0` on response start).
- **Priority:** P0 embodiment honesty.
- **Dependencies:** Expression/product audits and a release-environment classification.
- **Owner:** One future bounded firmware/streaming owner with expression/release reviewers.
- **Allowed files:** To be frozen; demo production default/config contract, streaming clamp, and
  focused tests.
- **Frozen systems:** Affect equations, face timing, motion/power, explicit demo environments,
  production services, physical image/evidence.
- **Acceptance tests:** Every public/release/soak env boots demo off; explicit demo env remains
  opt-in; signed valence survives streaming; negative/neutral/positive boundary tests and current
  source gates pass.
- **Stop conditions:** Demo tooling is removed rather than isolated, face timing changes, or a
  physical claim is made without exact-image evidence.
- **Result:** Queued; not started.
- **Commit:** None.
- **Decision:** Treat current affect as uptime-state contaminated by production demo default until fixed.

## PERCEPT-001 — Make Presence and Social Context Freshness Truthful

- **Problem:** Face-lost events retain historical size while refreshing event time, allowing
  `camera_target_fresh=1`; stale one-person room summaries can still authorize personal context.
- **User-facing consequence:** Stackchan can claim someone is present, initiate, or project
  personal memory after the person/room evidence is gone.
- **Evidence:** AUDIT-05 source chain and safe synthetic probes; no physical cause inferred.
- **Priority:** P0 sensing/privacy.
- **Dependencies:** World-model contract and separate firmware/host scope decision.
- **Owner:** One future presence-contract owner with privacy and hardware-authority reviewers.
- **Allowed files:** To be frozen; camera freshness/heartbeat, room freshness accessor, and focused
  native/host tests.
- **Frozen systems:** Camera auth, raw-frame handling, identity policy, gaze/motion authority,
  initiative frequency, live vision/robot.
- **Acceptance tests:** A regression test first reproduces false freshness from detect-then-repeated-
  lost on the frozen baseline; after repair, lost evidence cannot remain fresh, stale/error/unknown
  room fails closed for personal projection, fresh evidence restores behavior, and broad gates pass.
- **Stop conditions:** Requires raw-frame retention, identity, live camera use, or treats absence of
  data as absence/presence.
- **Result:** Queued; not started.
- **Commit:** None.
- **Decision:** Must precede broader perception-driven initiative.

## INIT-001 — Revalidate Initiative Against Authoritative Current Inhibits

- **Problem:** Initiative checks thermal/power fields absent from production heartbeat and does not
  cancel/revalidate an already reserved opener when later heartbeat state becomes sleeping,
  unsafe, inhibited, or no longer present.
- **User-facing consequence:** Proactive speech can start or continue at an inappropriate body,
  safety, or social moment.
- **Evidence:** AUDIT-06 real-shaped heartbeat and slow-path source trace; firmware physical
  authority remains bounded.
- **Priority:** P0 initiative restraint.
- **Dependencies:** Typed inhibit contract and presence fix; initiative remains unpromoted/off by
  default.
- **Owner:** One future host/protocol initiative owner with independent safety, privacy, and
  failure-injection reviewers.
- **Allowed files:** To be frozen; production heartbeat/host session revalidation and focused
  integration tests only.
- **Frozen systems:** Actuator/power authority, microphone windows, frequency/backoff, memory,
  model/research prompts, live services, and hardware.
- **Acceptance tests:** Real production heartbeat suppresses authoritative unsafe state; slow runner
  emits zero response/audio after later sleep/error/inhibit/presence-loss; normal eligible case
  remains; broad gates pass.
- **Stop conditions:** Host gains physical authority, missing telemetry is guessed healthy, or a
  live initiative is triggered.
- **Result:** Queued; not started.
- **Commit:** None.
- **Decision:** Required before initiative physical or longitudinal promotion.

## PRODUCT-001 — Make Passive Dashboard Motion and Thermal Labels Truthful

- **Problem:** Passive dashboard state can label motion safely stopped when rail/torque remain on
  and render unknown thermal state as clear.
- **User-facing consequence:** An operator can trust a false actuator/thermal safety statement while
  diagnosing or preparing the robot.
- **Evidence:** AUDIT-08 synthetic contradictory and missing-telemetry snapshots. Connectivity/
  readiness freshness is owned separately by `UX-001`.
- **Priority:** P0 operator trust.
- **Dependencies:** None beyond frozen tri-state contract; compare with selected first slice after
  full audit ranking.
- **Owner:** One future dashboard vertical-slice owner with independent hardware-authority and UI
  contract reviewers.
- **Allowed files:** Expected dashboard status projection, UI labels, and focused API/UI tests;
  exact scope must be frozen.
- **Frozen systems:** Motion command path, robot polling frequency, firmware, bridge protocol,
  production service, hardware, and last-known evidence values.
- **Acceptance tests:** Motion safe only when motion/rail/torque are fresh explicit false and no
  suppression conflict; unknown thermal stays unknown; fresh explicit thermal-clear restores the
  label; no new robot poll or command.
- **Stop conditions:** Fix changes motion endpoints, calls live hardware, discards cached telemetry,
  or labels one timeout a robot failure.
- **Result:** Queued; not started.
- **Commit:** None.
- **Decision:** High-value host-only candidate, but memory authorization remains higher trust priority.

## SEC-001 — Fail Closed at the PC Bridge Admission Boundary

- **Problem:** The production launcher binds the PC bridge on all interfaces, but WebSocket
  admission does not enforce the existing firmware path/protocol/device signals or configured
  robot peer, browser-origin admission is open, dispatch is not conditioned on a validated upgrade,
  and a blank endpoint ID bypasses an active owner.
- **User-facing consequence:** An untrusted LAN peer could access private settings/memory behavior,
  inject turns, or monopolize the single-client brain service.
- **Evidence:** AUDIT-09 source trace and synthetic-only admission/message probes. The exposed live
  bridge listener was stopped with zero established clients; no payload or live data was accessed.
- **Priority:** P0 stop-ship security.
- **Dependencies:** Existing `BridgeWebSocketTransport` handshake semantics, production launcher
  configured device host, durable audit evidence, failing tests approved before code.
- **Owner:** One host-transport implementation owner; separate security, privacy, regression, and
  documentation reviewers.
- **Allowed files:** Freeze to `bridge/lan_service.py`, `bridge/test_lan_service.py`,
  `bridge/lan_smoke.py` (independently approved after the red phase exposed its direct legacy
  headerless fixture), `bridge/test_dashboard_service.py` (independently approved after the first
  broad run exposed the same integrated-server fixture),
  `tools/start_pc_brain.ps1`, `tools/start_pc_brain_directml.ps1`,
  `tools/restore_voice_v2_production.ps1`, `tools/run_selected_voice_once.ps1`,
  `tools/start_voice_v2_supervised_validation.ps1`,
  `tools/start_warm_rocm_full_system_soak.ps1`, `tools/check_pc_brain_runtime.ps1`,
  `tools/test_pc_brain_runtime_check_contract.ps1`,
  `tools/test_start_pc_brain_directml_contract.ps1`,
  `tools/test_stackchan_dashboard_launcher_contract.ps1`, `docs/BRIDGE_PROTOCOL.md`,
  `docs/RELEASE_QUICKSTART.md`, `docs/ARRIVAL_DAY_RUNBOOK.md`, `docs/BRIDGE_DASHBOARD.md`, and
  `bridge/README.md`. Each expansion was independently approved after a test/review exposed a
  directly coupled compatibility gap. No firmware file in this slice.
- **Frozen systems:** Message schemas after admission, STT/model/TTS, memory semantics, dashboard,
  firmware, robot, pairing values, voice/vision workers, release packaging, and all hardware
  authority.
- **Acceptance tests:** Exact `GET /bridge HTTP/1.1`; tokenized WebSocket upgrade fields, version 13,
  exact existing firmware protocol and bounded nonblank device headers; duplicate critical headers
  and any browser `Origin` rejected; configured robot peer required and resolved once for a
  non-loopback bind; wrong peer rejected before request dispatch; protected message types fail on an
  explicitly unadmitted session; invalid attempts do not consume `--once`; valid firmware-shaped
  connection/immediate server hello/disconnect/reconnect remains compatible; a blank endpoint is
  rejected only when an active brain owner exists; current launcher contracts, bridge suite, native
  logic, and silent privacy gates pass. The device header is not brain-owner identity. No test
  contains a real secret or live private value.
- **Stop conditions:** Existing firmware does not provide a stable signal needed by the contract;
  fix requires a client-side hello, inventing cryptographic identity/pairing semantics, reading a
  private code, changing wire payloads, weakening loopback defaults, or restarting the contained
  live bridge before independent verification. If peer resolution cannot be frozen safely, require
  a configured literal IP instead of widening admission.
- **Result:** Implemented test-first in the isolated working tree after the expected-red run.
  Focused admission, malformed-key recovery, wrong-peer no-dispatch/once recovery, maintained
  robot-wrapper, and runtime-certification contracts are green. The final staged-tree matrix is
  green: 559 bridge, 289 native, 115 focused LAN, ten consecutive dashboard-heartbeat race
  repetitions, five LAN smoke scenarios, silent privacy, secret-free release compile, and three
  evidence/archive contracts. The self-identifying pre-commit manifest and hashed logs are stored
  under ignored `output/private/sec-001/final-<tree>/`; the containing Git commit and final handoff
  provide the durable source identity. A user-authorized isolated live check also
  completed one real Ollama model turn, and a separate real non-loopback socket rejected a wrong
  peer without consuming `once`; both alternate-port processes exited/stopped and nothing was
  deployed to the production listener or robot. Independent security, regression, preregistration,
  and documentation/authority reviews accept the frozen candidate.
- **Commit:** The atomic `SEC-001` commit containing this record; its exact SHA is assigned by Git
  after the record is written and must be read from history/the final handoff.
- **Decision:** Accepted for the atomic host-side commit. Treat TCP peer plus spoofable headers as
  bounded admission hardening, not cryptographic authentication. Deployment remains unauthorized;
  firmware HTTP control authorization remains the separate P0 `SEC-002` task.

## SEC-002 — Enforce Emergency-Stop-Only Firmware HTTP Control

- **Problem:** Wi-Fi firmware applies tone, wake-reset, motion-enable, recovery, and reboot-class
  HTTP controls before response without authenticated owner authority; malformed/unknown requests
  can fall through to status and the raw request target is echoed.
- **User-facing consequence:** A LAN peer can request physical/recovery changes, while dashboards
  and motion-validation tools can offer an authority the contained firmware no longer has.
- **Evidence:** Source/configuration trace only; no unsafe hardware endpoint was exercised.
- **Priority:** P0 physical/control security.
- **Dependencies:** `SEC-001` commit `9c72f020`; fail-closed release decision selected; one
  hardware-affecting branch at a time.
- **Owner:** `/root` implementation owner; independent policy, scope, operator-authority, release,
  and physical-evidence reviewers.
- **Decision:** Fixed emergency-stop-only containment. No authentication, credential, pairing-code
  reuse, or pairing-file transport is introduced.
- **Expected-red gate:** Before implementation, focused native tests must fail because no shared
  request policy exists; the source/config contract must show that all 19 effective Wi-Fi profiles
  inherit unsafe pre-response effects; dashboard tests must show Resume does not fail closed for
  missing/contained policy; operator-tool contracts must show legacy workflows do not all stop
  truthfully. Preserve exact commands and logs.
- **Allowed routes:** Query-free `GET /`, `GET /debug`; query-free `GET`/`POST` emergency audio-stop
  and motion-stop aliases. Those methods define supported stop availability; rejection of the
  baseline's accidental other-method behavior is intentional. Query-bearing `GET` camera families
  reach the existing parser/authorizer unchanged, and successful camera effects still require its
  exact grammar and pairing check.
- **Denied routes:** Both speaker-tone aliases, four mic-tone aliases, wake-reset, three motion-
  enable aliases, three recovery aliases, and three reboot aliases, for every method/query, before
  side effects. Malformed/query/prefix/suffix/encoded/truncated near-misses never dispatch.
- **Allowed files:** Exact `SEC-002 / PRIV-001 Frozen Preregistration` list in `PROJECT_STATE.md`.
  Any expansion requires preserved expected-red evidence of direct coupling and independent review.
- **Frozen systems:** Automatic offline recovery/reboot supervisor, emergency stops, bounded status,
  OTA token/digest path, camera pairing/grammar, bridge framing, 50 ms face gate, actuator authority,
  installed firmware, and all physical evidence.
- **Acceptance tests:** Expected red recorded for named assertions only; exhaustive method/route/
  query policy green; admitted stops return bounded `202 accepted:true`, motion publication failure
  returns `503 accepted:false`, and neither claims completion; no denied
  callback/effect; all 19 effective Wi-Fi configurations lack a bypass; dashboard missing/unknown/
  contained policy disables and refuses Resume while Stop remains available; coupled tools preflight
  and stop truthfully; full native/bridge/silent-privacy gates, secret-free release build, and package
  provenance and prearrival-simulator regression pass. Simulator results do not prove port 8789.
  Source acceptance does not close either risk; exact-image no-motion, supervised emergency-stop,
  exact identity, and final release gates remain separate.
- **Stop conditions:** A maintained query-free GET stop becomes less reachable; expected red misses
  its named assertion; any bypass/fallback appears or refusal is treated as success; camera pairing
  is repurposed; a private value is read; automatic recovery is disabled; any sink leaks a raw
  target/query/pairing/authorization value; microphone capture/wake gate/model changes; an unlisted
  file changes without approved expansion; exact source/binary identity is unavailable before no-
  motion qualification; hardware is touched early; or deployment/risk closure is claimed before
  physical/release gates.
- **Rollback:** Revert the exact atomic source/client candidate if target tests do not turn green or
  a frozen invariant regresses. Do not flash a prior insecure image as automatic rollback; isolate
  or power off the robot and preserve evidence.
- **Result:** Preregistered; expected-red pending; no implementation or hardware exercise.
- **Commit:** Atomic control-only preregistration commit containing this record; exact SHA assigned
  by Git and reported in the handoff.
- **Decision:** Stop-ship. Existing supervised Resume/motion-soak tooling has no approved authority
  after containment; keep the robot on a trusted isolated LAN or powered off until qualification.

## PRIV-001 — Disable Unauthenticated Wake PCM Export

- **Problem:** `/wake.wav` and `/wake-pcm.wav` return recent 16 kHz wake-microphone ring PCM without
  the camera pairing gate.
- **Evidence:** Source-observed only. No raw audio was fetched, archived, logged, or inspected.
- **Priority:** P0 privacy/trust.
- **Decision:** The shared emergency-stop-only policy returns `403` for both aliases before reading
  the PCM ring, constructing a WAV response, or exporting bytes in every Wi-Fi/release profile. It
  does not label PCM as read-only health or alter on-device wake capture.
- **Frozen systems:** Wake-gated audio processing, wake model, microphone capture needed on-device,
  camera pairing, memory privacy, and all raw/private artifacts.
- **Acceptance tests:** Pure policy and source/config tests only; no request, raw-audio fixture,
  content assertion, log, or archive. Silent trusted-facts and release gates remain green.
- **Stop conditions:** Any test requests or inspects PCM, microphone capture/wake gating/wake model
  changes, general control auth is invented, consent/retention is assumed, or private audio enters a
  repository/evidence path.
- **Future authority:** Any diagnostic export requires separately approved authentication, explicit
  consent, bounded retention, and private-artifact transport.
- **Result:** Preregistered with `SEC-002`; expected-red pending; not exercised.
