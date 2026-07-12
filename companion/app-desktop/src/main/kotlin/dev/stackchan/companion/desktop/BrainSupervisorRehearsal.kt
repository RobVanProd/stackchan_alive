package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.BridgeHello
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.core.DeviceHello
import dev.stackchan.companion.core.Listening
import dev.stackchan.companion.core.ResponseEnd
import dev.stackchan.companion.core.ResponseStart
import dev.stackchan.companion.core.Thinking
import dev.stackchan.companion.core.UtteranceEnd
import dev.stackchan.companion.core.UtteranceStart
import dev.stackchan.companion.core.decodeControlMessage
import dev.stackchan.companion.core.encodeControlMessage
import java.net.ConnectException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.time.Instant
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

fun main(args: Array<String>) {
    val outDir = Path.of(args.firstOrNull() ?: "output/companion/c6-gui-rehearsal")
    Files.createDirectories(outDir)
    val result = runC6GuiRehearsalSmoke(outDir)
    if (!result.report.ok) {
        error("C6 GUI rehearsal failed; see ${result.evidencePath}")
    }
}

fun runC6GuiRehearsalSmoke(outDir: Path): BrainSupervisorRehearsalResult = runBlocking {
    val repoRoot = defaultRepoRoot()
    val scriptPath = repoRoot.resolve("bridge").resolve("lan_service.py")
    val pythonCommand = resolveBrainSupervisorPythonCommand()
    val runtimePort = freeBrainSupervisorLoopbackPort()
    val brainPort = freeBrainSupervisorLoopbackPort()
    val stateDir = Files.createTempDirectory(outDir, "state-")
    val brainConfig = DesktopBrainSupervisorConfig(
        pythonCommand = pythonCommand,
        scriptPath = scriptPath,
        host = "127.0.0.1",
        port = brainPort,
        arguments = listOf(
            "--host",
            "127.0.0.1",
            "--port",
            brainPort.toString(),
            "--runner-profile",
            "gemma4-e2b-gguf",
            "--runner-case",
            "greeting",
            "--once",
        ),
        workingDirectory = scriptPath.parent,
    )
    val runtimeConfig = DesktopCompanionRuntimeConfig(
        host = "127.0.0.1",
        port = runtimePort,
        storageDir = stateDir,
        endpointId = "pc-c6-gui-rehearsal",
        advertiseMdns = false,
        brainSupervisorConfig = brainConfig,
    )

    DesktopCompanionRuntime(runtimeConfig).use { runtime ->
        runtime.start()
        runtime.runC6GuiRehearsal(outDir)
    }
}

data class BrainSupervisorRehearsalResult(
    val evidencePath: Path,
    val diagnosticsPath: Path,
    val report: BrainSupervisorRehearsalReport,
)

data class BrainSupervisorRehearsalReport(
    val generatedAt: Instant,
    val brainPort: Int,
    val firstStart: DesktopBrainSupervisorSnapshot,
    val firstTurn: BrainTurnEvidence,
    val firstStop: DesktopBrainSupervisorSnapshot,
    val restartStart: DesktopBrainSupervisorSnapshot,
    val secondTurn: BrainTurnEvidence,
    val finalStop: DesktopBrainSupervisorSnapshot,
    val diagnosticsPath: Path,
    val notes: List<String>,
) {
    val startOk: Boolean = firstStart.running && firstStart.pid != null
    val firstStopOk: Boolean = firstStop.running == false && firstStop.exitCode != null
    val restartOk: Boolean = restartStart.running && restartStart.pid != null && restartStart.pid != firstStart.pid
    val finalStopOk: Boolean = finalStop.running == false && finalStop.exitCode != null
    val diagnosticsExportOk: Boolean = Files.isRegularFile(diagnosticsPath)
    val ok: Boolean =
        startOk && firstTurn.ok && firstStopOk && restartOk && secondTurn.ok && finalStopOk && diagnosticsExportOk

    fun toMarkdown(): String = buildString {
        appendLine("# Companion C6 GUI Rehearsal")
        appendLine()
        appendLine("- generated_at: `$generatedAt`")
        appendLine("- brain_endpoint: `127.0.0.1:$brainPort`")
        appendLine("- start_ok: `$startOk`")
        appendLine("- first_turn_ok: `${firstTurn.ok}`")
        appendLine("- first_stop_ok: `$firstStopOk`")
        appendLine("- restart_ok: `$restartOk`")
        appendLine("- second_turn_ok: `${secondTurn.ok}`")
        appendLine("- final_stop_ok: `$finalStopOk`")
        appendLine("- diagnostics_export_ok: `$diagnosticsExportOk`")
        appendLine("- overall_ok: `$ok`")
        appendLine()
        appendLine("## Turns")
        appendLine()
        appendLine("- first_frame_order: `${firstTurn.frameOrder.joinToString(" -> ")}`")
        appendLine("- first_response_text: `${firstTurn.responseText}`")
        appendLine("- first_response_end_latency_ms: `${firstTurn.responseEndLatencyMs}`")
        appendLine("- second_frame_order: `${secondTurn.frameOrder.joinToString(" -> ")}`")
        appendLine("- second_response_text: `${secondTurn.responseText}`")
        appendLine("- second_response_end_latency_ms: `${secondTurn.responseEndLatencyMs}`")
        appendLine()
        appendLine("## Supervisor")
        appendLine()
        appendLine("- first_pid: `${firstStart.pid}`")
        appendLine("- first_stop_exit_code: `${firstStop.exitCode}`")
        appendLine("- restart_pid: `${restartStart.pid}`")
        appendLine("- final_stop_exit_code: `${finalStop.exitCode}`")
        appendLine("- diagnostics_path: `$diagnosticsPath`")
        appendLine()
        appendLine("## Notes")
        notes.forEach { appendLine("- $it") }
    }

    fun toJson(): String =
        buildJsonObject {
            put("schema", "stackchan.companion.c6-gui-rehearsal.v1")
            put("generated_at", generatedAt.toString())
            put("brain_port", brainPort)
            put("start_ok", startOk)
            put("first_turn_ok", firstTurn.ok)
            put("first_stop_ok", firstStopOk)
            put("restart_ok", restartOk)
            put("second_turn_ok", secondTurn.ok)
            put("final_stop_ok", finalStopOk)
            put("diagnostics_export_ok", diagnosticsExportOk)
            put("overall_ok", ok)
            put("first_start", firstStart.toBrainSupervisorEvidenceJson())
            put("first_turn", firstTurn.toBrainTurnEvidenceJson())
            put("first_stop", firstStop.toBrainSupervisorEvidenceJson())
            put("restart_start", restartStart.toBrainSupervisorEvidenceJson())
            put("second_turn", secondTurn.toBrainTurnEvidenceJson())
            put("final_stop", finalStop.toBrainSupervisorEvidenceJson())
            put("diagnostics_path", diagnosticsPath.toString())
            put("notes", JsonArray(notes.map { JsonPrimitive(it) }))
        }.toString()
}

suspend fun DesktopCompanionRuntime.runBrainSupervisorGuiRehearsal(
    outputDir: Path = snapshot().storageDir.resolve("diagnostics").resolve("c6-gui-rehearsal"),
): BrainSupervisorRehearsalResult {
    Files.createDirectories(outputDir)
    val notes = mutableListOf<String>()
    notes += "Running C6 rehearsal through DesktopCompanionRuntime controls."
    val initial = snapshot().brainSupervisor
    if (initial.running) {
        notes += "Stopping already-running brain service before rehearsal."
        stopBrainService()
    }

    val brainPort = snapshot().brainSupervisor.port
    val firstStart = startBrainService()
    val firstTurn = driveBrainSupervisorTextTurn(brainPort, deviceId = "stackchan-gui-rehearsal-1", seq = 81)
    waitForBrainSupervisorExit(timeout = Duration.ofMillis(500))
    val firstStop = stopBrainService()

    val restartStart = restartBrainService()
    val secondTurn = driveBrainSupervisorTextTurn(brainPort, deviceId = "stackchan-gui-rehearsal-2", seq = 82)
    waitForBrainSupervisorExit(timeout = Duration.ofMillis(500))
    val finalStop = stopBrainService()

    val diagnosticsPath = exportDiagnosticsEvidenceFile(outputDir)
    notes += "First service pid `${firstStart.pid}` stopped with exit code `${firstStop.exitCode}`."
    notes += "Restarted service pid `${restartStart.pid}` stopped with exit code `${finalStop.exitCode}`."
    notes += "Diagnostics export written to `$diagnosticsPath`."

    val report = BrainSupervisorRehearsalReport(
        generatedAt = Instant.now(),
        brainPort = brainPort,
        firstStart = firstStart,
        firstTurn = firstTurn,
        firstStop = firstStop,
        restartStart = restartStart,
        secondTurn = secondTurn,
        finalStop = finalStop,
        diagnosticsPath = diagnosticsPath,
        notes = notes,
    )
    val evidencePath = outputDir.resolve("GUI_REHEARSAL.json")
    Files.writeString(evidencePath, report.toJson())
    Files.writeString(outputDir.resolve("GUI_REHEARSAL.md"), report.toMarkdown())
    return BrainSupervisorRehearsalResult(
        evidencePath = evidencePath,
        diagnosticsPath = diagnosticsPath,
        report = report,
    )
}

private fun DesktopCompanionRuntime.waitForBrainSupervisorExit(timeout: Duration): DesktopBrainSupervisorSnapshot {
    val deadline = System.nanoTime() + timeout.toNanos()
    while (System.nanoTime() < deadline) {
        val snapshot = snapshot().brainSupervisor
        if (!snapshot.running && snapshot.exitCode != null) {
            return snapshot
        }
        Thread.sleep(25)
    }
    return snapshot().brainSupervisor
}

data class BrainTurnEvidence(
    val ok: Boolean,
    val frameOrder: List<String>,
    val responseText: String,
    val thinkingLatencyMs: Long,
    val responseEndLatencyMs: Long,
)

internal fun BrainTurnEvidence.toBrainTurnEvidenceJson() =
    buildJsonObject {
        put("ok", ok)
        put("frame_order", JsonArray(frameOrder.map { JsonPrimitive(it) }))
        put("response_text", responseText)
        put("thinking_latency_ms", thinkingLatencyMs)
        put("response_end_latency_ms", responseEndLatencyMs)
    }

internal fun DesktopBrainSupervisorSnapshot.toBrainSupervisorEvidenceJson() =
    buildJsonObject {
        put("running", running)
        pid?.let { put("pid", it) }
        put("host", host)
        put("port", port)
        put("script_path", scriptPath.toString())
        put("command", JsonArray(command.map { JsonPrimitive(it) }))
        put("python_runtime", pythonRuntime.toBrainSupervisorEvidenceJson())
        startedAt?.let { put("started_at", it.toString()) }
        stoppedAt?.let { put("stopped_at", it.toString()) }
        exitCode?.let { put("exit_code", it) }
        put("recent_logs", JsonArray(recentLogs.map { JsonPrimitive(it) }))
    }

internal fun DesktopPythonRuntimeStatus.toBrainSupervisorEvidenceJson() =
    buildJsonObject {
        put("command", command)
        put("available", available)
        put("version", version)
        put("script_available", scriptAvailable)
        workingDirectory?.let { put("working_directory", it.toString()) }
        put("detail", detail)
        put("searched_commands", JsonArray(searchedCommands.map { JsonPrimitive(it) }))
        put("managed_runtime", managedRuntime.toBrainSupervisorEvidenceJson())
    }

internal fun DesktopManagedPythonRuntimeStatus.toBrainSupervisorEvidenceJson() =
    buildJsonObject {
        put("present", present)
        root?.let { put("root", it.toString()) }
        manifestPath?.let { put("manifest_path", it.toString()) }
        pythonPath?.let { put("python_path", it.toString()) }
        put("detail", detail)
    }

internal fun driveBrainSupervisorTextTurn(port: Int, deviceId: String, seq: Int): BrainTurnEvidence {
    BrainRehearsalClient.connectWithRetry("ws://127.0.0.1:$port/bridge").use { client ->
        val startedAt = System.nanoTime()
        val sessionHello = decodeControlMessage(client.nextText()) as BridgeHello
        client.send(encodeControlMessage(DeviceHello(deviceId = deviceId, capabilities = listOf("diagnostics"))))
        val hello = decodeControlMessage(client.nextText()) as BridgeHello
        client.send(encodeControlMessage(UtteranceStart(seq = seq, sampleRate = 16000)))
        val listening = decodeControlMessage(client.nextText()) as Listening
        client.send(encodeControlMessage(UtteranceEnd(seq = seq, transcript = "Hello Stackchan.")))
        val thinking = decodeControlMessage(client.nextText()) as Thinking
        val thinkingLatencyMs = Duration.ofNanos(System.nanoTime() - startedAt).toMillis()
        val responseStart = decodeControlMessage(client.nextText()) as ResponseStart
        val frameOrder = mutableListOf(hello.type, listening.type, thinking.type, responseStart.type)
        var responseEndLatencyMs = thinkingLatencyMs
        while (true) {
            val next = decodeControlMessage(client.nextText())
            frameOrder += next.type
            if (next is ResponseEnd) {
                responseEndLatencyMs = Duration.ofNanos(System.nanoTime() - startedAt).toMillis()
                break
            }
        }
        val ok = sessionHello.protocol == CompanionIdentity.protocol &&
            hello.protocol == CompanionIdentity.protocol &&
            thinking.seq == seq &&
            responseStart.seq == seq &&
            responseStart.text.isNotBlank() &&
            frameOrder.first() == "hello" &&
            frameOrder.contains("thinking") &&
            frameOrder.contains("response_start") &&
            frameOrder.last() == "response_end"
        return BrainTurnEvidence(
            ok = ok,
            frameOrder = frameOrder,
            responseText = responseStart.text,
            thinkingLatencyMs = thinkingLatencyMs,
            responseEndLatencyMs = responseEndLatencyMs,
        )
    }
}

private class BrainRehearsalClient private constructor(
    private val socket: WebSocket,
    private val messages: LinkedBlockingQueue<String>,
) : AutoCloseable {
    fun send(text: String) {
        socket.sendText(text, true).join()
    }

    fun nextText(): String =
        messages.poll(Duration.ofSeconds(5).toMillis(), TimeUnit.MILLISECONDS)
            ?: error("timed out waiting for websocket text")

    override fun close() {
        socket.sendClose(WebSocket.NORMAL_CLOSURE, "done").join()
    }

    companion object {
        fun connectWithRetry(uri: String): BrainRehearsalClient {
            val deadline = System.nanoTime() + Duration.ofSeconds(8).toNanos()
            var lastError: Throwable? = null
            while (System.nanoTime() < deadline) {
                try {
                    return connect(uri)
                } catch (error: Throwable) {
                    lastError = error
                    if (!isRetryableConnectError(error)) {
                        throw error
                    }
                    Thread.sleep(100)
                }
            }
            throw IllegalStateException("timed out connecting to $uri", lastError)
        }

        private fun connect(uri: String): BrainRehearsalClient {
            val messages = LinkedBlockingQueue<String>()
            val listener = object : WebSocket.Listener {
                override fun onText(
                    webSocket: WebSocket,
                    data: CharSequence,
                    last: Boolean,
                ): CompletionStage<*> {
                    if (last) {
                        messages.offer(data.toString())
                    }
                    webSocket.request(1)
                    return CompletableFuture.completedFuture(null)
                }

                override fun onBinary(
                    webSocket: WebSocket,
                    data: ByteBuffer,
                    last: Boolean,
                ): CompletionStage<*> {
                    webSocket.request(1)
                    return CompletableFuture.completedFuture(null)
                }
            }
            val socket = HttpClient
                .newHttpClient()
                .newWebSocketBuilder()
                .connectTimeout(Duration.ofSeconds(2))
                .buildAsync(URI.create(uri), listener)
                .get(Duration.ofSeconds(2).toMillis(), TimeUnit.MILLISECONDS)
            socket.request(1)
            return BrainRehearsalClient(socket, messages)
        }

        private fun isRetryableConnectError(error: Throwable): Boolean {
            var current: Throwable? = error
            while (current != null) {
                if (current is ConnectException) {
                    return true
                }
                current = current.cause
            }
            return false
        }
    }
}
