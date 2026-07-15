# Stackchan Bridge Dashboard

The PC bridge can serve a local browser dashboard at `http://127.0.0.1:8766/`. It shows the
bridge and robot link state, a square Stackchan face, bounded robot telemetry, recent dashboard
events, and verified motion stop/resume controls.

## Start And Open

Run the reset-safe launcher:

```powershell
.\tools\start_stackchan_dashboard.ps1
```

The launcher behaves in two modes:

- If the dashboard is already running, it opens the existing page.
- If an older Stackchan bridge is running without the dashboard, it starts only the loopback
  dashboard and leaves the robot WebSocket and voice process untouched.
- If the PC bridge is not running after a reset, it starts the production DirectML bridge with
  research enabled, waits for readiness, and opens the dashboard.

Install the desktop shortcut once:

```powershell
.\tools\install_stackchan_dashboard_shortcut.ps1
```

The branded shortcut is named `Stackchan Alive` and invokes the same reset-safe launcher.

## Motion Authority

The dashboard does not write servo state directly. It calls the firmware-owned debug endpoints
on port `8789`:

- **Stop motion** calls `/motion-stop`, then requires `/debug` to report motion, servo rail, and
  servo torque all off before showing a verified stop.
- **Resume motion** stays disabled until the operator checks **Robot is upright and clear**. It
  calls `/motion-resume`, then requires `/debug` to report motion, servo rail, and servo torque
  enabled with no power or thermal suppression before showing success.

A command timeout, rejected command, or mismatched `/debug` state is shown as unverified. The
dashboard never converts transport success into a motion-success claim.

## Security And Load

- The dashboard binds to loopback only. `lan_service.py` rejects a non-loopback dashboard host.
- Write requests require same-origin JSON and the dashboard request header. No CORS access is
  granted to other pages.
- Dashboard status is allowlisted and does not expose bridge memory, prompts, turn text, pairing
  secrets, Wi-Fi credentials, microphone audio, or camera frames.
- Browser status updates read in-memory state. The firmware `/debug` endpoint is contacted only
  for a manual refresh or motion verification, not every few seconds.

## Direct Bridge Launch

The base launcher also supports explicit dashboard options:

```powershell
.\tools\start_pc_brain.ps1 -Background -EnableDashboard `
  -DashboardHost 127.0.0.1 -DashboardPort 8766 `
  -RobotHost 192.168.1.238 -EnableAudioDownlink
```

The dashboard runs inside that bridge process and receives robot heartbeat summaries directly.
The standalone compatibility mode cannot see heartbeat details from a bridge that was launched
before dashboard support; use **Refresh status** for a bounded firmware snapshot in that mode.
