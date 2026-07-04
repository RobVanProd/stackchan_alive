package dev.stackchan.companion.desktop

import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionConsole
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

fun main() {
    val runtime = DesktopCompanionRuntime().start()
    Runtime.getRuntime().addShutdownHook(Thread { runtime.close() })

    application {
        Window(
            onCloseRequest = {
                runtime.close()
                exitApplication()
            },
            title = CompanionIdentity.displayName,
            state = rememberWindowState(width = 1180.dp, height = 820.dp),
        ) {
            val uiState = produceState(initialValue = desktopStartingUiState(), runtime) {
                while (true) {
                    value = runtime.toCompanionUiState()
                    delay(1_000)
                }
            }
            val scope = rememberCoroutineScope()
            CompanionConsole(
                targetName = "Desktop",
                state = uiState.value,
                onStartBrain = { runCatching { runtime.startBrainService() } },
                onStopBrain = { runCatching { runtime.stopBrainService() } },
                onRestartBrain = { runCatching { runtime.restartBrainService() } },
                onExportDiagnostics = {
                    scope.launch {
                        runCatching { runtime.exportDiagnosticsEvidenceFile() }
                    }
                },
                onRunC6Rehearsal = {
                    scope.launch {
                        runCatching { runtime.runC6GuiRehearsal() }
                    }
                },
            )
        }
    }
}
