"use strict";

const $ = (id) => document.getElementById(id);
const state = { busy: false, status: null, activeView: "overview" };

function boolLabel(value, yes = "Ready", no = "Unavailable") {
  return value === true ? yes : value === false ? no : "--";
}

function formatDuration(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  const hours = String(Math.floor(value / 3600)).padStart(2, "0");
  const minutes = String(Math.floor((value % 3600) / 60)).padStart(2, "0");
  const secs = String(Math.floor(value % 60)).padStart(2, "0");
  return `${hours}:${minutes}:${secs}`;
}

function formatAge(value) {
  if (value === null || value === undefined) return "--";
  if (value < 1) return "now";
  return `${Math.round(value)}s`;
}

function formatTime(iso) {
  if (!iso) return "--:--:--";
  const value = new Date(iso);
  return Number.isNaN(value.getTime()) ? "--:--:--" : value.toLocaleTimeString([], { hour12: false });
}

function showResult(message, kind = "") {
  const node = $("actionResult");
  node.textContent = message;
  node.className = `action-result ${kind}`.trim();
}

function renderMotion(robot) {
  const badge = $("motionBadge");
  const enabled = robot.motionEnabled;
  badge.className = "motion-badge";
  if (!robot.motionVerified || enabled === null) {
    badge.textContent = "UNVERIFIED";
    badge.classList.add("unknown");
    $("motionTitle").textContent = "Motion state unknown";
    $("motionReason").textContent = "Refresh robot status before changing motion.";
    $("motionSummary").textContent = "Unknown";
  } else if (enabled) {
    badge.textContent = "ENABLED";
    badge.classList.add("enabled");
    $("motionTitle").textContent = "Autonomous motion enabled";
    $("motionReason").textContent = robot.lastMotionReason || "Firmware motion authority is active.";
    $("motionSummary").textContent = "Enabled";
  } else {
    badge.textContent = "STOPPED";
    badge.classList.add("stopped");
    $("motionTitle").textContent = "Motion safely stopped";
    $("motionReason").textContent = robot.lastMotionReason || "Servo rail and torque are verified off.";
    $("motionSummary").textContent = "Stopped";
  }
}

function renderEvents(events) {
  const list = $("eventList");
  list.replaceChildren();
  for (const event of events || []) {
    const item = document.createElement("li");
    const stamp = document.createElement("time");
    const message = document.createElement("span");
    stamp.dateTime = event.at || "";
    stamp.textContent = formatTime(event.at);
    message.textContent = event.message || "Status update";
    if (event.kind === "error") message.className = "event-error";
    if (event.kind === "motion") message.className = "event-motion";
    item.append(stamp, message);
    list.append(item);
  }
  if (!list.children.length) {
    const item = document.createElement("li");
    item.innerHTML = "<time>--:--:--</time><span>No activity yet</span>";
    list.append(item);
  }
}

function render(payload) {
  state.status = payload;
  const bridge = payload.bridge || {};
  const robot = payload.robot || {};
  const connected = robot.connected === true;
  const chip = $("connectionChip");
  chip.className = `connection-chip ${connected ? "online" : "offline"}`;
  $("connectionLabel").textContent = connected ? "ROBOT CONNECTED" : "ROBOT OFFLINE";
  $("bridgeState").textContent = bridge.bridgeState === "ready" || connected ? "Ready" : bridge.listening ? "Listening" : "External";
  $("robotHost").textContent = robot.host || "Not connected";
  $("runnerProfile").textContent = bridge.runnerProfile || "Unknown";
  $("researchState").textContent = bridge.researchEnabled ? "Natural web tools on" : "Off";
  $("voiceName").textContent = bridge.ttsVoice || "Local voice";
  $("uptime").textContent = formatDuration(bridge.uptimeSeconds);
  $("robotMode").textContent = connected ? String(robot.mode || "ONLINE").toUpperCase() : "AWAITING ROBOT";
  $("heartbeatValue").textContent = formatAge(robot.heartbeatAgeSeconds);

  const face = $("faceShell");
  face.className = "face-shell";
  const modeClass = String(robot.mode || "").toLowerCase();
  if (["listening", "thinking", "sleeping", "error"].includes(modeClass)) face.classList.add(modeClass);

  renderMotion(robot);
  const hasBattery = robot.batteryPercent !== null && robot.batteryPercent !== undefined;
  const battery = hasBattery ? Number(robot.batteryPercent) : Number.NaN;
  $("powerValue").textContent = Number.isFinite(battery) && battery >= 0 ? `${battery}%` : robot.powerVbusMv ? `${robot.powerVbusMv} mV` : "--";
  $("powerDetail").textContent = robot.externalPower === true ? "External power" : robot.externalPower === false ? "Battery power" : "Power source unknown";
  const hasTemperature = robot.chipTempC !== null && robot.chipTempC !== undefined;
  const temp = hasTemperature ? Number(robot.chipTempC) : Number.NaN;
  $("temperatureValue").textContent = Number.isFinite(temp) ? `${temp.toFixed(1)} C` : "--";
  $("thermalDetail").textContent = robot.thermalSuppressed ? "Motion thermally suppressed" : "Thermal gate clear";
  $("touchValue").textContent = boolLabel(robot.touchReady);
  $("cameraValue").textContent = robot.cameraActive ? "Active" : boolLabel(robot.cameraEnabled, "Ready", "Unavailable");
  $("servoRailValue").textContent = boolLabel(robot.servoRailEnabled, "On", "Off");
  $("servoTorqueValue").textContent = `Torque ${String(boolLabel(robot.servoTorqueEnabled, "on", "off")).toLowerCase()}`;
  $("debugFreshness").textContent = robot.debugAt ? `Sampled ${formatTime(robot.debugAt)}` : "Not sampled";
  renderEvents(payload.events);
}

async function api(path, body = null) {
  const options = body === null ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Stackchan-Dashboard": "1" },
    body: JSON.stringify(body),
  };
  const response = await fetch(path, options);
  const payload = await response.json();
  if (payload.status) render(payload.status);
  else if (payload.schema) render(payload);
  if (!response.ok) throw new Error(payload.error || `Request failed (${response.status})`);
  return payload;
}

async function refresh(localOnly = false) {
  if (state.busy) return;
  state.busy = true;
  $("refreshButton").disabled = true;
  try {
    await api(localOnly ? "/api/status" : "/api/refresh", localOnly ? null : {});
    if (!localOnly) showResult("Robot status refreshed.", "success");
  } catch (error) {
    showResult(error.message, "error");
  } finally {
    state.busy = false;
    $("refreshButton").disabled = false;
  }
}

async function changeMotion(enabled) {
  if (state.busy) return;
  state.busy = true;
  $("stopMotionButton").disabled = true;
  $("resumeMotionButton").disabled = true;
  showResult(enabled ? "Requesting motion resume..." : "Requesting safe motion stop...");
  try {
    const payload = await api("/api/motion", {
      enabled,
      confirmation: enabled ? "robot_clear" : "",
    });
    showResult(enabled ? "Motion resumed and verified." : "Motion stopped; rail and torque verified off.", "success");
    if (payload.ok && enabled) $("robotClearCheck").checked = false;
  } catch (error) {
    showResult(error.message, "error");
  } finally {
    state.busy = false;
    $("stopMotionButton").disabled = false;
    $("resumeMotionButton").disabled = !$("robotClearCheck").checked;
  }
}

function activateView(target) {
  state.activeView = target;
  document.querySelectorAll(".mobile-nav button").forEach((button) => {
    button.classList.toggle("active", button.dataset.target === target);
  });
  document.querySelectorAll(".view-panel").forEach((panel) => {
    panel.classList.toggle("mobile-active", panel.dataset.view === target);
  });
}

$("refreshButton").addEventListener("click", () => refresh(false));
$("stopMotionButton").addEventListener("click", () => changeMotion(false));
$("resumeMotionButton").addEventListener("click", () => changeMotion(true));
$("robotClearCheck").addEventListener("change", (event) => {
  $("resumeMotionButton").disabled = !event.target.checked || state.busy;
});
document.querySelectorAll(".mobile-nav button").forEach((button) => {
  button.addEventListener("click", () => activateView(button.dataset.target));
});

activateView("overview");
refresh(true);
setInterval(() => refresh(true), 3000);
