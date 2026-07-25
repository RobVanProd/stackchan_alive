# Bridge AI Supervised Qualification

This run qualifies Conversation v2, persistent local STT, initiative, and room observation
against one exact firmware image and one exact clean source commit. It is a physical evidence
gate, not a source-test substitute.

## Safety And Privacy Boundary

- Keep an operator present and the robot body clear.
- Run the first qualification with motion, servo rail, and torque off.
- Do not flash, reboot, restart, or discard evidence automatically after a failure.
- Production qualification must use redacted turn logs and no microphone evidence directory.
- Room frames remain in memory only. No PGM, PNG, JPEG, WebP, or BMP file may appear in the
  evidence root.
- A conversation lease never grants motion, pairing, power, camera, or OTA authority.

## Start The Candidate

Use a planned restart window. The DirectML launcher starts or reuses the local RVC worker and
resident loopback whisper.cpp server, then replaces only a verified Stackchan bridge listener.
Room observation additionally requires a private camera pairing-code file and a loopback
vision-capable Ollama model.

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

- a stable 64-character firmware SHA-256 before and after;
- connected bridge/network state, the 50 ms display gate, and motion/rail/torque off;
- zero uplink, writer-drop, reply-window, playback, raw-speaker, or forced-stop deltas;
- zero host late-audio events or declared/received audio-count mismatches;
- three or more warm local audio turns meeting the under-3-second first-audio gate;
- authoritative playback drain before every reply window;
- the required conversation, initiative, room, privacy, and operator-observation evidence.

Only `bridge-ai-supervised-ready` is promotable. A different firmware SHA, dirty source tree,
failed check, or missing operator confirmation requires a new session; evidence does not transfer.
