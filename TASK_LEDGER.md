# Task Ledger

Ledger timestamp: 2026-08-03 America/New_York

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
- **Owner:** `/root`, with separate Luna implementation and read-only verification owners.
- **Allowed files:** The initial tentative scope was insufficient once package/source binding,
  dependency identity, command trust, ZIP safety, publication ordering, and every release consumer
  had to fail closed as one contract. The expanded slice is frozen to `platformio.ini`, `AGENTS.md`,
  exact firmware-release requirements, the firmware/release workflows, package/verifier/
  publication/share/audit consumers, reproducibility/dependency/source/Git/toolchain/ZIP helpers,
  their focused contracts, and directly coupled release/status/runbook documentation. The pending
  commit's exact path inventory is the authority. Firmware `src/`, bridge runtime, personas,
  private evidence, and unrelated feature work remain outside scope.
- **Frozen systems:** Firmware behavior, face timing, actuator/power authority, bridge runtime,
  package secret policy, hardware, and unrelated LAN tests.
- **Acceptance tests:** Failing effective-config coverage test first; exactly one effective
  pre-script for every firmware/release environment; sanitized/fail-closed overrides; exact source,
  dependency, toolchain, command, package, ZIP, and publication governance; current regression and
  evidence-contract gates; two clean exact-image builds across a clock boundary for all three
  public packaged environments (`stackchan`, `stackchan_servo_calibration`, and
  `stackchan_release_full`) plus classified private evidence-bearing domains, with identical
  SHA-256; explicit documented PlatformIO core. Until an independently reviewed allowlist can meet
  the complete gate, release-grade packaging and `RequireReleaseEligible` must refuse before Git,
  Python, or PlatformIO execution while diagnostic packages remain ineligible.
- **Stop conditions:** Ordinary current-main build becomes red; a release environment cannot be
  classified; identical clean builds differ; implementation needs unrelated source changes.
- **Result:** In progress. Two same-input clean `stackchan_release_full` builds produced different
  firmware binaries, with 69 differing bytes including embedded wall-clock time and downstream
  digest regions; this is the accepted expected-red evidence. PR #218 was reviewed read-only and
  will not be merged or cherry-picked because its hook inheritance, override handling, dirty-tree
  detection, and unrelated bridge-test change do not meet this gate. The public boot-motion
  prerequisite is committed at `b5ea5c5f`. The deterministic input, source/dependency/toolchain,
  safe packaging/verification, publication, consumer, CI, and selector-authority corrections are
  committed through `e52826a4` and published on draft PR #220 with all checks green. The selector
  slice binds one exact `boot_app0.bin` per firmware environment to reviewed framework identity,
  size, and SHA-256; makes the release flasher write it at `0xE000` from locked, second-verified
  snapshot bytes; and locks/verifies standalone publication assets. Diagnostic v13 proved the
  five-file package inventory and selector address order while remaining expressly dirty,
  diagnostic-only, non-release-eligible,
  non-flashable, and not reproducibility proof. Commit `616424e4` contains the Luna-reviewed
  24-component exact-host allowlist, all-three-environment clean B/C canonical dependency equality,
  a source-bound semantic Git-pack verifier, operational caller propagation, and passing policy,
  adversarial verifier, integration, and broad reproducibility contracts. No clean governed release
  package or hardware claim is earned yet.
- **Commit:** Reviewed toolchain integration
  `616424e4b87bc8cc7c737a849d543eda7bf51dfd`; release-governance/selector prerequisite
  `e52826a4a130f00718e20e71e5aea0f1cbc050ff`.
- **Decision:** Keep M0 open until the retained exact-host guard and governed package prove the
  exact clean commit across all three packaged environments and the independent rebuild. Do not
  flash or create qualification evidence before those gates close.

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

## M0-STATE-TRUTH — Reconcile Governance And Recovery Evidence

- **Problem:** The committed boot-motion/governance correction, current selector slice, diagnostic package,
  private firmware backup, and historical deployment prose could be read as one transferable
  release or physical identity.
- **User-facing consequence:** A diagnostic ZIP or backup-time observation could be flashed,
  published, or cited as current qualification without a clean source/toolchain/device binding.
- **Evidence:** committed head `e52826a4`; diagnostic v13 manifest with release/flash/hardware/
  distribution eligibility false; verified private three-read backup; backup-time `app0` selection
  with unknown source mapping; fresh intermittent `/debug` successes/timeouts; matching CoreS3 PnP
  identity present on COM4 without opening serial.
- **Priority:** P0 documentation and recovery truth before commit.
- **Owner:** `/root`, with independent read-only Luna state audit.
- **Allowed files:** `PROJECT_STATE.md`, `TASK_LEDGER.md`, `docs/FIRST_DEPLOY_STATUS.md`, and
  `docs/ARRIVAL_DAY_RUNBOOK.md` only.
- **Frozen systems:** Firmware, robot, serial ports, live services, backup bytes, private values,
  evidence archives, remote release state, and historical measured results.
- **Acceptance tests:** Current committed/uncommitted/package/backup/live identities are separated;
  the whole-flash hash is not called an app hash; historical current/live language is dated; no
  physical, reproducibility, restore, or release claim is transferred; documentation review and
  whitespace checks pass.
- **Stop conditions:** Any update would expose private backup content, infer a current application
  from USB/network absence or presence, strengthen historical evidence, or authorize restore/flash.
- **Result:** Complete for the latest snapshot. State reconciliation records the committed
  governance head, fail-closed M0 status, verified backup limits, current COM4 enumeration, and
  recovered intermittent debug. The live firmware self-reports confirmed `app0` and expected
  `69d3db27...8ebfa8`, while independent current bytes remain unproven. Runtime motion, rail,
  torque, and power authorities were off, but the installed image reports both motion and
  autonomous motion enabled at boot. No serial/control/flash/motion action occurred. Independent
  read-only review preserved the distinction between live self-report, backup extraction, source,
  package, and physical qualification.
- **Commit:** `616424e4b87bc8cc7c737a849d543eda7bf51dfd` with the atomic M0 governance slice.
- **Decision:** Accept the reconciliation while keeping release and hardware promotion on hold;
  the backup remains recovery evidence only.

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
- **Result:** Expected-red preserved; the source candidate represented by this record is
  implemented. Native logic passed 294/294, the exact policy passed all 19 Wi-Fi environments,
  focused dashboard passed 28 tests, full bridge discovery passed 567 tests, coupled operator/
  evidence contracts passed,
  silent trusted-facts privacy smoke remained model/audio silent, the no-hardware simulator passed,
  and secret-free release compilation/link/image generation passed. Dirty-tree release-package
  assembly/verification passed, and independent policy, security, and documentation/authority
  reviews accepted the exact source slice. The atomic implementation is `4d31de41`; a subsequent
  clean three-profile package at that commit verified with `dirty:false`, ZIP SHA-256
  `b69ecc75...174b96`, and full-image SHA-256 `4256f2e5...b31055`. No deploy, endpoint mutation,
  raw-audio request, reboot, flash, OTA, or hardware exercise occurred; physical gates remain
  unearned. A 2026-08-03 qualification audit found that the exact public full image had motion and
  autonomous motion enabled at boot, so it is explicitly rejected as the no-motion qualification
  candidate. The replacement source profile keeps both off at boot and is committed as
  `b5ea5c5f95e737d50c2ef2619b8efc4d846b4ea3`, but it remains source-only and unqualified at the
  time of this ledger update. Neither the dirty M0 governance worktree nor any diagnostic package
  inherits the old package or physical evidence.
- **Commit:** Frozen preregistration `d75c62f3`; package prerequisite `2ed5bb6a`; atomic
  implementation `4d31de414f5f2279b4c423ac3dfd7e940bb540d9`; public boot-motion correction
  `b5ea5c5f95e737d50c2ef2619b8efc4d846b4ea3`.
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
- **Result:** Implemented with `SEC-002` in commit `4d31de41`. Pure policy/config coverage and the
  silent privacy gate passed without requesting, reading, fixtureing, printing, or archiving wake
  PCM. The exact clean package verified; it remains undeployed and physically unqualified, so the
  risk remains open.

## PERCEPT-002 — Classify and Follow One Anonymous Human, Dog, or Cat

- **Problem:** The current paired vision worker detects faces only, sorts each frame independently,
  and has no species or durable track continuity. Any fresh target is projected as a person.
- **User-facing consequence:** Stackchan cannot intentionally follow a dog or cat and can silently
  switch geometric targets or make a false person claim.
- **Evidence:** Read-only source trace in
  `docs/PERSON_PET_FOLLOW_IDENTITY_MOTION_PREREGISTRATION.md`; historical evidence proves only one-
  human acquire/reacquire and slow horizontal follow.
- **Priority:** P1 aliveness/perception after P0 truth, memory, and operator-safety repairs.
- **Dependencies:** `PERCEPT-001`, `PRODUCT-001`, current camera-auth/privacy contract, and final
  wake/listen/reply follow evidence.
- **Owner:** One future host/firmware attention-slice owner with independent privacy, hardware-
  authority, model-provenance, and failure-injection reviewers.
- **Allowed files:** Freeze after expected-red tracing; likely local vision/model provenance,
  bounded camera candidate protocol/attention/gaze consumers, typed host context, focused tests,
  launcher/package contracts, and vision documentation.
- **Frozen systems:** Pairing, raw-frame non-retention, identity, generic memory, wake/audio, model
  authority, MotionTask/PowerCoordinator/ActuationEngine authority, 50 ms display gate, live robot,
  and completed evidence.
- **Acceptance tests:** Exact class allowlist; separated confidences; sticky single target across
  jitter/reorder/short loss; ambiguity/crossing abstention; pet never audio-matched; stale pet never
  described as person; no names/embeddings/private IDs on the firmware wire or diagnostics; model
  hash/license/performance gates; native/bridge/simulator and staged physical gates.
- **Stop conditions:** Confident wrong class, silent target switch, raw-frame retention, unpaired or
  remote vision, identity leakage, hunting/snap, missing stop evidence, or any safety/timing/power/
  thermal regression.
- **Result:** Preregistered only; no detector, protocol, behavior, service, or hardware change.
- **Commit:** Documentation-only preregistration commit containing this record; exact SHA assigned
  by Git and reported in the handoff.
- **Decision:** Anonymous classified following precedes every durable identity experiment.

## IDENT-001 — Natural Session Names and Owner-Controlled Durable Recognition

- **Problem:** The current system intentionally has no identity enrollment, recognition, names,
  biometric authority, identity vault, or verified removal surface.
- **User-facing consequence:** Stackchan cannot naturally remember who he is following; adding it
  naively could misname people/pets, persist biometric data, or resurrect a deleted identity.
- **Evidence:** Current YuNet/room/memory/dashboard source trace plus independent privacy review;
  PetFace/OpenAnimals show feasibility and substantial animal re-identification difficulty.
- **Priority:** P0 privacy within a later P1 experience feature.
- **Dependencies:** `SAFE-001`, `PERCEPT-001`, `PERCEPT-002`, authenticated owner-admin authority,
  private vault/deletion design, and explicit recognition-enable approval.
- **Owner:** One future identity vertical-slice owner with independent privacy/security, memory-
  truth, deletion, model-provenance, and product reviewers.
- **Allowed files:** Freeze per phase; likely new identity policy/store/isolated worker and tests,
  local vision typed integration, owner-admin dashboard surfaces, memory/prompt isolation guards,
  launcher/package verification, and privacy/vision documentation.
- **Frozen systems:** Recognition off by default; human/pet domains separated; names never guessed;
  raw frames ephemeral; identity absent from generic memory/routine telemetry/firmware; recognition
  never authentication or actuator/tool/memory authority; no cloud processing.
- **Acceptance tests:** Session nickname requires explicit wake-gated naming, one stable track, and
  confirmation; its dedicated in-RAM bridge registry is isolated from `BridgeMemory`, histories,
  logs, caches, and evidence and expires on every worker/bridge/conversation/track boundary. No
  biometric work begins before fresh admin action and consent; every pending-enrollment abort path
  destroys RAM/capture/template/index/vault state. Durable enrollment requires admin authority,
  nonce, consent, exact-label confirmation, threshold/margin/multi-frame agreement, and human/pet
  separation. Every rename/disable/re-enable uses fresh owner-admin authentication and its own nonce,
  advances epochs, invalidates caches/context (including every old-label binding on rename), fails
  closed on replay/auth loss/rollback, and preserves template isolation. Offline deletion covers RAM/
  index/templates/aliases/caches/managed backups and restart; tombstoned backup restore cannot rematch;
  public packages contain no private identity artifact.
- **Stop conditions:** Automatic durable enrollment, passive/model-authored names, missing consent
  or admin authority, false match/name transfer, raw-frame persistence, private diagnostic output,
  incomplete deletion, uncontrolled backup, rollback resurrection, or unlicensed/unhashed model.
- **Result:** Preregistered and held. Session nickname and durable biometric recognition are
  explicitly separate; neither is implemented or enabled.
- **Commit:** Documentation-only preregistration commit containing this record; exact SHA assigned
  by Git and reported in the handoff.
- **Decision:** Recognition remains disabled until the separate explicit enable checkpoint passes.

## MOTION-001 — Deterministic Emotional Motion and Sim/Real Trace Loop

- **Problem:** Existing affect/gaze/idle/gesture behavior lacks one explicit persona motion-style
  projection and calibrated final-actuator sim/real comparison. Production demo intent, blink,
  saccade, and boot-seeded random sources mean trace determinism must be established under recorded
  inputs/timing/seeds rather than assumed.
- **User-facing consequence:** Head motion can be technically safe yet feel slow, generic, or
  disconnected from face/voice/personality; tuning only pre-actuator frames can miss real output.
- **Evidence:** Source trace shows `IntentEngine` composition followed by downstream
  `ActuationEngine` idle sine, clamps, suppression, session, power, and hardware writes; the current
  Python simulator is not a dynamics twin.
- **Priority:** P1 embodiment after P0 motion-state truth and physical containment gates.
- **Dependencies:** `PRODUCT-001`, exact SEC-002 physical qualification, `PERCEPT-002` for classified
  follow scenarios, and a controlled-source final-actuator trace harness.
- **Owner:** One future firmware motion-style owner with independent hardware-authority,
  personality, deterministic-trace, and physical-evidence reviewers.
- **Allowed files:** Freeze after expected-red trace; likely affect/intent/idle/gaze/style components,
  native trace fixtures, orchestration/metrics, simulator contract, persona constants, and focused
  documentation. Safety coordinators change only if an independent defect requires a separate task.
- **Frozen systems:** No LLM/RL motor authority; exact servo/session/power/thermal/stop limits and
  50 ms display gate; model proposes typed intent only; physical evidence remains hash-specific.
- **Acceptance tests:** With demo injection controlled and every boot/persona/blink/saccade/random
  source fixed or recorded, the same input/timing/source schedule is trace-identical; bounded recorded
  variants stay within final yaw/pitch/velocity/acceleration/jerk/settling envelopes; zero suppressed/
  expired writes; reduced motion includes downstream overlays; emotion metadata cannot change safety/
  power decisions; target loss/reacquire and gestures settle; staged no-motion/HIL/follow/soak/post-
  stop evidence passes on the exact image.
- **Stop conditions:** Nonreproducible trace, unexplained sim/real sign/amplitude mismatch, unsafe
  jerk/oscillation, hunting, bad motion state, weakened coordinator, missed stop/post-stop proof, or
  timing/power/thermal regression.
- **Result:** Preregistered only; no motion equation, parameter, simulator, firmware, or hardware
  behavior changed.
- **Commit:** Documentation-only preregistration commit containing this record; exact SHA assigned
  by Git and reported in the handoff.
- **Decision:** Use deterministic low-dimensional styling and system identification; do not add an
  end-to-end learned motion policy.
