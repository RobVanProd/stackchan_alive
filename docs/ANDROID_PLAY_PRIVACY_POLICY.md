# Stackchan Companion Privacy Policy

Effective date: July 14, 2026
Last reviewed: July 14, 2026

This policy applies to Stackchan Companion for Android
(`dev.stackchan.companion`) and the companion desktop applications. The
canonical public URL is
https://robvanprod.github.io/stackchan_alive/privacy/.

- App name: Stackchan Companion
- Developer: RobVanProd
- Privacy inquiries: https://github.com/RobVanProd/stackchan_alive/issues
- Security reports: https://github.com/RobVanProd/stackchan_alive/security/policy

## Summary

Stackchan Companion pairs with and operates a Stack-chan robot on the user's
local network. The app does not create accounts, show ads, sell purchases, or
send companion data to a developer-controlled analytics service.

Meaningful connected features require a Stack-chan robot or bridge on the same
local network. The app stores local setup state so the user can reconnect to
saved robots.

## Data The Developer Does Not Collect

The developer does not receive these categories from the app:

- Personal information such as name, email, phone number, or address.
- Financial information.
- Photos, videos, or camera data.
- Crash reports or diagnostics automatically.
- Device identifiers for analytics or advertising.
- Location data. The app uses local network state and bridge URLs, not Android
  location permissions.

The app does not persist raw microphone audio or include raw audio in
diagnostics exports. Push-to-talk speech processing is described separately
below because the configured Android speech service may process audio away from
the phone.

## Local Data Stored On The Device

The app may store these records in app-private storage:

- Saved robot and trusted companion records.
- Local bridge URLs, endpoint IDs, robot IDs, pairing fingerprints, and pairing
  state used to reconnect to a Stack-chan robot.
- App settings such as persona selection, display preferences, diagnostics
  export preference, and model asset state.
- Optional Mobile Brain model state, including model path, byte count, checksum
  status, and load or eject state.

This information remains on the device unless the user explicitly sends it to
a local Stack-chan bridge or shares a diagnostics export.

## Microphone And Speech

The Android app requests `RECORD_AUDIO` only when the user invokes
Push-to-talk. If microphone permission is denied, the app does not start the
turn or send a transcript.

The app asks Android's configured speech-recognition service to convert the
user's speech into text. Depending on the device and speech-service settings,
that service may process microphone audio on the device or transmit it to the
speech-service provider for ephemeral processing. That processing is governed
by the selected speech provider's privacy policy. Stackchan Companion requests
offline recognition when the service supports it, but cannot guarantee that
every installed speech service honors that preference.

The recognizer returns text for the current turn. Stackchan Companion sends the
transcript to the user-configured Stack-chan bridge, normally on the local
network. The app does not persist raw microphone audio and does not include raw
audio or transcript text in diagnostics exports.

## Diagnostics Export

Diagnostics export is user initiated. The app creates a local JSON file and
opens the operating system share surface only after the user requests an
export. The user chooses whether and where to send the file.

Diagnostics may include bridge and robot status, saved robot and trusted
endpoint state, model asset state, and provisioning state. The export redacts
the last text turn to a presence-only flag and records Wi-Fi provisioning with
password placeholders and `password_redacted=true`.

## Local Network And Model Downloads

The app uses network access to host or connect to a Stack-chan bridge, discover
local services, and keep an active robot session reachable. Local bridge
traffic can include pairing state, commands, settings, status, and the current
recognized transcript. The v1 local bridge uses the user's trusted LAN and is
not represented as end-to-end encrypted.

If the user downloads the optional Mobile Brain model, the app connects to the
configured model host to fetch the file and verifies its size and SHA-256
checksum before staging it. The host may receive ordinary request metadata such
as the user's IP address. The model request does not include local robot,
conversation, microphone, or diagnostics content.

## When Data Leaves The App

The app does not automatically sell data or send data to the developer. Data
can leave the app in these limited cases:

- The user starts Push-to-talk and the configured Android speech service uses
  off-device processing.
- The user sends a recognized text turn or commands to a user-configured local
  Stack-chan bridge.
- The user explicitly shares a diagnostics export with a destination they
  select.
- The user downloads the optional model asset from its configured host.

## Security, Retention, And Deletion

Local records are stored in app-private storage. They remain until the user
removes the associated saved robot or trusted companion record, clears the
app's data, or uninstalls the app. Downloaded model assets remain until removed
or the app data is cleared. The app does not retain raw microphone audio.

Users can remove saved robot and trusted companion records from the app UI.
Uninstalling the app removes app-private local stores from the device.
Robot-side unpairing is managed separately by robot firmware and may require a
robot-side clear or pairing command.

## Children

Stackchan Companion is not directed to children. Connected operation requires
Stack-chan hardware or a local bridge and is intended for robot setup,
development, and operation by the device owner.

## Changes And Contact

Material policy changes will be published at the canonical URL with an updated
review date. Privacy questions may be submitted through the public issue
tracker. Security-sensitive reports should use the repository security policy
rather than a public issue.
