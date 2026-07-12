## Summary

Describe the problem and the user-visible result.

## Ownership Boundaries

List the firmware, bridge, persona, tool, companion, or documentation boundaries touched. Explain
how actuator, power, camera, microphone, memory, network, and model authority remain constrained.

## Verification

List the exact commands and results. Include exact firmware SHA-256/source binding and sanitized
evidence for physical behavior changes.

## Safety And Privacy

- [ ] Motion was disabled, or physical testing had an operator present, a clear body, a stable surface, and explicit servo-risk confirmation.
- [ ] No power, thermal, display, wake, pairing, OTA, camera-auth, memory, or evidence gate was weakened to obtain a pass.
- [ ] Observed facts are separated from hypotheses.
- [ ] No credentials, pairing/OTA material, private firmware, local memory, raw audio/camera data, signing keys, or private model assets are included.
- [ ] Voice, model, code, and media inputs have clear contribution and distribution rights.

## Documentation

- [ ] User, agent, runbook, protocol, creator, or release documentation was updated where behavior or commands changed.
- [ ] Remaining risks and unverified gates are stated explicitly.
