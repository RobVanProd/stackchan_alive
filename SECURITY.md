# Security Policy

Stackchan: Alive combines local AI with microphones, a camera, LAN services, persistent memory,
OTA updates, and physical actuators. Please report security and privacy defects privately.

## Supported Code

Security fixes target the latest `main` commit and the latest published prerelease. Historical
diagnostic firmware, archived candidates, local recovery images, and older evidence bundles are
not supported distributions.

## Report Privately

Use [GitHub private vulnerability reporting](https://github.com/RobVanProd/stackchan_alive/security/advisories/new).
Do not open a public issue for a vulnerability and do not include live credentials, pairing data,
private firmware, local memory, raw audio, camera frames, signing material, or private model assets
in a report. Use redacted logs and synthetic reproduction values.

Include, when available:

- affected commit, release, firmware SHA-256, and component;
- impact and realistic attack path;
- minimal reproduction steps or a safe proof of concept;
- whether microphone, camera, memory, LAN, OTA, power, or actuator authority is involved;
- suggested mitigation; and
- whether any credential or private artifact may already be exposed.

Please allow maintainers time to investigate and prepare a coordinated fix before public
disclosure. No response or remediation deadline is promised for this prerelease project.

## Urgent Safety Response

If a suspected vulnerability causes unexpected motion, stop the runner that can renew motion and
call the robot's authenticated motion-stop path when reachable. Remove power only when needed for
immediate physical safety. Preserve the first debug and network evidence; do not repeatedly reboot
or reflash before capture.

If a secret was exposed, rotate or revoke it immediately. Removing it from the latest commit does
not remove it from Git history or downloaded artifacts.

## Public Discussion

After a fix or safe workaround exists, ordinary non-sensitive bugs can be tracked publicly. Keep
private exploit details, credentials, identifying recordings, and restricted assets out of issues,
pull requests, Actions logs, and release packages.
