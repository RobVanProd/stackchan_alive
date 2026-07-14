package dev.stackchan.companion.desktop

import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.ui.CompanionConsole
import java.awt.Desktop
import java.awt.FileDialog
import java.awt.Frame
import java.net.URI
import java.nio.file.Path
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    val packageSmokeOutput = args.firstOrNull { it.startsWith(PACKAGE_SMOKE_OUTPUT_PREFIX) }
        ?.substringAfter(PACKAGE_SMOKE_OUTPUT_PREFIX)
        ?.takeIf { it.isNotBlank() }
    val packageSmokeContext = args.firstOrNull { it.startsWith(PACKAGE_SMOKE_CONTEXT_PREFIX) }
        ?.substringAfter(PACKAGE_SMOKE_CONTEXT_PREFIX)
        ?.takeIf { it.isNotBlank() }
        ?: "package-extraction"
    if (packageSmokeOutput != null || "--package-smoke" in args) {
        val report = if (packageSmokeOutput == null) {
            inspectPackagedRuntimeSmoke(launchContext = packageSmokeContext)
        } else {
            writePackagedRuntimeSmoke(Path.of(packageSmokeOutput), packageSmokeContext)
        }
        if (packageSmokeOutput == null) {
            println(report.toJson())
        }
        exitProcess(if (report.status == "ready") 0 else 2)
    }

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
                onSelectPersona = {
                    runCatching { runtime.selectNextPersona() }
                },
                onSaveDisplaySettings = {
                    runCatching { runtime.toggleDisplayReducedMotion() }
                },
                onPrivacySettings = {
                    runCatching { runtime.toggleDiagnosticsLogExport() }
                },
                onOpenPrivacyPolicy = {
                    runCatching { openPrivacyPolicy() }
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
                onClaimBrain = {
                    scope.launch {
                        runCatching { runtime.claimBrain() }
                    }
                },
                onReleaseBrain = {
                    scope.launch {
                        runCatching { runtime.releaseBrain() }
                    }
                },
            )
        }
    }
}

private const val PACKAGE_SMOKE_OUTPUT_PREFIX = "--package-smoke-output="
private const val PACKAGE_SMOKE_CONTEXT_PREFIX = "--package-smoke-context="

private fun openPrivacyPolicy() {
    check(Desktop.isDesktopSupported()) { "Desktop integration is unavailable." }
    val desktop = Desktop.getDesktop()
    check(desktop.isSupported(Desktop.Action.BROWSE)) { "Browser integration is unavailable." }
    desktop.browse(URI(CompanionIdentity.privacyPolicyUrl))
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
