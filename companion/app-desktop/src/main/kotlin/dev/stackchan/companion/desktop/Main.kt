package dev.stackchan.companion.desktop

import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionConsole
import java.awt.FileDialog
import java.awt.Frame
import java.nio.file.Path
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
                onDownloadModel = {
                    scope.launch {
                        runCatching { runtime.downloadGemmaModel() }
                    }
                },
                onLoadModel = {
                    runCatching { runtime.loadGemmaModel() }
                },
                onEjectModel = {
                    runCatching { runtime.ejectGemmaModel() }
                },
                onModelSettings = {
                    runCatching { runtime.modelAssetStatus() }
                },
                onImportPersona = {
                    choosePersonaImportZip()?.let { input ->
                        scope.launch {
                            runCatching { runtime.importPersonaZip(input) }
                        }
                    }
                },
                onExportPersona = {
                    val activePersona = uiState.value.personaLibrary.activePersona
                    choosePersonaExportZip("${activePersona}-persona.zip")?.let { output ->
                        scope.launch {
                            runCatching { runtime.exportPersonaZip(activePersona, output) }
                        }
                    }
                },
                onRunC6Rehearsal = {
                    scope.launch {
                        runCatching { runtime.runC6GuiRehearsal() }
                    }
                },
                onSendTextTurn = { text ->
                    scope.launch {
                        runCatching { runtime.submitTextTurn(text) }
                    }
                },
            )
        }
    }
}

private fun choosePersonaImportZip(): Path? {
    val dialog = FileDialog(null as Frame?, "Import Stackchan persona", FileDialog.LOAD)
    dialog.file = "*.zip"
    dialog.isVisible = true
    val file = dialog.file ?: return null
    val directory = dialog.directory ?: return null
    return Path.of(directory, file)
}

private fun choosePersonaExportZip(defaultFileName: String): Path? {
    val dialog = FileDialog(null as Frame?, "Export Stackchan persona", FileDialog.SAVE)
    dialog.file = defaultFileName
    dialog.isVisible = true
    val file = dialog.file ?: return null
    val directory = dialog.directory ?: return null
    return Path.of(directory, file)
}
