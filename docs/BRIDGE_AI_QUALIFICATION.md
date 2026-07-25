# Bridge AI Supervised Qualification

This run qualifies Conversation v2, persistent local STT, initiative, and room observation
against one exact firmware image and one exact clean source commit. It is a physical evidence
gate, not a source-test substitute.

The bridge candidate does not alter firmware. Use the accepted working image from `main`, record
its SHA-256 before and after, and do not flash or rebuild the robot as part of this procedure.
The shared `personas/` packs are firmware build inputs, so bridge-only conversation policies must
stay under `bridge/`; the start gate rejects any firmware-input diff from `origin/main`.

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
resident loopback whisper.cpp server, then replaces only a verified Stackchan bridge listener.
Room observation additionally requires a private camera pairing-code file and a loopback
vision-capable Ollama model. When room observation is enabled, the launcher also starts the
hash-pinned local YuNet face worker and refuses readiness unless authenticated camera frame and
target counters advance. Use `-EnableFaceVision` to run face tracking without room observation.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\start_pc_brain_directml.ps1 `
  -EnableResearch `
  -EnableConversationV2 `
  -EnableInitiative `
  -EnableRoomObservation `
  -RoomVisionModel "<local-vision-model>" `
  -CameraPairingCodeFile "<private-pairing-code-file>" `
  -Json
```

Normal startup uses the resident STT endpoint, redacts transcript and response text in the turn
log, and does not persist microphone WAV files. Private audio evidence requires a separate,
explicit validation flow and is not admissible for this privacy qualification.

## Open An Evidence Session

This command is passive. It does not start, stop, restart, flash, or move the robot. It refuses
the session unless the live bridge has all candidate flags, local persistent STT, redacted logs,
no private audio evidence, a configured dashboard, and a connected motion-off robot.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\start_bridge_ai_supervised_qualification.ps1 `
  -PackageZip "output\release\stackchan_alive_<exact-version>.zip" `
  -ExpectedFirmwareSha256 "69d3db27f2d7197799fdc08ff3c1dc4d6e3011724fe29899367dc016e48ebfa8" `
  -ExpectedFirmwareSourceCommit "ce66f8a0fadfadbc07eb59124522267ba66ee70a" `
  -OperatorPresent `
  -ConfirmMotionOff `
  -MinReplyWindows 100 `
  -Json
```

Preserve the returned evidence-root path. During that one session:

1. Hold a natural multi-turn exchange from one wake.
2. Exercise an exit phrase, silence close, and physical over-speaker barge-in.
3. Observe at least 100 reply windows with no accepted echo.
4. Observe two initiative openers at least ten minutes apart, ignore both, and verify backoff.
5. Verify initiative is suppressed during configured night hours.
6. Collect at least two grounded room observations, disable observation, and confirm the summary
   clears.
7. Briefly remove and restore the bridge connection, confirming local face and wake behavior.
8. Confirm speech is complete and continuous, with no phrase-boundary gap or clipped tail.

## Complete The Session

Run completion only after speaker and microphone activity have drained. Every confirmation is an
operator-observed fact; do not pass a switch for an unobserved behavior.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\complete_bridge_ai_supervised_qualification.ps1 `
  -EvidenceRoot "<evidence-root>" `
  -EchoWindowsObserved 100 `
  -ConfirmOneWakeMultiTurn `
  -ConfirmEchoFree `
  -ConfirmExitPhraseClosed `
  -ConfirmSilenceClosed `
  -ConfirmBargeInStoppedAudio `
  -ConfirmBridgeLossLocalRecovery `
  -ConfirmCleanCompleteAudio `
  -ConfirmInitiativeNatural `
  -ConfirmInitiativeRateFloor `
  -ConfirmInitiativeIgnoredBackoff `
  -ConfirmInitiativeNightSuppressed `
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
- zero uplink, writer-drop, reply-window, playback, raw-speaker, or forced-stop deltas;
- zero host late-audio events or declared/received audio-count mismatches;
- no unrecovered response-wire overlap, sequence mismatch, or missing end;
- advancing authenticated host-vision frame, target, face, and camera-event counters with zero new
  frame or pairing failures;
- three or more warm local audio turns meeting the under-3-second first-audio gate;
- three or more streaming turns with at least 25 ms of configured downlink pacing headroom;
- authoritative playback drain before every reply window;
- the required conversation, initiative, room, privacy, and operator-observation evidence.

Only `bridge-ai-supervised-ready` is promotable. A different accepted-main firmware SHA,
unrecorded firmware source commit, package/source/runtime commit mismatch, restarted bridge,
dirty source tree, failed check, or missing operator confirmation requires a new session;
evidence does not transfer.
