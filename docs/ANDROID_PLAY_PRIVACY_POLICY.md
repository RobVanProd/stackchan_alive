# Stackchan Companion Privacy Policy

This policy is the Play-facing privacy-policy draft for the Android app package
`dev.stackchan.companion`. It is derived from `docs/PRIVACY.md` and
`docs/ANDROID_PLAY_POLICY_DECLARATIONS.md`.

Before Play submission, publish this policy at the final privacy-policy URL,
replace the review placeholders below with the Play listing developer contact and
review date, and verify it against the exact uploaded Android build.

- App name: Stackchan Companion
- Android package: `dev.stackchan.companion`
- Last reviewed: pending final Play upload
- Developer contact: use the contact address shown on the final Play listing

## Summary

Stackchan Companion is a local companion app for pairing with and operating a
Stack-chan robot on the user's own network. The app does not create accounts,
show ads, sell purchases, or upload companion data to a developer-controlled
cloud service.

Meaningful connected features require a Stack-chan robot or bridge on the same
local network. The app can also store local setup state so the user can reconnect
to saved robots.

## Data The App Does Not Collect

The app does not collect or upload these data categories to the developer:

- Personal information such as name, email, phone number, or address.
- Financial information.
- Photos, videos, or camera data.
- Raw microphone audio or voice recordings.
- Crash reports or diagnostics automatically.
- Device identifiers for developer analytics or advertising.
- Location data. The app uses local network state and bridge URLs, not Android
  location permissions.

## Local Data Stored On The Device

The app may store local-only records in app-private storage:

- Saved robot rows and trusted companion endpoint records.
- Local bridge URLs, endpoint IDs, robot IDs, pairing fingerprints, and pairing
  state used to reconnect to a Stack-chan robot.
- App settings such as persona selection, display preferences, diagnostics export
  preference, and model asset state.
- Optional local Mobile Brain model download state, including model path, byte
  count, checksum status, and load/eject state.

This information stays on the device unless the user explicitly shares a
diagnostics export through the Android share sheet.

## Microphone And Speech

The app requests `RECORD_AUDIO` only for explicit Push-to-talk use. If the user
denies microphone permission, no transcript is sent.

When Push-to-talk is used, Android's speech recognizer handles speech capture
according to the user's device and speech-service settings, then returns text for
the current turn. The app sends that transcript through the local Stack-chan
bridge session. The app does not persist raw microphone audio and does not
include raw audio in diagnostics exports.

## Diagnostics Export

Diagnostics export is user initiated. The export is a local JSON file shared
through Android's share sheet only after the user requests it.

Diagnostics are intended for support and validation. They include bridge status,
robot/session status, saved robot/trusted endpoint state, model asset state, and
provisioning state. The export redacts the last text turn to a presence-only
flag and records Wi-Fi provisioning with password placeholders and
`password_redacted=true`.

## Local Network And Model Downloads

The app uses local-network permissions to host and connect to the Stack-chan
bridge, advertise/discover local services, and keep the active bridge reachable
while the user is operating the robot.

If the user downloads the optional Mobile Brain model, the app connects to the
configured model artifact host to fetch the model file and verifies its size and
SHA-256 checksum before staging it. This download does not upload local robot,
conversation, microphone, or diagnostics data to the developer.

## Data Sharing

The app does not share user data with the developer or third parties
automatically. Data leaves the app only when:

- The user operates a local Stack-chan bridge on their own network.
- The user explicitly shares a diagnostics export.
- The user downloads the optional model asset from its configured artifact host.

## Deletion

Users can remove saved robot and trusted companion records from the app UI.
Uninstalling the app removes app-private local stores from the phone. Robot-side
unpairing is managed by robot firmware and may require a separate robot-side
clear or pairing command.

## Children

Stackchan Companion is not directed to children. Connected operation requires
Stack-chan hardware or a local bridge and is intended for robot setup,
development, and operation by the device owner.
