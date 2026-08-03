# Project State

State timestamp: 2026-08-02 America/New_York

## Current Objective

Keep stop-ship security work ahead of aliveness features. Milestone 0 and the independently
verified `SEC-001` host admission repair are committed. `SEC-001` remains contained and undeployed.
The active working-tree candidate implements the preregistered, credential-free `SEC-002` firmware
HTTP policy: public HTTP may serve bounded operational status and emergency stops, while every
other mutating control fails closed before side effects. The directly coupled dashboard and
actuator-validation tools represent that restriction fail-closed. This is source, test, simulator,
secret-free compilation, and dirty-tree package-regression evidence only. Independent policy,
security, and documentation reviewers accepted the source slice. It is undeployed and physically
unqualified. No production service, installed firmware, or live robot behavior has been changed for
`SEC-002`.

## Source Identity

- Repository: `RobVanProd/stackchan_alive`
- Working branch: `codex/aliveness-repository-truth`
- Current committed HEAD before the atomic `SEC-002` implementation commit:
  `2ed5bb6ad4755129b61aa0f636f0b654a3493d86`
- Frozen `SEC-002` preregistration baseline:
  `d75c62f37f8ff6e1c6cf49bc2c4c01479cd4f02f`
- Fetched `origin/main`: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
- Milestone 0 documentation baseline commit: `0e3467e79766ed1cafeef4837c162c8a50bb29e1`
- SEC-001 identity: commit `9c72f02091dc471f27e3c9bfff5e4af6e32e7134`, exact accepted tree
  `28a62773ee67103cd3f57f6cb93c0db6afbe143a`.
- Verification scope: native firmware logic, host bridge tests, silent trusted-facts routing,
  secret-free release compilation through the documented isolated pioarduino core, and three
  release/evidence contract suites.
- Physical verification is not transferred to this host/documentation commit.

The pre-existing checkout remains on `agent/away-cloudflare-bridge` at `269b11be`. It was not
switched because live services use that checkout. Milestone 0 work uses the isolated worktree at
`output/worktrees/aliveness-repository-truth`.

## Active Hypothesis

Selected experiment: `SEC-002`, fixed emergency-stop-only admission on the firmware debug HTTP
server, plus `PRIV-001` denial of its unauthenticated wake-microphone PCM export.

- **Observed behavior:** Port 8789 ignores the HTTP method, defaults malformed requests to `/`,
  dispatches camera paths before any common admission decision, applies tone/wake-reset/motion-
  enable/recovery/reboot effects before responding, returns generic status for unknown paths, and
  echoes the raw request target. `/wake.wav` and `/wake-pcm.wav` return recent microphone-ring PCM
  without the camera pairing gate. These are source observations; unsafe routes and PCM were not
  exercised on hardware.
- **Primary hypothesis:** One Arduino-free, exhaustive request-line/route policy invoked before
  dispatch can reduce admitted unauthenticated mutating operations to emergency audio/motion stop
  only, deny the PCM export, retain bounded status and paired camera behavior, and expose a
  non-secret `emergency_stop_only` capability without changing OTA or autonomous recovery logic.
- **Falsification:** Any denied route reaches a side effect; any malformed/query/prefix/suffix case
  falls through to status; any query-free `GET` emergency stop used by maintained clients is lost;
  paired camera or OTA behavior changes; a build profile bypasses the policy; any sink leaks raw
  request/query/pairing/authorization material; or the repair requires a credential, pairing-file
  transport, or hardware action before source gates.
- **Frozen baseline:** Commit `9c72f020`, the contained production bridge, installed firmware of
  unknown SHA-256, voice/vision/model workers, port-8790 OTA authorization, camera pairing grammar,
  automatic offline recovery supervisor, 50 ms face gate, actuator ownership, and physical
  evidence.
- **Rollback:** Revert only the atomic `SEC-002` source/client compatibility commit. Do not restore
  an insecure listener or flash the prior image as an automatic fallback; isolate or power off the
  robot and preserve evidence.

The reproducible-build and memory-authorization hypotheses remain queued P0 work; stop-ship
transport/control/privacy containment takes precedence without reordering later aliveness work.

## SEC-002 / PRIV-001 Frozen Preregistration

This preregistration is written against clean commit `9c72f020` before expected-red tests,
production-source changes, compilation, or device action. It introduces no authentication scheme.
Future authenticated resume/recovery authority, credentials, and pairing-file transport require a
separate preregistration.

The common policy must strictly parse `METHOD SP request-target SP HTTP-version` with exactly three
tokens, an uppercase bounded method token, an origin-form target beginning `/`, and exact version
`HTTP/1.0` or `HTTP/1.1`. A missing/extra token, unsupported version, control byte, incomplete line,
or non-origin target is malformed. Target truncation/overflow is distinct. Classification occurs
before camera dispatch or any existing effect:

- `GET /` and `GET /debug`, with no query, serve the existing bounded status classes.
- Exact `GET` or `POST` to `/audio-stop`, `/playback-stop`, `/motion-stop`, `/motion-off`, or
  `/servos-off`, with no query, may request an emergency stop. These five aliases and methods define
  supported unauthenticated stop availability. The baseline's accidental acceptance of other
  methods is not an availability guarantee. An admitted stop returns `202` with bounded
  `accepted:true`; a failed motion-stop queue publication returns `503` with `accepted:false`.
  Neither response claims physical completion.
- Query-bearing `GET /camera-gray.pgm?...` and `GET /vision-target?...` syntactic families route to
  the existing parser/authorizer unchanged. Its successful exact paired forms remain
  `/camera-gray.pgm?p=NNNNNN` and `/vision-target?p=NNNNNN&f=...`; malformed queries retain their
  current camera-specific `400`/`403` and auth-counter behavior. No capture or target submission is
  reachable before the existing pairing check. Wrong methods are rejected by the common policy.
- `/tone`, `/speaker-test`, `/mic-tone`, `/mic-tone-soft`, `/mic-tone-tap`, `/mic-tone-old`,
  `/wake-reset`, `/motion-resume`, `/motion-on`, `/servos-on`, `/recover`, `/bridge-recover`,
  `/wifi-recover`, `/reboot`, `/restart`, and `/reset` return `403` before side effects for every
  method and query.
- `/wake.wav` and `/wake-pcm.wav` also return `403` before reading the PCM ring, constructing a WAV
  response, or exporting bytes for every method and query. No test may request, store, print,
  fixture, or inspect wake PCM.
- Known allowed paths with a wrong method return `405`; malformed request lines return `400`;
  oversize targets return `414`; unknown exact paths return `404`. Outside the two camera syntactic
  families above, query, suffix, prefix, trailing-slash, fragment, encoded-alias, and truncated
  near-misses never dispatch or fall through to `/`.
- Denial responses are small, fixed-shape JSON. Status telemetry reports only bounded method/route/
  result enums and counters. Responses, status, serial logs, diagnostic fields, counters, evidence,
  test output, and every other sink must never emit a raw target, query, pairing code, authorization
  header, or credential-derived value.

Expected-red evidence must be demonstrated and preserved before implementation. First rerun
`pio test -e native_logic` unchanged and require the pre-existing 289/289 baseline. Then add only
the frozen tests/contracts and run these exact gates:

- `pio test -e native_logic` must fail with the new
  `test_bridge_debug_http_policy_*` cases unable to find the preregistered shared policy, not with a
  toolchain, dependency, syntax, collection, or pre-existing-test failure;
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  tools\test_firmware_http_control_policy_contract.ps1` must exit nonzero on its named mandatory-
  policy/pre-effect assertion across all 19 effective Wi-Fi environments, not because the command,
  file, dependency, or parser is unavailable;
- selected `bridge.test_dashboard_service.DashboardRuntimeTests.test_*motion_resume*policy*` cases
  must fail their missing/`emergency_stop_only` fail-closed assertions, not test setup or discovery;
- dashboard, camera-follow, warm-soak, full-system-soak, and wake-watcher contracts must exit
  nonzero on their named capability-preflight/refusal assertions, not unrelated syntax or fixture
  failures.

Any other red is rejected, preserved as separate evidence, and does not authorize implementation.

The capability contract is exact: firmware `/debug` emits
`"debug_http_control_policy":"emergency_stop_only"`. The dashboard projects only bounded
`motionResumeAvailable:false` and `motionResumePolicy:"emergency_stop_only"|"unknown"`. Missing,
unknown, malformed, or older-than-15-seconds capability is `unknown` and fail-closed. Resume refusal
occurs before `_fetch_robot`; Stop never depends on that capability and keeps its existing off-state
verification.

Implementation is limited to:

- `src/io/BridgeDebugHttpPolicy.hpp`, `src/io/BridgeDebugHttpPolicy.cpp`, `src/main.cpp`,
  `platformio.ini`, and `test/test_native_logic/test_main.cpp`;
- `bridge/dashboard_service.py`, `bridge/test_dashboard_service.py`, and `bridge/dashboard/app.js`;
- `tools/test_firmware_http_control_policy_contract.ps1`,
  `tools/test_stackchan_dashboard_launcher_contract.ps1`,
  `tools/camera_follow_wake_validation.ps1`,
  `tools/test_camera_follow_wake_validation_contract.ps1`,
  `tools/run_full_system_soak_http_motion.ps1`,
  `tools/start_warm_rocm_full_system_soak.ps1`,
  `tools/test_start_warm_rocm_full_system_soak_contract.ps1`,
  `tools/watch_stackchan_wake_test.ps1`, and `tools/verify_release_package.ps1`;
- `PROJECT_STATE.md`, `TASK_LEDGER.md`, `INITIAL_RISK_REGISTER.md`, `docs/BRIDGE_PROTOCOL.md`,
  `docs/BRIDGE_DASHBOARD.md`, and `docs/ARRIVAL_DAY_RUNBOOK.md`.

No other file may change without a preserved expected-red result showing direct coupling and an
independent scope review. In particular, the policy must not disable or condition the autonomous
offline recovery supervisor, change port-8790 OTA, reuse camera pairing as general control auth,
weaken a stop, change actuator coordination, or touch a private value.

`bridge/dashboard/index.html` remains explicitly unchanged: its Resume button already starts
disabled. Tests must prove the service and both JavaScript re-enable paths require an explicit
available capability; changing the markup requires the documented scope-expansion gate.

Test-to-tool ownership is frozen. `tools/test_stackchan_dashboard_launcher_contract.ps1` covers the
dashboard service and both JavaScript enable paths;
`tools/test_camera_follow_wake_validation_contract.ps1` covers its paired script;
`tools/test_start_warm_rocm_full_system_soak_contract.ps1` covers the warm wrapper; and the new
`tools/test_firmware_http_control_policy_contract.ps1` cross-checks those plus
`run_full_system_soak_http_motion.ps1` and `watch_stackchan_wake_test.ps1`. Every changed tool must
read the exact capability from `/debug` first; missing/unknown/contained policy must abort before
Resume, wake-reset, tone, process/service launch, or evidence-runner start; it must not relabel the
refusal as pass, fall back to a denied alias, or read pairing material. Emergency motion-stop cleanup
remains callable. The wake watcher switches its operational read from the accidental `/status`
fallback to exact `/debug` and can run observation-only only with reset/tone disabled.

Acceptance order is fixed: expected red; focused then full native tests; all 19 Wi-Fi-profile source/
config contract cases; dashboard and operator-tool contracts; full isolated bridge suite; silent
trusted-facts privacy smoke; the existing no-hardware prearrival simulator as a general regression
proxy that does not prove port-8789; secret-free `stackchan_release_full` compilation and package
verifier. Those gates can accept only the source candidate. Deployment and `R-000B`/`R-000C` risk
closure additionally require an independently approved and executed exact-image no-motion run,
supervised physical emergency-stop proof, and final release gates with exact source/binary identity.
No flash, OTA, reboot, endpoint mutation, or physical motion is authorized by source success.
Supervised resume and motion-soak workflows remain blocked until separately authenticated/local
authority is designed.

Hard stop the candidate if expected red does not fail on its named security assertion; a maintained
consumer falls back or treats refusal as success; an unlisted file changes without the documented
scope-expansion review; microphone capture, wake gating, or the wake model changes; exact source and
binary identity are unavailable before no-motion qualification; or deployment/risk closure is
claimed before exact-image physical and release gates.

## SEC-002 / PRIV-001 Source Candidate Result

The preregistered expected-red phase was preserved before implementation: native policy tests
failed only because the shared policy did not yet exist; dashboard cases failed their named
missing/contained-capability assertions; and the firmware/tool contract cases failed their named
policy/preflight assertions. The current uncommitted candidate then earned the following
non-physical evidence on 2026-08-02:

- native firmware logic passed 294/294;
- the focused dashboard service suite passed 28 tests and full bridge discovery passed 567 tests;
- the exact firmware HTTP policy contract passed all 19 effective Wi-Fi environments;
- dashboard, camera-follow, warm-soak, full-system-soak evidence, current-lead reproducibility v2,
  and current-lead archive contracts passed;
- the silent trusted-facts privacy smoke returned ready with zero model invocations and zero audio
  playback, without printing stored fact values;
- the no-hardware simulator reported `stackchan.hardware-sim.v1` status `pass`; this does not prove
  port 8789, deployment, or physical behavior; and
- `stackchan_release_full` completed compilation, link, size analysis, bootloader/partition/app
  image generation, and produced a 2,803,375-byte application image report. Windows Device Guard
  rejected PlatformIO's generated console-script executable, so the same pinned esptool 5.1.0
  package was invoked through PlatformIO's Python interpreter for this isolated build. No upload
  target was invoked.

Dirty-tree release-package assembly and verification passed after the conversation-harness package
prerequisite was committed separately as `2ed5bb6a`; independent policy, security, and
documentation/authority reviews accepted the exact source slice. The regression build and package
predate the final atomic source commit and are not exact-image candidates for deployment. `R-000B`
and `R-000C` remain open until a clean committed source identity has matching binary/package hashes,
independently approved exact-image no-motion qualification, supervised physical emergency-stop
evidence, and final release gates all pass.

## SEC-001 Frozen Preregistration

This preregistration was reviewed read-only against exact source `39b750e6` before any source or
launcher implementation. Firmware sends no application-side client hello. Admission therefore
completes at the bounded HTTP upgrade, and `X-Stackchan-Device` is never treated as a brain-owner
endpoint or cryptographic identity.

Expected failing tests on the frozen baseline, to be added and demonstrated red before repair:

- `test_admission_rejects_non_bridge_path`
- `test_admission_rejects_missing_or_wrong_protocol`
- `test_admission_rejects_blank_or_invalid_device`
- `test_admission_rejects_browser_origin`
- `test_non_loopback_config_requires_robot_peer`
- `test_admission_rejects_wrong_peer_before_dispatch`
- `test_unadmitted_session_rejects_protected_message`
- `test_owner_gate_rejects_blank_endpoint_when_owner_exists`
- `test_invalid_attempt_does_not_consume_once_recovery`

Compatibility tests that must remain or become green without firmware changes:

- `test_admission_accepts_exact_firmware_upgrade`
- `test_loopback_default_allows_firmware_without_configured_peer`
- `test_valid_firmware_disconnect_and_reconnect_receives_hello`
- existing WebSocket handshake, streaming, cancellation, bridge, native firmware, silent trusted-
  facts, DirectML launcher, and dashboard launcher contracts.

The raw valid fixture is exactly `GET /bridge HTTP/1.1`, WebSocket upgrade/version/key fields,
`X-Stackchan-Protocol: stackchan.bridge.v1`, one normalized nonblank device value of at most 64
characters, and no `Origin`. Security-critical duplicate headers fail closed. A non-loopback bind
requires `RobotHost`; it is resolved once before accept, and the normalized frozen address set is
checked before reading or dispatching a request. Invalid attempts close before `101` and do not
consume `--once`; a later valid firmware connection receives the existing immediate server hello.
The general launcher becomes loopback-default. Every maintained robot-facing wrapper opts into
`0.0.0.0` with an early nonblank `DeviceHost` guard and an explicit frozen robot peer; runtime
certification requires the same peer argument. Scoped and link-local IPv6 peers fail closed in
this IPv4-bound slice.

Frozen implementation files are `bridge/lan_service.py`, `bridge/test_lan_service.py`,
`bridge/lan_smoke.py`, `bridge/test_dashboard_service.py`,
`tools/start_pc_brain.ps1`, `tools/start_pc_brain_directml.ps1`,
`tools/restore_voice_v2_production.ps1`, `tools/run_selected_voice_once.ps1`,
`tools/start_voice_v2_supervised_validation.ps1`,
`tools/start_warm_rocm_full_system_soak.ps1`, `tools/check_pc_brain_runtime.ps1`,
`tools/test_pc_brain_runtime_check_contract.ps1`,
`tools/test_start_pc_brain_directml_contract.ps1`,
`tools/test_stackchan_dashboard_launcher_contract.ps1`, `docs/BRIDGE_PROTOCOL.md`,
`docs/RELEASE_QUICKSTART.md`, `docs/ARRIVAL_DAY_RUNBOOK.md`, `docs/BRIDGE_DASHBOARD.md`, and
`bridge/README.md`. These scope expansions were independently approved only after focused/broad
tests and security review exposed directly coupled compatibility gaps. Rollback is
reversion of the single atomic host-side commit while keeping the non-loopback service stopped.
Stop on any valid-firmware incompatibility, post-admission output change, need for private data or
new wire semantics, unfrozen DNS behavior, hardware access, or live-service restart.

The expected-red phase exposed one maintained synthetic-smoke dependency before production code was
edited: `bridge/lan_smoke.py` emits the legacy headerless request directly into
`handle_connection`. The independent preregistration reviewer approved adding only that file and
only to use the current firmware protocol/device headers (and an already available peer address if
the final seam requires it). A compatibility bypass or permissive flag is forbidden.

The first broad bridge run exposed the same legacy synthetic request in
`bridge/test_dashboard_service.py`; strict admission rejected it and, correctly, did not consume
`once`, so the run was terminated while the server awaited a valid client. The same independent
reviewer approved adding only the current firmware protocol/device headers to that fixture. No
timeout, `once`, validator, or compatibility bypass is allowed.

Preregistration metric fields:

- **Fixture:** `bridge/test_lan_service.py::firmware_upgrade_request`, version
  `sec001-firmware-upgrade-v1`, a field-for-field request-shape fixture traced to
  `src/io/BridgeWebSocketTransport.cpp::buildHandshakeRequest`. It uses the current firmware
  default key `c3RhY2tjaGFuLWZpcm13YXJlLWtleQ==`; host formatting is synthetic/configuration-
  dependent, and only synthetic device IDs are used.
- **Baseline/version:** exact source `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`; the nine named
  rejection tests above are expected to fail for the recorded reasons, while the raw current
  firmware request shape is source-observed.
- **Seed:** not applicable; the validator, peer matrix, and socket sequences are deterministic.
- **Trials:** one execution per named matrix row in the focused red run; after repair, one complete
  focused module run, one complete bridge discovery run, one native logic run, and one run of each
  named launcher contract. Any failure stops the slice rather than being averaged.
- **Artifacts:** ignored, synthetic-only logs under `output/private/sec-001/` named
  `prereg-red.txt`, `focused-green.txt`, `bridge-green.txt`, `native-green.txt`, and
  `launcher-green.txt`; no live/private values, packets, audio, camera data, or credentials.

## Physical Firmware Identity

- Current installed firmware SHA-256: **unknown from live evidence at this audit timestamp**.
- Latest accepted exact-image record in the authoritative deployment documents: source commit
  `ce66f8a0fadfadbc07eb59124522267ba66ee70a`, firmware SHA-256
  `69d3db27f2d7197799fdc08ff3c1dc4d6e3011724fe29899367dc016e48ebfa8`, with a formally checked
  28,807-second all-feature actuator soak.
- That documented hash is historical accepted evidence, not a claim about what is currently
  reachable or installed. Direct `/debug` was unavailable during the current snapshot, so no
  live hash binding is asserted.

## Active Bridge Source And Services

Initial observed Windows processes, before the explicitly authorized security containment:

- PC bridge/dashboard: PID `14648`, launched 2026-07-31 00:12 local, running relative
  `bridge/lan_service.py` from the pre-existing checkout with Gemma, Whisper, DirectML RVC,
  Conversation v2, episode distillation, initiative, room observation, and loopback dashboard
  flags. Because the command uses a relative script path, the exact loaded source commit is not
  proven by process metadata; the checkout currently points at `269b11be` based on local-main
  commit `36acc0c7`.
- DirectML RVC worker process pair: PIDs `36132` and `26576`, explicit source/model paths under
  `output/worktrees/natural-research-voice`; loopback health at port `5059` reports
  `ready=true`, schema `stackchan.rvc-directml-worker.health.v1`, no last error.
- Vision service process pair: PIDs `45004` and `22668`, local paired-camera worker targeting
  `192.168.1.238:8789` with a private pairing-code file. No pairing value was read or printed.
- No PlatformIO, qualification, motion-refresh, or soak runner was found in the process scan.

Containment update on 2026-08-02:

- AUDIT-09 confirmed that the PC bridge's production launcher binds on all interfaces while its
  WebSocket admission and pre-hello sensitive-message boundary are fail-open.
- With user authorization, PID `14648` was stopped only after a final check found zero established
  clients and only its `0.0.0.0:8765` and `127.0.0.1:8766` listeners. Both listeners closed.
- Two user-started replacement `lan_service.py` processes (`42344` and `47448`) exited without
  acquiring the LAN listener. No bridge process currently owns ports `8765`/`8766` on all
  interfaces.
- An unrelated older Python process, PID `27748`, listens only on loopback `127.0.0.1:8765`; it was
  not changed. Voice and vision workers remain running and untouched.
- The user powered the robot, but bounded `/debug` and TCP `8789` checks still did not establish
  reachability. The robot was not rebooted, flashed, moved, or sent a control request.

## Current Live-State Evidence

Bounded read-only snapshot on 2026-08-02:

- Robot `/debug`: three five-second attempts failed with `WebException`.
- Ping and TCP port `8789`: failed in the bounded probe.
- Bridge PID `14648`: listeners exist on `0.0.0.0:8765` and `127.0.0.1:8766`; no established
  robot TCP connection was present.
- Dashboard: reachable on loopback and reports bridge uptime about 231,001 seconds, model/STT/
  voice/playback health, but also reports `robot.connected=true`, `networkState=connected`, and
  `bridgeState=ready` from a last heartbeat approximately 64,909 seconds old.
- Dashboard last-known actuator state is motion off, rail off, torque off, with last reason
  `manual_stop`. This is stale last-known state, not current device proof.
- Room observation is enabled but stale, with `camera_unavailable` as its last aggregate error;
  initiative reports stale presence and zero curiosity score.

The stale dashboard snapshot above was captured before containment. Its service is now stopped; it
remains evidence of the presentation defect rather than current status.

Observed conclusion: robot reachability is not established, and the dashboard is not expiring its
connected/ready presentation when heartbeat/socket evidence becomes stale. Do not relabel this as
a robot freeze, blackout, brownout, thermal event, USB failure, board failure, or power failure.

## Known Faults

1. The last observed production host service exposed a fail-open robot-to-host WebSocket admission
   boundary on the LAN. Commit `9c72f020` repairs those source paths, but is not deployed on the
   production listener or robot; the previously exposed listener remains stopped.
2. The last source-observed Wi-Fi firmware baseline allowed unauthenticated debug HTTP tone,
   mic-tone, wake-reset, motion-enable, recovery, and reboot aliases to reach effects before
   response; the installed-image identity remains unknown. The accepted working-tree candidate
   contains those routes before effects while preserving public emergency audio/motion stops, but
   it is undeployed and physically unqualified. Unsafe routes were not exercised on hardware; OTA
   remains separately token-gated.
3. The last source-observed baseline allowed `/wake.wav` and `/wake-pcm.wav` to export recent
   wake-microphone PCM without pairing, and the installed-image identity remains unknown. The
   accepted working-tree candidate denies both aliases before PCM access, but it is undeployed and
   physically unqualified. No PCM was requested or inspected.
4. Dashboard connection/readiness state can remain affirmative after the heartbeat is stale and
   the bridge has no established robot socket.
5. The exact AGENTS baseline command through the default shared PlatformIO core fails before
   source compilation because the pioarduino framework directory is absent. The same environment
   builds successfully when the documented `C:\spio\pioarduino` core is pinned.
6. Ordinary valid model output can currently authorize an unprompted durable write or wildcard
   forget; generic third-party private details can evade the finite sensitive-name filter.
7. A due callback can displace an unrelated user request, and explicit topic recall can choose the
   newest unrelated episode.
8. Playback failure can strand host Conversation v2 in `SPEAKING`; model/TTS recovery can disagree
   with the firmware wake gate; and the 10-second host lease is shorter than the allowed 12-second
   firmware utterance.
9. Release firmware initializes synthetic demo affect events enabled; phrase streaming clamps
   signed negative valence to zero; semantic manipulation paraphrases bypass the current lexical
   relationship validator.
10. Repeated face-lost updates can retain a historical face size while refreshing its timestamp,
   causing a false-current presence bit; stale room state can still permit personal projection.
11. Initiative power/thermal suppression fields are not present in the production heartbeat, and
   an in-flight initiative is not revalidated on a later sleep/safety/presence transition.

Documentation baseline status: required project-control/longitudinal documents and reconciled
status claims now exist in the isolated worktree and passed the final independent review. They
were committed atomically as `0e3467e79766ed1cafeef4837c162c8a50bb29e1`; this is repository
control evidence, not physical qualification.

## Known Regressions

Committed `SEC-001` changes host admission, launcher defaults, robot-facing wrappers, and runtime
certification. It has not been deployed or started on the production
listener or robot; the isolated alternate-port checks were started and stopped as recorded below.
The exposed production PC bridge remains intentionally stopped; current deployed firmware
therefore still has no verified host admission repair, and its exact installed SHA remains unknown.
This containment is not a hidden regression. Voice/vision workers and robot firmware were not changed. Physical affect,
perception, initiative, Conversation v2, over-speaker barge-in, echo rejection, and a current
exact-image no-motion conversation soak remain unqualified rather than failed.

## Baseline Evidence

- Native logic: 289/289 passed.
- Bridge suite: 543/543 passed.
- Trusted-facts smoke: ready, 19 routed cases, 10 passthrough cases, zero model calls, zero audio,
  no stored fact values printed.
- `stackchan_release_full`: passed under the documented isolated pioarduino core; output size
  2,803,216 bytes, SHA-256
  `8A76CA8030B3CD0C06C76C2A869C42B960E6864E7C5D7CC6A339E918FB1BB756`.
- Full-system-soak evidence contract: passed.
- Current-lead reproducibility v2 contract: passed.
- Current-lead archive contract: passed.
- Branch/PR evidence: `BRANCH_LEDGER.md`.

## SEC-001 Committed Evidence

The live checks below and the first matrix were observed on 2026-08-02 in the isolated working tree
based at `0e3467e7`. The final self-identifying staged-tree matrix repeated the applicable gates and
is stored with hashed logs under ignored `output/private/sec-001/final-<tree>/`. The containing Git
commit and final handoff provide the durable source identity. None of this evidence identifies or
qualifies the installed firmware or authorizes a service restart.

- Focused LAN service: 115/115 passed, including actual-firmware-key compatibility,
  invalid-invalid-valid `once` recovery, and wrong-peer no-dispatch/state-mutation recovery.
- Full bridge discovery: 559/559 passed after the CLI-abbreviation test was added.
- Deterministic LAN smoke: five/five scenarios passed with fake local engines.
- Native firmware logic: 289/289 passed; no firmware source file changed.
- DirectML launcher, dashboard launcher, and PC-brain runtime-certification contracts: passed.
- Trusted-facts smoke: ready, 19 routed and 10 passthrough cases, zero model invocations, zero
  audio played, and no stored fact values printed.
- Secret-free `stackchan_release_full` compilation: passed in `C:\spio\pioarduino`; the dirty-tree
  build is 2,803,248 bytes with SHA-256
  `602D1F75C45A754217116D72174E22621593817FD48D219504E9B82565DCC4A8`. This is compilation
  evidence only and is not a physical or reproducibility claim.
- Full-system-soak evidence, current-lead reproducibility v2, and current-lead archive contracts:
  passed with synthetic fixtures.
- User-authorized live local-runner check on isolated loopback port `18765`: the candidate accepted
  the current firmware-shaped handshake, completed endpoint registration/claim, invoked the
  installed `gemma4:e2b-it-qat` Ollama model, returned the full `thinking` through `response_end`
  sequence in 2,097.7 ms, and exited cleanly under `once`. Audio downlink was disabled, the prompt
  was synthetic, and no durable memory file was configured.
- User-authorized live OS-socket peer check on isolated port `18766`: a real `0.0.0.0` candidate
  listener frozen to robot peer `192.168.1.238` rejected the actual loopback client before
  handshake, remained listening under `once`, and was then stopped by exact PID. This proves the
  local wrong-peer path, not robot reachability or network-attacker resistance. Evidence remains
  ignored under `output/private/sec-001/`.

## Exact Next Action

Create the one atomic `SEC-002`/`PRIV-001` implementation commit containing this record, rerun the
exact source gates, and produce clean source/binary/package identities from that commit. Do not
design credentials or read a pairing file. Production restart and every firmware/hardware action
remain unauthorized until a separately approved exact-image no-motion qualification, supervised
emergency-stop proof, and final release gates are earned.

## Unauthorized Actions

- No firmware flash, OTA, reboot, recovery, wake reset, serial command, robot endpoint write,
  motion resume, motion refresh, or actuator test.
- No restart or replacement of the contained PC bridge until the selected admission repair passes;
  voice, vision, model, and the unrelated loopback service remain frozen. The one bridge
  termination above was explicitly authorized after the stop-ship finding and is now recorded.
- No release publication, tag, push, PR mutation, branch deletion, force-push, or evidence deletion.
- No wake-WAV request, raw microphone read/inspection, pairing-code read or file transport, or
  fallback from a denied HTTP control.
- No remote/Away infrastructure, credential, pairing, privacy-policy, sensitive-memory,
  identity-recognition, always-listening, cloud-required, or model-physical-authority work.
- No human study, paid service, destructive hardware action, or cross-repository modification.

## Rollback Path

`SEC-001` rollback is reversion of exact commit `9c72f020`; keep the exposed listener stopped rather
than restoring a fail-open fallback. `SEC-002` preregistration and its current implementation remain
separate atomic changes and are reverted only by exact commit if a frozen invariant regresses. Do
not flash an insecure prior image as an operational rollback. Hardware rollback remains the exact
private accepted archive/runbook procedure and is not exercised without source, build, no-motion,
physical, and exact-image gates.
