# Play Screenshot Capture Plan

Capture final Google Play screenshots from the signed Android build after physical robot
validation. Do not use simulator mockups for the public listing.

## Capture Rules

- Use the final internal-testing or release-candidate build for every screenshot.
- Capture on a physical Android phone with status and navigation bars visible and respected.
- Show the square Stack-chan display face used by the robot/app, not the early rectangular
  placeholder.
- Hide pairing secrets, local IPs, Wi-Fi passwords, and raw diagnostics before upload.
- Keep screenshots free of debug overlays, test toasts, and partial loading states.
- Record the phone model, Android version, app version, source commit, and AAB SHA-256 in
  `PLAY_STORE_EVIDENCE.json`.

## Required Shots

1. `phone-pairing-setup`
   - Screen: Nodes / setup.
   - Must show the guided pairing flow, short code or QR ticket, saved robot add/remove
     affordance, and the current next step for a first-time user.
   - State: no physical secrets visible; bridge is running or clearly ready.

2. `phone-live-dashboard`
   - Screen: Live robot stage.
   - Must show a connected robot session with robot identity or connection status, square
     Stack-chan face preview, active brain owner, and honest telemetry labels.
   - State: physical robot connected and hello handshake complete.

3. `phone-brain-model`
   - Screen: Brain / model controls.
   - Must show Gemma-4-E2B download/load/eject state, checksum or staged status, and model
     settings entry point.
   - State: use the real device model state from the final build; do not imply inference is
     validated unless the evidence packet proves it.

4. `phone-personas-diagnostics`
   - Screen: Persona library, settings, or diagnostics.
   - Must show import/export persona affordances or diagnostics export from the final build.
   - State: no exported private data or local secrets visible.

The Play Console requires at least two phone screenshots, but v1 should capture all four so
the store listing covers setup, live operation, model management, and field support.
