# Stackchan Bridge Dashboard

The PC bridge can serve a local browser dashboard at `http://127.0.0.1:8766/`. It shows the
bridge and robot link state, a square Stackchan face, bounded robot telemetry, recent dashboard
events, and verified motion stop/resume controls.

The integrated dashboard also has an **Awareness** view. It exposes independent initiative and
room-observation switches, the bounded room-observation interval, aggregate freshness, and
degraded-state reporting. A standalone dashboard attached to an older bridge can display robot
status but cannot add these host runtimes to that already-running process.

## Start And Open

Run the reset-safe launcher:

```powershell
.\tools\start_stackchan_dashboard.ps1
```

The launcher behaves in two modes:

- If the dashboard is already running, it opens the existing page.
- If an older Stackchan bridge is running without the dashboard, it starts only the loopback
  dashboard, derives displayed research/Conversation-v2 state from that process's real command
  line, and leaves the robot WebSocket and voice process untouched.
- If the PC bridge is not running after a reset, it starts the production DirectML bridge with
  Conversation v2 and bounded initiative enabled. It starts and fully checks local research
  before replacing a bridge. When the private pairing-code file exists, it also starts face
  presence detection and preconfigures the room model, while leaving semantic room observation
  off until it is enabled in the dashboard. After the robot reconnects, startup calls the
  firmware-owned motion-stop endpoint through the loopback dashboard and refuses to report ready
  until `/debug` confirms motion, servo rail, and servo torque are all off.

Normal startup is fail-closed when local research is unavailable. Docker or Podman installation
remains an owner action; the launcher never elevates or installs it. For an intentional offline
session only, use:

```powershell
.\tools\start_stackchan_dashboard.ps1 -DisableResearch
```

`-DisableFaceVision` is the explicit fallback when authenticated camera presence should not run.
Neither fallback changes firmware or grants motion.

Install the desktop shortcut once:

```powershell
.\tools\install_stackchan_dashboard_shortcut.ps1
```

The branded shortcut is named `Stackchan Alive` and invokes the same reset-safe launcher.

## Motion Authority

The dashboard does not write servo state directly. It calls the firmware-owned debug endpoints
on port `8789`:

- Production DirectML startup always verifies a motion stop after bridge reconnect. Motion never
  remains enabled when the launcher reports ready; the operator must use the guarded control
  below to resume it.
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
- Room observation accepts only 2-30 minute intervals. Frames remain in memory for one local
  model request and are never included in dashboard status, logs, prompts, or durable memory.
- Initiative requires fresh presence, preserves the wake gate for microphone entry, and never
  grants motion authority.

## Direct Bridge Launch

The base launcher also supports explicit dashboard options:

```powershell
.\tools\start_pc_brain.ps1 -Background -EnableDashboard `
  -DashboardHost 127.0.0.1 -DashboardPort 8766 `
  -RobotHost 192.168.1.238 -EnableAudioDownlink
```

For a supervised qualification that starts semantic room observation immediately:

```powershell
$env:STACKCHAN_OLLAMA_VISION_MODEL = "your-local-vision-model"
.\tools\start_pc_brain.ps1 -Background -EnableDashboard -EnableAudioDownlink `
  -EnableConversationV2 -EnableInitiative -EnableRoomObservation `
  -CameraPairingCodeFile "$env:USERPROFILE\.stackchan\camera-pairing-code.txt" `
  -RobotHost 192.168.1.238
```

The dashboard runs inside that bridge process and receives robot heartbeat summaries directly.
The standalone compatibility mode cannot see heartbeat details from a bridge that was launched
before dashboard support; use **Refresh status** for a bounded firmware snapshot in that mode.
