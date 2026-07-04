package dev.stackchan.companion.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.stackchan.companion.core.CompanionIdentity

private val Ink = Color(0xFFE7F8FF)
private val Muted = Color(0xFF88A5B3)
private val Page = Color(0xFF05070D)
private val Panel = Color(0xFF0B111C)
private val PanelAlt = Color(0xFF101826)
private val Line = Color(0xFF164E5B)
private val Purple = Color(0xFF7C5CFF)
private val Cyan = Color(0xFF16D9E8)
private val Mint = Color(0xFF62E6BA)
private val Amber = Color(0xFFF2B84B)
private val Danger = Color(0xFFFF5D72)
private val Console = Color(0xFF07101D)

data class CompanionUiState(
    val connection: String = "Connected: Rob's Phone (This Companion)",
    val brainOwner: String = "Android",
    val heartbeatMs: Int = 8,
    val activePersona: String = "Spark",
    val robotState: String = "Neutral",
    val servoArmed: Boolean = true,
    val telemetry: List<TelemetryReading> = listOf(
        TelemetryReading("Power", "87%", "Discharging"),
        TelemetryReading("CPU temp", "42.5 C", "Nominal"),
        TelemetryReading("Uptime", "04:12:39", "H:M:S"),
        TelemetryReading("Firmware", "v3.1.0", "Stable"),
    ),
    val audioStatus: String = "Fake output ready",
    val consoleMessage: String = "Awaiting wake-gated input on android brain...",
    val brainService: BrainServiceUiState = BrainServiceUiState(),
    val diagnosticsExport: DiagnosticsExportUiState = DiagnosticsExportUiState(),
    val c6Rehearsal: C6RehearsalUiState = C6RehearsalUiState(),
    val endpoints: List<EndpointRow> = listOf(
        EndpointRow("Rob's Phone (This Companion)", "android", "SHA256:B84F17C2A0E192DDB...", 80, true, true),
        EndpointRow("Studio Mac Studio", "pc", "SHA256:A21B84C019E2FF02A...", 90, false, false),
        EndpointRow("Guest Raspberry Pi 5", "pc", "SHA256:7F452C2C0F90DA15B...", 50, false, false),
    ),
)

data class DiagnosticsExportUiState(
    val status: String = "Not exported",
    val path: String = "",
    val error: String = "",
)

data class C6RehearsalUiState(
    val status: String = "Ready",
    val path: String = "",
    val error: String = "",
)

data class BrainServiceUiState(
    val running: Boolean = false,
    val status: String = "Stopped",
    val pid: String = "n/a",
    val endpoint: String = "0.0.0.0:8766",
    val command: String = "python bridge/lan_service.py",
    val exitCode: String = "n/a",
    val recentLogs: List<String> = listOf("PC brain supervisor idle."),
)

data class TelemetryReading(
    val label: String,
    val value: String,
    val detail: String,
)

data class EndpointRow(
    val name: String,
    val kind: String,
    val fingerprint: String,
    val priority: Int,
    val connected: Boolean,
    val activeBrain: Boolean,
)

@Composable
fun CompanionConsole(
    targetName: String,
    state: CompanionUiState = CompanionUiState(),
    onStartBrain: () -> Unit = {},
    onStopBrain: () -> Unit = {},
    onRestartBrain: () -> Unit = {},
    onExportDiagnostics: () -> Unit = {},
    onRunC6Rehearsal: () -> Unit = {},
) {
    MaterialTheme {
        Surface(color = Page, modifier = Modifier.fillMaxSize()) {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val compact = maxWidth < 820.dp
                TacticalBackdrop()
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(if (compact) 12.dp else 24.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    Header(targetName, state, compact)
                    if (compact) {
                        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            StagePanel(state, Modifier.fillMaxWidth(), compact = true)
                            BrainPanel(
                                state = state,
                                modifier = Modifier.fillMaxWidth(),
                                onStartBrain = onStartBrain,
                                onStopBrain = onStopBrain,
                                onRestartBrain = onRestartBrain,
                                onExportDiagnostics = onExportDiagnostics,
                                onRunC6Rehearsal = onRunC6Rehearsal,
                            )
                            EndpointRegistry(state, Modifier.fillMaxWidth())
                            TelemetryPanel(state, Modifier.fillMaxWidth())
                        }
                    } else {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                verticalArrangement = Arrangement.spacedBy(16.dp),
                                modifier = Modifier.weight(1.65f),
                            ) {
                                StagePanel(state, Modifier.fillMaxWidth())
                                EndpointRegistry(state, Modifier.fillMaxWidth())
                            }
                            Column(
                                verticalArrangement = Arrangement.spacedBy(16.dp),
                                modifier = Modifier.weight(1f),
                            ) {
                                TelemetryPanel(state, Modifier.fillMaxWidth())
                                BrainPanel(
                                    state = state,
                                    modifier = Modifier.fillMaxWidth(),
                                    onStartBrain = onStartBrain,
                                    onStopBrain = onStopBrain,
                                    onRestartBrain = onRestartBrain,
                                    onExportDiagnostics = onExportDiagnostics,
                                    onRunC6Rehearsal = onRunC6Rehearsal,
                                )
                                SecurityPanel(Modifier.fillMaxWidth())
                            }
                        }
                    }
                    Footer()
                }
            }
        }
    }
}

@Composable
private fun Header(targetName: String, state: CompanionUiState, compact: Boolean) {
    Surface(
        color = Panel,
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Line),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Console)
                        .border(1.dp, Cyan, RoundedCornerShape(8.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("//", color = Cyan, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text("Stackchan Alive", color = Ink, fontWeight = FontWeight.Bold, fontSize = 19.sp)
                    Text(
                        "Companion ${CompanionIdentity.appVersion}  //  $targetName  //  ${CompanionIdentity.protocol}",
                        color = Muted,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (!compact) {
                    StatusPill(state.connection, Mint, Color(0xFF0D2A25))
                    StatusPill("Brain: ${state.brainOwner}", Purple, Color(0xFF181536))
                }
            }
            if (compact) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, bottom = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    StatusPill(
                        text = state.connection,
                        color = Mint,
                        background = Color(0xFF0D2A25),
                        modifier = Modifier.weight(1f),
                    )
                    StatusPill(
                        text = "Brain: ${state.brainOwner}",
                        color = Purple,
                        background = Color(0xFF181536),
                        modifier = Modifier.weight(0.72f),
                    )
                }
            }
        }
    }
}

@Composable
private fun StagePanel(state: CompanionUiState, modifier: Modifier, compact: Boolean = false) {
    PanelShell(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            SectionTitle("Live Robot Stage", Mint)
            Spacer(modifier = Modifier.weight(1f))
            StatusPill("Heartbeat: ${state.heartbeatMs}ms", Purple, Color(0xFF181536))
        }
        Spacer(Modifier.height(14.dp))
        Surface(
            color = Console,
            shape = RoundedCornerShape(8.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, Line),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                    Readout("Pan", "0 deg", Muted)
                    Readout("Servo", if (state.servoArmed) "Armed" else "Safe", if (state.servoArmed) Danger else Mint)
                    Readout("Tilt", "0 deg", Muted)
                }
                Spacer(Modifier.height(10.dp))
                RobotPreview(Modifier.fillMaxWidth(if (compact) 0.86f else 0.62f).aspectRatio(1.65f))
                Spacer(Modifier.height(8.dp))
                Text("State // ${state.robotState}", color = Muted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
            }
        }
        Spacer(Modifier.height(14.dp))
        Text("Manual servos and triggers", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallCommand("Look L")
            SmallCommand("Look R")
            SmallCommand("Nod Down")
            SmallCommand("Shake")
            SmallCommand("Reset", filled = true)
        }
        Spacer(Modifier.height(12.dp))
        Text("Facial expressions", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("neutral", "happy", "sad", "angry", "sleepy", "listening", "thinking").forEach {
                ExpressionChip(it, selected = it == "neutral")
            }
        }
    }
}

@Composable
private fun EndpointRegistry(state: CompanionUiState, modifier: Modifier) {
    PanelShell(modifier = modifier) {
        Tabs()
        Spacer(Modifier.height(14.dp))
        Text("Trusted Companion Registry", color = Ink, fontWeight = FontWeight.Bold, fontSize = 16.sp)
        Text(
            "Only paired endpoints can own the conversational brain or issue settings updates.",
            color = Muted,
            fontSize = 11.sp,
        )
        Spacer(Modifier.height(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.endpoints.forEach { endpoint ->
                EndpointItem(endpoint)
            }
        }
        Spacer(Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Deploy mDNS Pairing", color = Ink, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                Text("Broadcasts `_stackchan-bridge._tcp.local` for discovery.", color = Muted, fontSize = 11.sp)
            }
            OutlinedButton(onClick = {}) {
                Text("+ Pair Node", fontSize = 12.sp)
            }
        }
        Spacer(Modifier.height(14.dp))
        SecurityPanel(Modifier.fillMaxWidth())
    }
}

@Composable
private fun TelemetryPanel(state: CompanionUiState, modifier: Modifier) {
    PanelShell(modifier = modifier) {
        SectionTitle("Telemetry", Cyan)
        Spacer(Modifier.height(12.dp))
        state.telemetry.forEach { reading ->
            TelemetryRow(reading)
        }
        Spacer(Modifier.height(16.dp))
        Text("Audio out // ${state.audioStatus}", color = Ink, fontWeight = FontWeight.Bold, fontSize = 14.sp)
        Spacer(Modifier.height(8.dp))
        AudioBars()
        Spacer(Modifier.height(16.dp))
        ConsoleLog(state.consoleMessage)
    }
}

@Composable
private fun TacticalBackdrop() {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val step = 22.dp.toPx()
        var y = 0f
        while (y < size.height) {
            var x = 0f
            while (x < size.width) {
                drawCircle(
                    color = Color(0x223D91A3),
                    radius = 0.7.dp.toPx(),
                    center = Offset(x, y),
                )
                x += step
            }
            y += step
        }
    }
}

@Composable
private fun BrainPanel(
    state: CompanionUiState,
    modifier: Modifier,
    onStartBrain: () -> Unit = {},
    onStopBrain: () -> Unit = {},
    onRestartBrain: () -> Unit = {},
    onExportDiagnostics: () -> Unit = {},
    onRunC6Rehearsal: () -> Unit = {},
) {
    PanelShell(modifier = modifier) {
        SectionTitle("PC Brain Supervisor", Purple)
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp), modifier = Modifier.fillMaxWidth()) {
            Readout("Service", state.brainService.status, if (state.brainService.running) Mint else Amber)
            Readout("PID", state.brainService.pid, Muted)
            Readout("Endpoint", state.brainService.endpoint, Cyan)
        }
        Spacer(Modifier.height(12.dp))
        Readout("Owner", state.brainOwner, Cyan)
        Spacer(Modifier.height(10.dp))
        Readout("Persona", state.activePersona, Purple)
        Spacer(Modifier.height(10.dp))
        Readout("Command", state.brainService.command, Muted)
        Spacer(Modifier.height(14.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallCommand(
                text = if (state.brainService.running) "Stop brain" else "Start brain",
                filled = true,
                onClick = if (state.brainService.running) onStopBrain else onStartBrain,
            )
            SmallCommand("Restart", onClick = onRestartBrain)
            SmallCommand("Export diagnostics", onClick = onExportDiagnostics)
            SmallCommand("Run C6 rehearsal", onClick = onRunC6Rehearsal)
            SmallCommand("Use phone")
            SmallCommand("Handoff")
        }
        Spacer(Modifier.height(12.dp))
        Readout("Diagnostics export", state.diagnosticsExport.status, if (state.diagnosticsExport.error.isBlank()) Mint else Danger)
        if (state.diagnosticsExport.path.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                state.diagnosticsExport.path,
                color = Muted,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(10.dp))
        Readout("C6 GUI rehearsal", state.c6Rehearsal.status, if (state.c6Rehearsal.error.isBlank()) Mint else Danger)
        if (state.c6Rehearsal.path.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                state.c6Rehearsal.path,
                color = Muted,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(14.dp))
        ConsoleLog(state.brainService.recentLogs.takeLast(6).joinToString("\n"))
    }
}

@Composable
private fun SecurityPanel(modifier: Modifier) {
    Surface(
        color = Console,
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF26344D)),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Text("Security Compliance Handoff Gates", color = Color(0xFFC7D2FE), fontSize = 11.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text(
                "Pairing creates a trusted endpoint record. The robot must verify command envelopes before settings, servo, persona, or brain-owner writes.",
                color = Color(0xFFE5E7EB),
                fontSize = 11.sp,
                lineHeight = 16.sp,
            )
        }
    }
}

@Composable
private fun PanelShell(modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        color = Panel,
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Line),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(18.dp), content = content)
    }
}

@Composable
private fun SectionTitle(text: String, accent: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(accent))
        Text(text.uppercase(), color = Ink, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp)
    }
}

@Composable
private fun StatusPill(text: String, color: Color, background: Color, modifier: Modifier = Modifier) {
    Surface(color = background, shape = RoundedCornerShape(8.dp), modifier = modifier) {
        Text(
            text,
            color = color,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun Readout(label: String, value: String, accent: Color) {
    Column {
        Text(label.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Text(value, color = accent, fontSize = 13.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun SmallCommand(text: String, filled: Boolean = false, onClick: () -> Unit = {}) {
    val colors = if (filled) {
        ButtonDefaults.buttonColors(containerColor = Cyan, contentColor = Color(0xFF061018))
    } else {
        ButtonDefaults.outlinedButtonColors(contentColor = Ink, containerColor = Color.Transparent)
    }
    if (filled) {
        Button(onClick = onClick, shape = RoundedCornerShape(8.dp), colors = colors) {
            Text(text, fontSize = 12.sp)
        }
    } else {
        OutlinedButton(onClick = onClick, shape = RoundedCornerShape(8.dp), colors = colors) {
            Text(text, fontSize = 12.sp)
        }
    }
}

@Composable
private fun ExpressionChip(text: String, selected: Boolean) {
    Surface(
        color = if (selected) Color(0xFF2A2613) else PanelAlt,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) Amber else Line),
        shape = RoundedCornerShape(8.dp),
    ) {
        Text(text, color = if (selected) Ink else Muted, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
    }
}

@Composable
private fun Tabs() {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("Endpoints", "Mobile Brain", "Voice Synthesis", "Personas", "Calibration", "Telemetry").forEachIndexed { index, text ->
            Text(
                text,
                color = if (index == 0) Purple else Muted,
                fontSize = 12.sp,
                fontWeight = if (index == 0) FontWeight.Bold else FontWeight.Normal,
            )
        }
    }
    Spacer(Modifier.height(8.dp))
    HorizontalDivider(color = Line)
}

@Composable
private fun EndpointItem(endpoint: EndpointRow) {
    val iconLabel = when (endpoint.kind) {
        "android" -> "P"
        "robot" -> "SC"
        else -> "PC"
    }
    Surface(
        color = if (endpoint.activeBrain) Color(0xFF131B33) else PanelAlt,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (endpoint.activeBrain) Purple else Line),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).background(Console).border(1.dp, Line, RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(iconLabel, color = Cyan, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            }
            Column(modifier = Modifier.weight(1f)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(endpoint.name, color = Ink, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (endpoint.activeBrain) StatusPill("Active brain", Purple, Color(0xFF181536))
                }
                Text("Fingerprint: ${endpoint.fingerprint}", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("stt   llm   tts   settings   ${endpoint.kind}", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("Priority: ${endpoint.priority}", color = Muted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                Spacer(Modifier.height(6.dp))
                if (endpoint.connected) {
                    StatusPill("Connected", Mint, Color(0xFF0D2A25))
                } else {
                    Button(
                        onClick = {},
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Purple, contentColor = Color.White),
                    ) {
                        Text("Handoff", fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun TelemetryRow(reading: TelemetryReading) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).border(1.dp, Line, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(reading.label.take(1), color = Cyan, fontSize = 13.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(reading.label.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
            Text(reading.value, color = Ink, fontSize = 14.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
        }
        Text(reading.detail, color = Cyan, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun AudioBars() {
    Canvas(modifier = Modifier.fillMaxWidth().height(28.dp)) {
        val bars = 28
        val gap = size.width / (bars * 1.7f)
        val barWidth = gap * 0.7f
        repeat(bars) { index ->
            val height = (6 + (index % 5) * 3).dp.toPx()
            drawRoundRect(
                color = if (index % 4 == 0) Purple else Cyan,
                topLeft = Offset(index * gap * 1.7f, (size.height - height) / 2f),
                size = Size(barWidth, height),
            )
        }
    }
}

@Composable
private fun ConsoleLog(message: String) {
    Surface(
        color = Color(0xFF111B2D),
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF26344D)),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Text("Console log", color = Cyan, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text("> $message", color = Color(0xFFE5E7EB), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

@Composable
private fun RobotPreview(modifier: Modifier) {
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        val body = Size(w * 0.58f, h * 0.56f)
        val bodyLeft = (w - body.width) / 2f
        val bodyTop = h * 0.2f
        val stroke = Stroke(width = 6.dp.toPx(), cap = StrokeCap.Round)

        drawOval(Color(0x22000000), topLeft = Offset(w * 0.34f, h * 0.78f), size = Size(w * 0.32f, h * 0.08f))
        drawRoundRect(Color(0xFF111827), topLeft = Offset(bodyLeft, bodyTop), size = body, cornerRadius = androidx.compose.ui.geometry.CornerRadius(24.dp.toPx()))
        drawRoundRect(Amber, topLeft = Offset(bodyLeft, bodyTop), size = body, cornerRadius = androidx.compose.ui.geometry.CornerRadius(24.dp.toPx()), style = stroke)
        drawRoundRect(Amber, topLeft = Offset(bodyLeft - 18.dp.toPx(), bodyTop + body.height * 0.34f), size = Size(14.dp.toPx(), body.height * 0.28f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(8.dp.toPx()))
        drawRoundRect(Amber, topLeft = Offset(bodyLeft + body.width + 4.dp.toPx(), bodyTop + body.height * 0.34f), size = Size(14.dp.toPx(), body.height * 0.28f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(8.dp.toPx()))
        drawOval(Cyan, topLeft = Offset(bodyLeft + body.width * 0.22f, bodyTop + body.height * 0.30f), size = Size(16.dp.toPx(), 24.dp.toPx()))
        drawOval(Cyan, topLeft = Offset(bodyLeft + body.width * 0.68f, bodyTop + body.height * 0.30f), size = Size(16.dp.toPx(), 24.dp.toPx()))
        drawRoundRect(Cyan, topLeft = Offset(bodyLeft + body.width * 0.45f, bodyTop + body.height * 0.68f), size = Size(body.width * 0.10f, 4.dp.toPx()), cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()))
        drawLine(Color(0xFF1F2937), Offset(w * 0.5f, bodyTop + body.height + 8.dp.toPx()), Offset(w * 0.5f, bodyTop + body.height + 28.dp.toPx()), strokeWidth = 8.dp.toPx(), cap = StrokeCap.Round)
        drawRoundRect(Color(0xFF1F2937), topLeft = Offset(w * 0.43f, bodyTop + body.height + 28.dp.toPx()), size = Size(w * 0.14f, 10.dp.toPx()), cornerRadius = androidx.compose.ui.geometry.CornerRadius(5.dp.toPx()))
        drawLine(
            color = Color(0xFF2B3650),
            start = Offset(bodyLeft + 18.dp.toPx(), bodyTop + body.height * 0.16f),
            end = Offset(bodyLeft + body.width - 18.dp.toPx(), bodyTop + body.height * 0.16f),
            strokeWidth = 1.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 6f)),
        )
    }
}

@Composable
private fun Footer() {
    Text(
        "Character OS hardware parity lock: SHA256:49A8FBD...  //  Compiler accordance verified",
        color = Muted,
        fontSize = 10.sp,
        fontFamily = FontFamily.Monospace,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    )
}
