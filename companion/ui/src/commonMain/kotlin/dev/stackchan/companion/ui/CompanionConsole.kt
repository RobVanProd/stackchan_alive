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
import androidx.compose.foundation.layout.safeDrawingPadding
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
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
    val conversation: ConversationUiState = ConversationUiState(),
    val brainService: BrainServiceUiState = BrainServiceUiState(),
    val robotSetup: RobotSetupUiState = RobotSetupUiState(),
    val diagnosticsExport: DiagnosticsExportUiState = DiagnosticsExportUiState(),
    val c6Rehearsal: C6RehearsalUiState = C6RehearsalUiState(),
    val endpoints: List<EndpointRow> = listOf(
        EndpointRow("phone-rob-01", "Rob's Phone (This Companion)", "android", "SHA256:B84F17C2A0E192DDB...", 80, true, true),
        EndpointRow("studio-mac-01", "Studio Mac Studio", "pc", "SHA256:A21B84C019E2FF02A...", 90, false, false, removable = true),
        EndpointRow("guest-pi-01", "Guest Raspberry Pi 5", "pc", "SHA256:7F452C2C0F90DA15B...", 50, false, false, removable = true),
    ),
)

data class ConversationUiState(
    val inputEnabled: Boolean = false,
    val pushToTalkEnabled: Boolean = false,
    val pushToTalkLabel: String = "Push-to-talk",
    val pushToTalkStatus: String = "",
    val status: String = "Connect Stack-chan to send text turns.",
    val messages: List<ConversationMessage> = listOf(
        ConversationMessage("Bridge", "Text turns will appear here once the app is connected to Stack-chan.", "Waiting"),
    ),
)

data class ConversationMessage(
    val sender: String,
    val text: String,
    val detail: String = "",
)

data class RobotSetupUiState(
    val setupTitle: String = "Add your Stack-chan",
    val setupStatus: String = "Start the phone bridge, then connect Stack-chan on the same Wi-Fi.",
    val primaryBridgeUrl: String = "ws://<phone-lan-ip>:8765/bridge",
    val otherBridgeUrls: List<String> = emptyList(),
    val serviceRunning: Boolean = false,
    val robotConnected: Boolean = false,
    val robotName: String = "Awaiting Stack-chan robot",
    val robotFingerprint: String = "No robot hello yet",
    val trustedCompanionCount: Int = 0,
    val steps: List<RobotSetupStepUiState> = listOf(
        RobotSetupStepUiState("Start bridge", "Keep this app open so Stack-chan can reach the phone.", current = true),
        RobotSetupStepUiState("Connect robot", "Put Stack-chan on the same Wi-Fi and enter the phone bridge URL."),
        RobotSetupStepUiState("Confirm ready", "Wait for the robot hello before using brain or settings controls."),
    ),
)

data class RobotSetupStepUiState(
    val label: String,
    val detail: String,
    val completed: Boolean = false,
    val current: Boolean = false,
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
    val panelTitle: String = "PC Brain Supervisor",
    val primaryActionRunningLabel: String = "Stop brain",
    val primaryActionStoppedLabel: String = "Start brain",
    val restartActionLabel: String = "Restart",
    val showBrainHandoffActions: Boolean = true,
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
    val endpointId: String,
    val name: String,
    val kind: String,
    val fingerprint: String,
    val priority: Int,
    val connected: Boolean,
    val activeBrain: Boolean,
    val removable: Boolean = false,
)

private enum class MobileSection(
    val label: String,
) {
    Live("Live"),
    Talk("Talk"),
    Brain("Brain"),
    Nodes("Nodes"),
    Telemetry("Telem"),
}

@Composable
fun CompanionConsole(
    targetName: String,
    state: CompanionUiState = CompanionUiState(),
    onStartBrain: () -> Unit = {},
    onStopBrain: () -> Unit = {},
    onRestartBrain: () -> Unit = {},
    onExportDiagnostics: () -> Unit = {},
    onRunC6Rehearsal: () -> Unit = {},
    onForgetEndpoint: (String) -> Unit = {},
    onSendTextTurn: (String) -> Unit = {},
    onPushToTalk: () -> Unit = {},
) {
    MaterialTheme {
        Surface(color = Page, modifier = Modifier.fillMaxSize()) {
            BoxWithConstraints(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
                val compact = maxWidth < 820.dp
                val wideConsole = maxWidth >= 1180.dp
                TacticalBackdrop()
                if (compact) {
                    MobileConsole(
                        targetName = targetName,
                        state = state,
                        onStartBrain = onStartBrain,
                        onStopBrain = onStopBrain,
                        onRestartBrain = onRestartBrain,
                        onExportDiagnostics = onExportDiagnostics,
                        onRunC6Rehearsal = onRunC6Rehearsal,
                        onForgetEndpoint = onForgetEndpoint,
                        onSendTextTurn = onSendTextTurn,
                        onPushToTalk = onPushToTalk,
                    )
                } else {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp),
                    ) {
                        Header(targetName, state, compact = false)
                        if (wideConsole) {
                            WideConsole(
                                state = state,
                                onStartBrain = onStartBrain,
                                onStopBrain = onStopBrain,
                                onRestartBrain = onRestartBrain,
                                onExportDiagnostics = onExportDiagnostics,
                                onRunC6Rehearsal = onRunC6Rehearsal,
                                onForgetEndpoint = onForgetEndpoint,
                                onSendTextTurn = onSendTextTurn,
                                onPushToTalk = onPushToTalk,
                            )
                        } else {
                            TabletConsole(
                                state = state,
                                onStartBrain = onStartBrain,
                                onStopBrain = onStopBrain,
                                onRestartBrain = onRestartBrain,
                                onExportDiagnostics = onExportDiagnostics,
                                onRunC6Rehearsal = onRunC6Rehearsal,
                                onForgetEndpoint = onForgetEndpoint,
                                onSendTextTurn = onSendTextTurn,
                                onPushToTalk = onPushToTalk,
                            )
                        }
                        Footer()
                    }
                }
            }
        }
    }
}

@Composable
private fun MobileConsole(
    targetName: String,
    state: CompanionUiState,
    onStartBrain: () -> Unit,
    onStopBrain: () -> Unit,
    onRestartBrain: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onRunC6Rehearsal: () -> Unit,
    onForgetEndpoint: (String) -> Unit,
    onSendTextTurn: (String) -> Unit,
    onPushToTalk: () -> Unit,
) {
    var selectedSection by remember { mutableStateOf(MobileSection.Live) }
    Column(
        modifier = Modifier.fillMaxSize().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Header(targetName, state, compact = true)
        Column(
            modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (selectedSection) {
                MobileSection.Live -> {
                    StagePanel(state, Modifier.fillMaxWidth(), compact = true)
                    SecurityPanel(Modifier.fillMaxWidth())
                }
                MobileSection.Talk -> ConversationPanel(
                    state = state,
                    modifier = Modifier.fillMaxWidth(),
                    onSendTextTurn = onSendTextTurn,
                    onPushToTalk = onPushToTalk,
                )
                MobileSection.Brain -> BrainPanel(
                    state = state,
                    modifier = Modifier.fillMaxWidth(),
                    onStartBrain = onStartBrain,
                    onStopBrain = onStopBrain,
                    onRestartBrain = onRestartBrain,
                    onExportDiagnostics = onExportDiagnostics,
                    onRunC6Rehearsal = onRunC6Rehearsal,
                )
                MobileSection.Nodes -> EndpointRegistry(
                    state = state,
                    modifier = Modifier.fillMaxWidth(),
                    showTabs = false,
                    onRestartBridge = onRestartBrain,
                    onForgetEndpoint = onForgetEndpoint,
                )
                MobileSection.Telemetry -> TelemetryPanel(state, Modifier.fillMaxWidth())
            }
            Spacer(Modifier.height(4.dp))
        }
        MobileNav(selectedSection = selectedSection, onSelected = { selectedSection = it })
    }
}

@Composable
private fun WideConsole(
    state: CompanionUiState,
    onStartBrain: () -> Unit,
    onStopBrain: () -> Unit,
    onRestartBrain: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onRunC6Rehearsal: () -> Unit,
    onForgetEndpoint: (String) -> Unit,
    onSendTextTurn: (String) -> Unit,
    onPushToTalk: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.weight(0.82f),
        ) {
            PersonaCorePanel(state, Modifier.fillMaxWidth())
            DirectivePanel(Modifier.fillMaxWidth())
            SecurityPanel(Modifier.fillMaxWidth())
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.weight(1.62f),
        ) {
            StagePanel(state, Modifier.fillMaxWidth())
            ConversationPanel(
                state = state,
                modifier = Modifier.fillMaxWidth(),
                onSendTextTurn = onSendTextTurn,
                onPushToTalk = onPushToTalk,
            )
            EndpointRegistry(
                state = state,
                modifier = Modifier.fillMaxWidth(),
                onRestartBridge = onRestartBrain,
                onForgetEndpoint = onForgetEndpoint,
            )
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.weight(0.96f),
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
        }
    }
}

@Composable
private fun TabletConsole(
    state: CompanionUiState,
    onStartBrain: () -> Unit,
    onStopBrain: () -> Unit,
    onRestartBrain: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onRunC6Rehearsal: () -> Unit,
    onForgetEndpoint: (String) -> Unit,
    onSendTextTurn: (String) -> Unit,
    onPushToTalk: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.weight(1.65f),
        ) {
            StagePanel(state, Modifier.fillMaxWidth())
            ConversationPanel(
                state = state,
                modifier = Modifier.fillMaxWidth(),
                onSendTextTurn = onSendTextTurn,
                onPushToTalk = onPushToTalk,
            )
            EndpointRegistry(
                state = state,
                modifier = Modifier.fillMaxWidth(),
                onRestartBridge = onRestartBrain,
                onForgetEndpoint = onForgetEndpoint,
            )
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

@Composable
private fun MobileNav(selectedSection: MobileSection, onSelected: (MobileSection) -> Unit) {
    Surface(
        color = Panel,
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Line),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            MobileSection.entries.forEach { section ->
                MobileNavItem(
                    text = section.label,
                    selected = section == selectedSection,
                    onClick = { onSelected(section) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun MobileNavItem(text: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = ButtonDefaults.buttonColors(
        containerColor = if (selected) Cyan else PanelAlt,
        contentColor = if (selected) Color(0xFF061018) else Ink,
    )
    Button(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        colors = colors,
        modifier = modifier.height(44.dp),
        contentPadding = ButtonDefaults.ContentPadding,
    ) {
        Text(text, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
private fun PersonaCorePanel(state: CompanionUiState, modifier: Modifier) {
    PanelShell(modifier = modifier) {
        SectionTitle("Persona Core", Cyan)
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            PersonaMode("Spark", selected = true, modifier = Modifier.weight(1f))
            PersonaMode("Glow", selected = false, modifier = Modifier.weight(1f))
        }
        Spacer(Modifier.height(14.dp))
        Readout("Active", state.activePersona, Mint)
        Spacer(Modifier.height(10.dp))
        Readout("State", state.robotState, Cyan)
        Spacer(Modifier.height(12.dp))
        Text(
            "> energetic / curious / high-frequency responses",
            color = Muted,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            lineHeight = 16.sp,
        )
    }
}

@Composable
private fun DirectivePanel(modifier: Modifier) {
    PanelShell(modifier = modifier) {
        SectionTitle("Directives", Mint)
        Spacer(Modifier.height(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            DirectiveItem("Initialize greeting")
            DirectiveItem("Environmental scan")
            DirectiveItem("Diagnostic mode")
            DirectiveItem("Low power sleep")
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
                RobotPreview(Modifier.fillMaxWidth(if (compact) 0.78f else 0.42f).aspectRatio(1f))
                Spacer(Modifier.height(8.dp))
                Text("State // ${state.robotState}", color = Muted, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
            }
        }
        Spacer(Modifier.height(14.dp))
        Text("Manual servos and triggers", color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Spacer(Modifier.height(8.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SmallCommand("Look L", enabled = false)
            SmallCommand("Look R", enabled = false)
            SmallCommand("Nod Down", enabled = false)
            SmallCommand("Shake", enabled = false)
            SmallCommand("Reset", filled = true, enabled = false)
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
private fun EndpointRegistry(
    state: CompanionUiState,
    modifier: Modifier,
    showTabs: Boolean = true,
    onRestartBridge: () -> Unit = {},
    onForgetEndpoint: (String) -> Unit = {},
) {
    var showSetup by remember { mutableStateOf(!state.robotSetup.robotConnected) }
    PanelShell(modifier = modifier) {
        if (showTabs) {
            Tabs()
            Spacer(Modifier.height(14.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("My Stack-chan", color = Ink, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            StatusPill(
                text = if (state.robotSetup.robotConnected) "Connected" else "Setup needed",
                color = if (state.robotSetup.robotConnected) Mint else Amber,
                background = if (state.robotSetup.robotConnected) Color(0xFF0D2A25) else Color(0xFF2A2613),
            )
        }
        Text("Add or reconnect the robot, then manage the companions allowed to control it.", color = Muted, fontSize = 11.sp)
        Spacer(Modifier.height(12.dp))
        RobotSetupCard(
            setup = state.robotSetup,
            expanded = showSetup,
            onToggleExpanded = { showSetup = !showSetup },
            onRestartBridge = onRestartBridge,
        )
        Spacer(Modifier.height(14.dp))
        Text("Trusted companion nodes", color = Ink, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        Text(
            "Only trusted companions can own the conversational brain or issue settings updates.",
            color = Muted,
            fontSize = 11.sp,
        )
        Spacer(Modifier.height(10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.endpoints.forEach { endpoint ->
                EndpointItem(endpoint, onForgetEndpoint = onForgetEndpoint, onReconnect = onRestartBridge)
            }
        }
        Spacer(Modifier.height(14.dp))
    }
}

@Composable
private fun ConversationPanel(
    state: CompanionUiState,
    modifier: Modifier,
    onSendTextTurn: (String) -> Unit,
    onPushToTalk: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    PanelShell(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionTitle("Talk", Mint)
            Spacer(Modifier.weight(1f))
            StatusPill(
                text = if (state.conversation.inputEnabled) "Ready" else "Waiting",
                color = if (state.conversation.inputEnabled) Mint else Amber,
                background = if (state.conversation.inputEnabled) Color(0xFF0D2A25) else Color(0xFF2A2613),
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(state.conversation.status, color = Muted, fontSize = 11.sp, lineHeight = 16.sp)
        Spacer(Modifier.height(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            state.conversation.messages.takeLast(5).forEach { message ->
                ConversationBubble(message)
            }
        }
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = draft,
            onValueChange = { draft = it },
            enabled = state.conversation.inputEnabled,
            singleLine = false,
            minLines = 2,
            label = { Text("Text to Stack-chan", color = Muted, fontSize = 12.sp) },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            SmallCommand(
                text = "Send",
                filled = true,
                enabled = state.conversation.inputEnabled && draft.isNotBlank(),
                onClick = {
                    val text = draft.trim()
                    if (text.isNotBlank()) {
                        draft = ""
                        onSendTextTurn(text)
                    }
                },
            )
            SmallCommand(
                text = state.conversation.pushToTalkLabel,
                enabled = state.conversation.pushToTalkEnabled,
                onClick = onPushToTalk,
            )
        }
        if (state.conversation.pushToTalkStatus.isNotBlank()) {
            Spacer(Modifier.height(8.dp))
            Text(state.conversation.pushToTalkStatus, color = Muted, fontSize = 10.sp, lineHeight = 14.sp)
        }
    }
}

@Composable
private fun ConversationBubble(message: ConversationMessage) {
    Surface(
        color = if (message.sender == "You") Color(0xFF102E30) else PanelAlt,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (message.sender == "You") Cyan else Line),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(message.sender, color = Ink, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                if (message.detail.isNotBlank()) {
                    Text(message.detail, color = Muted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Text(message.text, color = Ink, fontSize = 12.sp, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun RobotSetupCard(
    setup: RobotSetupUiState,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onRestartBridge: () -> Unit,
) {
    Surface(
        color = PanelAlt,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (setup.robotConnected) Mint else Amber),
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    modifier = Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).background(Console).border(1.dp, Line, RoundedCornerShape(8.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("SC", color = Cyan, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(setup.setupTitle, color = Ink, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(setup.setupStatus, color = Muted, fontSize = 10.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                SmallCommand(if (expanded) "Hide setup" else "Setup", onClick = onToggleExpanded)
            }

            if (expanded) {
                Readout("Robot", setup.robotName, if (setup.robotConnected) Mint else Amber)
                Readout("Robot fingerprint", setup.robotFingerprint, if (setup.robotConnected) Cyan else Muted)
                Readout("Phone bridge URL", setup.primaryBridgeUrl, Cyan)
                if (setup.otherBridgeUrls.isNotEmpty()) {
                    Text(
                        "Other LAN URLs: ${setup.otherBridgeUrls.joinToString(", ")}",
                        color = Muted,
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                setup.steps.forEachIndexed { index, step ->
                    PairingStep(index + 1, step)
                }
                Text(
                    "Trusted companions stored: ${setup.trustedCompanionCount}. Remove old phones, PCs, or test nodes below when they should no longer control Stack-chan.",
                    color = Muted,
                    fontSize = 11.sp,
                    lineHeight = 16.sp,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    SmallCommand("Restart discovery", filled = true, onClick = onRestartBridge)
                    SmallCommand(
                        text = if (setup.serviceRunning) "Bridge running" else "Start bridge",
                        enabled = !setup.serviceRunning,
                        onClick = onRestartBridge,
                    )
                }
            }
        }
    }
}

@Composable
private fun PairingStep(number: Int, step: RobotSetupStepUiState) {
    val color = when {
        step.completed -> Mint
        step.current -> Amber
        else -> Muted
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        Surface(color = if (step.completed) Color(0xFF0D2A25) else Color(0xFF102E30), shape = CircleShape) {
            Text(
                if (step.completed) "OK" else number.toString(),
                color = color,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(step.label, color = Ink, fontSize = 12.sp, fontWeight = FontWeight.Bold, lineHeight = 17.sp)
            Text(step.detail, color = Muted, fontSize = 11.sp, lineHeight = 16.sp)
        }
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
        SectionTitle(state.brainService.panelTitle, Purple)
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp), modifier = Modifier.fillMaxWidth()) {
            Readout("Service", state.brainService.status, if (state.brainService.running) Mint else Amber, Modifier.weight(0.9f))
            Readout("PID", state.brainService.pid, Muted, Modifier.weight(0.7f))
            Readout("Endpoint", state.brainService.endpoint, Cyan, Modifier.weight(1.35f))
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
                text = if (state.brainService.running) {
                    state.brainService.primaryActionRunningLabel
                } else {
                    state.brainService.primaryActionStoppedLabel
                },
                filled = true,
                onClick = if (state.brainService.running) onStopBrain else onStartBrain,
            )
            SmallCommand(state.brainService.restartActionLabel, onClick = onRestartBrain)
            SmallCommand("Export diagnostics", onClick = onExportDiagnostics)
            SmallCommand("Run C6 rehearsal", onClick = onRunC6Rehearsal)
            if (state.brainService.showBrainHandoffActions) {
                SmallCommand("Use phone", enabled = false)
                SmallCommand("Handoff", enabled = false)
            }
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
private fun Readout(label: String, value: String, accent: Color, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Text(label.uppercase(), color = Muted, fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        Text(
            value,
            color = accent,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SmallCommand(text: String, filled: Boolean = false, enabled: Boolean = true, onClick: () -> Unit = {}) {
    val colors = if (filled) {
        ButtonDefaults.buttonColors(
            containerColor = Cyan,
            contentColor = Color(0xFF061018),
            disabledContainerColor = Color(0xFF12343A),
            disabledContentColor = Muted,
        )
    } else {
        ButtonDefaults.outlinedButtonColors(
            contentColor = Ink,
            containerColor = Color.Transparent,
            disabledContentColor = Muted,
            disabledContainerColor = Color.Transparent,
        )
    }
    if (filled) {
        Button(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(8.dp), colors = colors) {
            Text(text, fontSize = 12.sp)
        }
    } else {
        OutlinedButton(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(8.dp), colors = colors) {
            Text(text, fontSize = 12.sp)
        }
    }
}

@Composable
private fun PersonaMode(text: String, selected: Boolean, modifier: Modifier = Modifier) {
    Surface(
        color = if (selected) Color(0xFF092832) else Color.Transparent,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) Cyan else Line),
        shape = RoundedCornerShape(8.dp),
        modifier = modifier,
    ) {
        Text(
            text.uppercase(),
            color = if (selected) Ink else Muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 10.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun DirectiveItem(text: String) {
    OutlinedButton(
        onClick = {},
        enabled = false,
        shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Ink, containerColor = Console),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text.uppercase(),
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
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
private fun EndpointItem(
    endpoint: EndpointRow,
    onForgetEndpoint: (String) -> Unit,
    onReconnect: () -> Unit,
) {
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
                    if (endpoint.kind == "robot") {
                        Spacer(Modifier.height(6.dp))
                        SmallCommand("Reconnect", onClick = onReconnect)
                    }
                } else if (endpoint.kind == "robot") {
                    StatusPill("Waiting", Amber, Color(0xFF2A2613))
                    Spacer(Modifier.height(6.dp))
                    SmallCommand("Setup", filled = true, onClick = onReconnect)
                } else if (endpoint.removable) {
                    Button(
                        onClick = { onForgetEndpoint(endpoint.endpointId) },
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Danger, contentColor = Color.White),
                    ) {
                        Text("Remove", fontSize = 12.sp)
                    }
                } else {
                    Button(
                        onClick = {},
                        enabled = false,
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
        val side = minOf(w, h)
        val display = Size(side, side)
        val left = (w - display.width) * 0.5f
        val top = (h - display.height) * 0.5f
        val scaleX = display.width / 240f
        val scaleY = display.height / 240f
        fun sx(value: Float) = left + value * scaleX
        fun sy(value: Float) = top + value * scaleY

        drawRoundRect(color = Color(0xFF071013), topLeft = Offset(0f, 0f), size = size)

        fun eye(cx: Float, cy: Float, browTilt: Float, pupilDx: Float) {
            val eyeW = 74f * scaleX
            val eyeH = 47f * scaleY
            val eyeLeft = sx(cx) - eyeW * 0.5f
            val eyeTop = sy(cy) - eyeH * 0.5f
            drawRoundRect(
                color = Color(0xFFF7FBFF),
                topLeft = Offset(eyeLeft, eyeTop),
                size = Size(eyeW, eyeH),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(8.dp.toPx()),
            )
            drawLine(
                color = Color(0xFF61E4D7),
                start = Offset(eyeLeft + eyeW * 0.04f, eyeTop + eyeH + 1.dp.toPx()),
                end = Offset(eyeLeft + eyeW * 0.96f, eyeTop + eyeH + 1.dp.toPx()),
                strokeWidth = 1.dp.toPx(),
                cap = StrokeCap.Round,
            )
            val cut = 8.dp.toPx()
            drawPath(
                path = Path().apply {
                    moveTo(eyeLeft, eyeTop + eyeH - cut)
                    lineTo(eyeLeft + cut, eyeTop + eyeH)
                    lineTo(eyeLeft, eyeTop + eyeH)
                    close()
                },
                color = Color(0xFF071013),
            )
            drawPath(
                path = Path().apply {
                    moveTo(eyeLeft + eyeW, eyeTop + eyeH - cut)
                    lineTo(eyeLeft + eyeW - cut, eyeTop + eyeH)
                    lineTo(eyeLeft + eyeW, eyeTop + eyeH)
                    close()
                },
                color = Color(0xFF071013),
            )
            val pupilW = eyeW * 0.16f
            val pupilH = eyeH * 0.52f
            val pupilCenter = Offset(sx(cx + pupilDx), sy(cy - 2f))
            drawOval(
                color = Color(0xFF111827),
                topLeft = Offset(pupilCenter.x - pupilW * 0.5f, pupilCenter.y - pupilH * 0.5f),
                size = Size(pupilW, pupilH),
            )
            drawCircle(
                color = Color(0xFF071013),
                radius = pupilW * 0.34f,
                center = Offset(pupilCenter.x - pupilW * 0.38f, pupilCenter.y - pupilH * 0.28f),
            )
            drawCircle(
                color = Color(0xFFF7FBFF),
                radius = pupilW * 0.16f,
                center = Offset(pupilCenter.x - pupilW * 0.20f, pupilCenter.y - pupilH * 0.34f),
            )
            val browY = sy(cy - 38f)
            val browHalf = eyeW * 0.25f
            drawLine(
                color = Color(0xFFF7FBFF),
                start = Offset(sx(cx) - browHalf, browY + browTilt * 5f * scaleY),
                end = Offset(sx(cx) + browHalf, browY - browTilt * 5f * scaleY),
                strokeWidth = 1.5.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }

        eye(78f, 96f, -0.10f, 4f)
        eye(162f, 96f, 0.10f, -4f)

        val mouth = Path().apply {
            moveTo(sx(88f), sy(158f))
            quadraticTo(sx(120f), sy(170f), sx(152f), sy(158f))
        }
        drawPath(
            path = mouth,
            color = Color(0xFFFF6B8A),
            style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round),
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
