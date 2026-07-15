# Away Mode Through Cloudflare

Away mode is a second persisted robot network profile. It does not replace or edit the Home
profile. The intended route is:

`Stack-chan -> phone hotspot -> Cloudflare Tunnel -> desktop companion bridge`

The robot uses TLS and a Cloudflare Access service token. The tunnel remains on the computer
running the desktop bridge and forwards WebSocket traffic to `http://127.0.0.1:8765`.

## Requirements

- A Cloudflare account with a domain managed in Cloudflare.
- `cloudflared` installed on the computer that runs the desktop companion.
- A named Cloudflare Tunnel and stable DNS hostname. Quick tunnels are not a durable Away
  profile because their hostnames change.
- A Cloudflare Access self-hosted application for that hostname with a Service Auth policy.
- One Cloudflare Access service token dedicated to this robot.
- The Away hotspot enabled before switching the robot to Away mode.

Do not add the Wi-Fi password, tunnel credential JSON, Access client ID, or Access client secret
to this repository. The firmware serial helper prompts for secrets and redacts them from its log.

## Create The Tunnel

Install and authenticate `cloudflared`, then create a named tunnel:

```powershell
winget install --id Cloudflare.cloudflared
cloudflared tunnel login
cloudflared tunnel create stackchan-away
cloudflared tunnel route dns stackchan-away <STACKCHAN-BRIDGE-HOSTNAME>
```

Copy `deploy/cloudflare/config.example.yml` outside the repository, replace its placeholders,
and start the tunnel:

```powershell
cloudflared tunnel --config <PATH-TO-CONFIG> run stackchan-away
```

For unattended use, install the validated configuration as a Windows service only after an
interactive tunnel run reaches the desktop bridge successfully.

In Cloudflare Zero Trust, create a self-hosted Access application for the same hostname. Add a
Service Auth policy that includes the dedicated service token. Record the token client ID and
secret once; Cloudflare does not display the secret again.

## Provision Away Without Changing Home

Start the desktop companion and the tunnel. With the robot connected by USB and not being used
by another flashing or serial process, run:

```powershell
.\tools\provision_stackchan_wifi.ps1 `
  -Port COM4 `
  -Profile away `
  -Ssid Pixel_1004 `
  -BridgeUrl wss://<STACKCHAN-BRIDGE-HOSTNAME>/bridge
```

The helper securely prompts for the hotspot password, Access client ID, and Access client
secret. Successful provisioning stores Away alongside Home and activates Away. It never prints
the supplied secrets.

Switch profiles later from the Android or desktop app under `Nodes -> Setup -> Network mode`.
The app command is accepted only from a paired endpoint. The robot acknowledges the request,
persists the selected profile, and then reconnects. USB fallback commands remain available:

```powershell
.\tools\provision_stackchan_wifi.ps1 -Port COM4 -Profile away -ActivateOnly
.\tools\provision_stackchan_wifi.ps1 -Port COM4 -Profile home -ActivateOnly
```

Turn on the phone hotspot before selecting Away. Select Home before turning the hotspot off when
returning home. If the active network is unavailable, connect USB and use the Home activation
command; neither operation deletes the other profile.

## Acceptance Check

1. Verify Home connects to the existing LAN bridge.
2. Start the desktop companion, named tunnel, and phone hotspot.
3. Provision Away and confirm firmware reports `profile=away`, `tls=1`, `clock_ready=1`, and an
   accepted WebSocket handshake without logging credentials.
4. Disconnect the home LAN from the robot while leaving the hotspot active.
5. Complete one spoken turn and one app text turn through the remote desktop brain.
6. Reboot the robot and repeat one turn to prove the selected profile persists.
7. Switch to Home and prove the original bridge configuration still works.

The repository can validate parsing, persistence, TLS, Access headers, companion controls, and
builds without a Cloudflare account. A real hostname, service token, hotspot session, and robot
round trip are required for final Away-mode evidence.
