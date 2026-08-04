# Bridge AI Supervised Qualification

This run qualifies Conversation v2, persistent local STT, initiative, and room observation
against one exact firmware image and one exact clean source commit. It is a physical evidence
gate, not a source-test substitute.

The bridge candidate does not alter firmware. Use the accepted working image from `main`, record
its SHA-256 before and after, and do not flash or rebuild the robot as part of this procedure.
The accepted image must be built from merged PR #217 (`10b0cc5404e072bb5784d9cfd2fabb0babd8a02e`)
or a later `main` commit. This includes PR #216's 12-second voice endpoint and PR #217's wake-gate
renewal plus strict `12 s endpoint < 13 s capture < 15 s privacy guard` ordering.
The older `ce66f8a0` accepted image is valid historical evidence but is not eligible for this
Conversation v2 qualification.
The shared `personas/` packs and their `bridge/persona_pack.py` loader are firmware build inputs,
so bridge-only conversation policies must stay in other host-only modules under `bridge/`; the
start gate rejects any firmware-input diff from `origin/main`.

## Safety And Privacy Boundary

- Keep an operator present and the robot body clear.
- Run the first qualification with motion, servo rail, and torque off.
- Treat the installed main firmware as immutable; this qualification starts no flash operation.
- Do not flash, reboot, restart, or discard evidence automatically after a failure.
- Production qualification must use redacted turn logs and no microphone evidence directory.
- Room frames remain in memory only. No PGM, PNG, JPEG, WebP, or BMP file may appear in the
  evidence root.
- A conversation lease never grants motion, pairing, power, camera, or OTA authority.

## Start The Candidate

Use a planned restart window. The DirectML launcher starts or reuses the local RVC worker and
starts a configuration-verified resident loopback whisper.cpp server, then replaces only a
verified Stackchan bridge listener. Production STT requires the local `small.en` model and prefers
the pinned Vulkan binary on the reference Windows host; prepare it before the window with
`tools\setup_whisper_cpp.ps1 -Backend vulkan -Model small.en`. The official BLAS binary is the
rollback when Vulkan is unavailable. Startup evidence must report `sttConfigVerified=true`,
`sttBackend=vulkan`, `sttBackendVerified=true`, `sttWarmupVerified=true`,
`sttModel=ggml-small.en.bin`, its pinned SHA-256, the executable SHA-256, and the intended thread
count. The tracked warmup must finish before readiness so cold shader initialization cannot be
charged to the first physical conversation turn.
Research is fail-closed: the launcher records a full local search/fetch preflight before starting
either worker or stopping an existing bridge. Start or verify the pinned loopback service first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\start_local_research.ps1 -Json
```

Room observation additionally requires a private camera pairing-code file and a loopback
vision-capable Ollama model. The installed `gemma4:e2b-it-qat` brain model is also vision-capable
and is the preferred room model because reusing it avoids a second resident model. The adapter
disables model thinking for its strict typed JSON response. Supplying the pairing file and room
model configures observation even when its initial state is off, so the dashboard can later enable
it without another restart. When face or room vision is enabled, the launcher starts the
hash-pinned local YuNet face worker and refuses readiness unless authenticated camera frame and
target counters advance. Use `-EnableFaceVision` to run face tracking while semantic observation
remains default-off.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\start_pc_brain_directml.ps1 `
  -EnableResearch `
  -EnableConversationV2 `
  -EnableInitiative `
  -EnableFaceVision `
  -EnableRoomObservation `
  -RoomVisionModel "<local-vision-model>" `
  -CameraPairingCodeFile "<private-pairing-code-file>" `
  -Json
```

Normal startup uses the resident STT endpoint, redacts transcript and response text in the turn
log, and does not persist microphone WAV files. Private audio evidence requires a separate,
explicit validation flow and is not admissible for this privacy qualification.
The dashboard must report the STT service configured, healthy, supervised, and not recovering.
Its restart and restart-failure counters must not advance during the qualification window.

## Open An Evidence Session

Run the command from the exact clean trusted source checkout after defining `$releaseToolchain` as
shown in `docs/RELEASE_PROCESS.md`. A downloaded or extracted archive does not confer release
authority.

This command is passive. It does not start, stop, restart, flash, or move the robot. It refuses
the session unless the live bridge has all candidate flags, local persistent STT, redacted logs,
no private audio evidence, a configured dashboard, and a connected motion-off robot.

```powershell
.\tools\start_bridge_ai_supervised_qualification.ps1 `
  -PackageZip "output\release\stackchan_alive_<exact-version>.zip" `
  -ExpectedFirmwareSha256 "<accepted-pr217-or-later-private-firmware-sha256>" `
  -ExpectedFirmwareSourceCommit "<accepted-pr217-or-later-main-source-commit>" `
  -OperatorPresent `
  -ConfirmMotionOff `
  -MinReplyWindows 100 `
  -Json `
  @releaseToolchain
```

Preserve the returned evidence-root path. During that one session:

1. Hold a natural multi-turn exchange from one wake.
2. Ask one current factual question that requires research and verify the spoken answer is
   grounded in the companion's cited result rather than an internet-access denial.
3. Ask what Stackchan sees, ask a deictic colour question, and confirm the first answer is grounded
   while the second truthfully reports the grayscale limitation.
4. Store one harmless memory, explicitly recall it, then change subjects and confirm that memory
   does not hijack unrelated turns.
5. Confirm a visible person is noticed without inventing identity, emotion, or private attributes.
6. Exercise an exit phrase, silence close, and physical over-speaker barge-in.
7. Observe at least 100 reply windows with no accepted echo.
8. Observe two initiative openers at least ten minutes apart, ignore both, and verify backoff.
9. Verify initiative is suppressed during configured night hours.
10. Collect at least two grounded room observations, disable observation, and confirm the summary
   clears.
11. Briefly remove and restore the bridge connection, confirming local face and wake behavior.
12. Confirm speech is complete and continuous, with no phrase-boundary gap or clipped tail.

## Complete The Session

Run completion only after speaker and microphone activity have drained. Every confirmation is an
operator-observed fact; do not pass a switch for an unobserved behavior.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\complete_bridge_ai_supervised_qualification.ps1 `
  -EvidenceRoot "<evidence-root>" `
  -EchoWindowsObserved 100 `
  -ConfirmOneWakeMultiTurn `
  -ConfirmConversationNatural `
  -ConfirmEchoFree `
  -ConfirmExitPhraseClosed `
  -ConfirmSilenceClosed `
  -ConfirmBargeInStoppedAudio `
  -ConfirmBridgeLossLocalRecovery `
  -ConfirmCleanCompleteAudio `
  -ConfirmResearchGrounded `
  -ConfirmVisualContextGrounded `
  -ConfirmGrayscaleLimitationTruthful `
  -ConfirmMemoryRecallAccurate `
  -ConfirmNoUnrelatedMemoryHijack `
  -ConfirmInitiativeNatural `
  -ConfirmInitiativeRateFloor `
  -ConfirmInitiativeIgnoredBackoff `
  -ConfirmInitiativeNightSuppressed `
  -ConfirmPersonNoticingGrounded `
  -ConfirmRoomContextGrounded `
  -ConfirmRoomOffCleared `
  -ConfirmNoFramePersisted `
  -Json
```

The checker requires:

- a verified clean release ZIP whose commit equals the clean source checkout and stamped live
  bridge runtime;
- a stable bridge PID and runtime manifest for the full session;
- the accepted main firmware SHA-256 and its distinct source commit, explicitly supplied to the
  start command, recorded together in unchanged `docs/FIRST_DEPLOY_STATUS.md`, and preserved in
  the evidence session;
- a robot-reported firmware SHA-256 that equals that accepted main image before and after, with
  the running app confirmed. The bridge package's bundled firmware is not the qualification
  target and is never flashed by this procedure;
- connected bridge/network state, the 50 ms display gate, and motion/rail/torque off;
- zero uplink, MWW-submit/drop, capture-failure, writer-drop, reply-window, playback, audio-stop,
  raw-speaker, or forced-stop deltas, with every required counter present;
- zero host late-audio events or declared/received audio-count mismatches;
- no unrecovered response-wire overlap, sequence mismatch, or missing end;
- redacted turn-log proof of one cited research route, one fresh on-demand visual observation, the
  deterministic grayscale colour guard, and deterministic memory recall;
- advancing authenticated host-vision frame, target, face, and camera-event counters with zero new
  frame or pairing failures;
- three or more warm local audio turns meeting the under-3-second first-audio gate;
- three or more streaming turns with at least 25 ms of configured downlink pacing headroom;
- authoritative playback drain before every reply window;
- the required natural conversation, research, visual, memory, person-noticing, initiative, room,
  privacy, and operator-observation evidence.

Only `bridge-ai-supervised-ready` is promotable. A different accepted-main firmware SHA,
unrecorded firmware source commit, package/source/runtime commit mismatch, restarted bridge,
dirty source tree, failed check, or missing operator confirmation requires a new session;
evidence does not transfer.
